locals {
  name = var.cluster_name

  aws_tags = {
    Name = local.name
    Terraform = "true"
  }

  # EKS cluster configuration
  cluster_version    = var.cluster_version
  node_instance_type = var.instance_type
  node_capacity_type = "ON_DEMAND"
  node_ami_type      = "AL2023_ARM_64_STANDARD"
  desired_size       = var.desired_capacity
  max_size           = var.max_size
  min_size           = var.min_size
}

################################################################################
# Data sources and Provider Initialization                                     #
################################################################################

# Get availability zones (exclude us-east-1e which doesn't support EKS)
data "aws_availability_zones" "available" {
  state = "available"
  exclude_names = ["us-east-1e"]
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

################################################################################
# VPC Configuration for Dual-Stack (IPv4 + IPv6)                            #
################################################################################

# Create custom VPC with dual-stack support
resource "aws_vpc" "main" {
  cidr_block                       = "10.0.0.0/16"
  assign_generated_ipv6_cidr_block = true
  enable_dns_hostnames             = true
  enable_dns_support               = true

  tags = merge(
    local.aws_tags,
    {
      Name = "${local.name}-vpc"
    }
  )
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.aws_tags,
    {
      Name = "${local.name}-igw"
    }
  )
}

# Egress-only Internet Gateway for IPv6
resource "aws_egress_only_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.aws_tags,
    {
      Name = "${local.name}-eigw"
    }
  )
}

# Public subnets with IPv4 and IPv6
resource "aws_subnet" "public" {
  count = min(length(data.aws_availability_zones.available.names), 3)

  vpc_id                          = aws_vpc.main.id
  cidr_block                      = "10.0.${count.index + 1}.0/24"
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, count.index + 1)
  availability_zone               = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true

  tags = merge(
    local.aws_tags,
    {
      Name = "${local.name}-public-${data.aws_availability_zones.available.names[count.index]}"
      Type = "Public"
    }
  )
}

# Route table for public subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.main.id
  }

  tags = merge(
    local.aws_tags,
    {
      Name = "${local.name}-public-rt"
    }
  )
}

# Associate public subnets with route table
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

################################################################################
# EKS Cluster                                                                  #
################################################################################

# Wait for IAM policy propagation (eventual consistency)
resource "time_sleep" "wait_for_iam_policy" {
  create_duration = "30s"
  
  depends_on = [
    aws_vpc.main,
    aws_subnet.public,
    aws_internet_gateway.main,
    aws_egress_only_internet_gateway.main
  ]
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  cluster_name    = local.name
  cluster_version = local.cluster_version
  
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]
  
  enable_cluster_creator_admin_permissions = true
  enable_irsa = true
  
  # Required for IPv6 clusters - creates the CNI IPv6 policy
  create_cni_ipv6_iam_policy = true
  
  cluster_addons = {
    coredns = {
      configuration_values = jsonencode({
        nodeSelector = {
          "kubernetes.io/os" = "linux"
        }
        tolerations = [
          {
            key    = "CriticalAddonsOnly"
            operator = "Exists"
          },
          {
            key    = "node.kubernetes.io/not-ready"
            operator = "Exists"
            effect = "NoExecute"
            tolerationSeconds = 300
          },
          {
            key    = "node.kubernetes.io/unreachable"
            operator = "Exists"
            effect = "NoExecute"
            tolerationSeconds = 300
          }
        ]
      })
    }
    kube-proxy = {}
    vpc-cni = {}
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
    }
  }

  # Enable logging
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = 7

  vpc_id                   = aws_vpc.main.id
  subnet_ids               = aws_subnet.public[*].id
  cluster_ip_family        = "ipv6"
  
  depends_on = [time_sleep.wait_for_iam_policy]

  eks_managed_node_groups = {
    "${local.name}-nodes" = {
      instance_types = [local.node_instance_type]
      capacity_type  = local.node_capacity_type
      ami_type       = local.node_ami_type

      min_size     = local.min_size
      max_size     = local.max_size
      desired_size = local.desired_size

      # Enable public IP assignment for nodes
      associate_public_ip_address = true

      # SSH key configuration
      key_name = var.key_name

      update_config = {
        max_unavailable = 1
      }

      tags = merge(
        local.aws_tags,
        {
          Name = "${local.name}-eks-node"
        }
      )
    }
  }

  # Additional security group rules for DERP and ICMP
  node_security_group_additional_rules = {
    # ICMP (ping) traffic - IPv4
    ingress_icmp = {
      description = "ICMP ping traffic IPv4"
      protocol    = "icmp"
      from_port   = -1
      to_port     = -1
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }

    # ICMPv6 (ping) traffic - IPv6
    ingress_icmpv6 = {
      description      = "ICMPv6 ping traffic IPv6"
      protocol         = "icmpv6"
      from_port        = -1
      to_port          = -1
      type             = "ingress"
      ipv6_cidr_blocks = ["::/0"]
    }

    # SSH access - IPv4
    ingress_ssh = {
      description = "SSH access IPv4"
      protocol    = "tcp"
      from_port   = 22
      to_port     = 22
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }

    # SSH access - IPv6
    ingress_ssh_ipv6 = {
      description      = "SSH access IPv6"
      protocol         = "tcp"
      from_port        = 22
      to_port          = 22
      type             = "ingress"
      ipv6_cidr_blocks = ["::/0"]
    }

    # DERP HTTP - IPv4
    ingress_derp_http = {
      description = "DERP HTTP traffic IPv4"
      protocol    = "tcp"
      from_port   = var.derp_http_port
      to_port     = var.derp_http_port
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }

    # DERP HTTP - IPv6
    ingress_derp_http_ipv6 = {
      description      = "DERP HTTP traffic IPv6"
      protocol         = "tcp"
      from_port        = var.derp_http_port
      to_port          = var.derp_http_port
      type             = "ingress"
      ipv6_cidr_blocks = ["::/0"]
    }

    # DERP HTTPS - IPv4
    ingress_derp_https = {
      description = "DERP HTTPS traffic IPv4"
      protocol    = "tcp"
      from_port   = var.derp_https_port
      to_port     = var.derp_https_port
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }

    # DERP HTTPS - IPv6
    ingress_derp_https_ipv6 = {
      description      = "DERP HTTPS traffic IPv6"
      protocol         = "tcp"
      from_port        = var.derp_https_port
      to_port          = var.derp_https_port
      type             = "ingress"
      ipv6_cidr_blocks = ["::/0"]
    }

    # DERP STUN TCP - IPv4
    ingress_derp_stun_tcp = {
      description = "DERP STUN TCP traffic IPv4"
      protocol    = "tcp"
      from_port   = var.derp_stun_port
      to_port     = var.derp_stun_port
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }

    # DERP STUN TCP - IPv6
    ingress_derp_stun_tcp_ipv6 = {
      description      = "DERP STUN TCP traffic IPv6"
      protocol         = "tcp"
      from_port        = var.derp_stun_port
      to_port          = var.derp_stun_port
      type             = "ingress"
      ipv6_cidr_blocks = ["::/0"]
    }

    # DERP STUN UDP - IPv4
    ingress_derp_stun_udp = {
      description = "DERP STUN UDP traffic IPv4"
      protocol    = "udp"
      from_port   = var.derp_stun_port
      to_port     = var.derp_stun_port
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }

    # DERP STUN UDP - IPv6
    ingress_derp_stun_udp_ipv6 = {
      description      = "DERP STUN UDP traffic IPv6"
      protocol         = "udp"
      from_port        = var.derp_stun_port
      to_port          = var.derp_stun_port
      type             = "ingress"
      ipv6_cidr_blocks = ["::/0"]
    }

    # Peer Relay UDP - IPv4
    ingress_peer_relay_udp = {
      description = "Peer relay UDP traffic IPv4"
      protocol    = "udp"
      from_port   = var.peer_relay_port
      to_port     = var.peer_relay_port
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }

    # Peer Relay UDP - IPv6
    ingress_peer_relay_udp_ipv6 = {
      description      = "Peer relay UDP traffic IPv6"
      protocol         = "udp"
      from_port        = var.peer_relay_port
      to_port          = var.peer_relay_port
      type             = "ingress"
      ipv6_cidr_blocks = ["::/0"]
    }

    # Tailscale specific port
    ingress_tailscale = {
      description      = "Tailscale UDP traffic"
      protocol         = "udp"
      from_port        = 41641
      to_port          = 41641
      type             = "ingress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }

    # Allow all traffic within the VPC - IPv4
    ingress_vpc_all = {
      description = "Allow all traffic within VPC IPv4"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      protocol    = "-1"
      cidr_blocks = [aws_vpc.main.cidr_block]
    }

    # Allow all traffic within the VPC - IPv6
    ingress_vpc_all_ipv6 = {
      description      = "Allow all traffic within VPC IPv6"
      from_port        = 0
      to_port          = 0
      type             = "ingress"
      protocol         = "-1"
      ipv6_cidr_blocks = [aws_vpc.main.ipv6_cidr_block]
    }

    # Allow all traffic within the worker-node security group
    ingress_self_all = {
      description = "Allow all traffic within the worker-node security group"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      protocol    = "-1"
      self        = true
    }
  }

  tags = local.aws_tags
}

################################################################################
# Kubernetes Resources                                                         #
################################################################################





################################################################################
# EBS CSI Driver IAM Role                                                     #
################################################################################

# Create IAM role for EBS CSI driver
module "ebs_csi_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name             = "${local.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.aws_tags
}

################################################################################
# Storage Configuration                                                        #
################################################################################

# Apply storage classes for EBS volumes
resource "kubectl_manifest" "storage_class_gp3" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp3"
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "true"
      }
    }
    provisioner          = "ebs.csi.aws.com"
    parameters = {
      type      = "gp3"
      fsType    = "ext4"
      encrypted = "true"
    }
    volumeBindingMode    = "WaitForFirstConsumer"
    allowVolumeExpansion = true
  })
  
  depends_on = [
    module.eks,
    module.eks.aws_eks_addon
  ]
}

resource "kubectl_manifest" "storage_class_gp3_retain" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp3-retain"
    }
    provisioner       = "ebs.csi.aws.com"
    parameters = {
      type      = "gp3"
      fsType    = "ext4"
      encrypted = "true"
    }
    reclaimPolicy        = "Retain"
    volumeBindingMode    = "WaitForFirstConsumer"
    allowVolumeExpansion = true
  })
  
  depends_on = [
    module.eks,
    module.eks.aws_eks_addon
  ]
}

################################################################################
# Flux Bootstrap                                                               #
################################################################################

# Create flux-system namespace
resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = "flux-system"
  }

  lifecycle {
    ignore_changes = [metadata]
  }

  depends_on = [module.eks]
}

# Apply Flux bootstrap kustomization
resource "null_resource" "flux_bootstrap" {
  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}
      kubectl kustomize ${path.root}/../clusters/common/bootstrap/flux | kubectl apply -f -
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Flux resources will be cleaned up with cluster deletion'"
    on_failure = continue
  }

  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
    cluster_id = module.eks.cluster_id
  }

  depends_on = [
    kubernetes_namespace.flux_system,
    module.eks
  ]
}

# Create SOPS GPG secret for Flux
resource "kubernetes_secret" "sops_gpg" {
  metadata {
    name      = "sops-gpg"
    namespace = "flux-system"
  }

  data = {
    "sops.asc" = file("${path.root}/${var.sops_gpg_key_path}")
  }

  type = "Opaque"

  depends_on = [
    kubernetes_namespace.flux_system,
    null_resource.flux_bootstrap
  ]

  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

# Apply cluster-specific Flux configuration
resource "null_resource" "flux_cluster_config" {
  provisioner "local-exec" {
    command = <<-EOT
      # Wait for Flux CRDs to be available
      kubectl wait --for condition=established --timeout=60s crd/gitrepositories.source.toolkit.fluxcd.io
      kubectl wait --for condition=established --timeout=60s crd/kustomizations.kustomize.toolkit.fluxcd.io
      
      # Apply cluster-specific configuration
      kubectl apply -f ${path.root}/../clusters/${var.cluster_name}/flux/config/cluster.yaml
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Cluster-specific Flux resources will be cleaned up with cluster deletion'"
    on_failure = continue
  }

  triggers = {
    cluster_config = filesha256("${path.root}/../clusters/${var.cluster_name}/flux/config/cluster.yaml")
    cluster_name = var.cluster_name
  }

  depends_on = [
    kubernetes_secret.sops_gpg,
    null_resource.flux_bootstrap
  ]
} 