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

  # Tailscale configuration
  tailscale_oauth_client_id     = var.tailscale_oauth_client_id
  tailscale_oauth_client_secret = var.tailscale_oauth_client_secret
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
  version = "~> 20.0"

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

# Kubernetes namespace for Tailscale operator
resource "kubernetes_namespace" "tailscale_operator" {
  metadata {
    name = "tailscale"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }

  depends_on = [module.eks]
}

# Kubernetes namespace for DERP server
resource "kubernetes_namespace" "derp" {
  metadata {
    name = "derp"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }

  depends_on = [module.eks]
}

# Kubernetes namespace for cert-manager
resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }

  depends_on = [module.eks]
}

# Deploy cert-manager using Helm
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.18.0"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  values = [
    yamlencode({
      installCRDs = true
      dns01RecursiveNameserversOnly = true
      extraArgs = [
        "--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53",
        "--dns01-recursive-nameservers-only"
      ]
    })
  ]

  depends_on = [
    kubernetes_namespace.cert_manager,
    module.eks,
  ]
}

# Deploy Tailscale Operator using Helm
resource "helm_release" "tailscale_operator" {
  name       = "tailscale-operator"
  repository = "https://pkgs.tailscale.com/helmcharts"
  chart      = "tailscale-operator"
  version    = "1.84.0"
  namespace  = kubernetes_namespace.tailscale_operator.metadata[0].name

  values = [
    yamlencode({
      operatorConfig = {
        image = {
          repo = "tailscale/k8s-operator"
          tag  = "v1.84.0"
        }
        hostname = "${local.name}-k8s-operator"
      }
      apiServerProxyConfig = {
        mode = "true"
        tags = "tag:k8s-operator,tag:k8s-api-server"
      }
      oauth = {
        clientId     = local.tailscale_oauth_client_id
        clientSecret = local.tailscale_oauth_client_secret
        hostname     = "${local.name}-operator"
        tags         = "tag:k8s-operator"
      }
    })
  ]

  set_sensitive {
    name  = "oauth.clientId"
    value = local.tailscale_oauth_client_id
  }

  set_sensitive {
    name  = "oauth.clientSecret"
    value = local.tailscale_oauth_client_secret
  }

  depends_on = [
    kubernetes_namespace.tailscale_operator,
    module.eks,
  ]
}

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
resource "kubernetes_manifest" "storage_class_gp3" {
  manifest = {
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
  }
  
  depends_on = [module.eks]
}

resource "kubernetes_manifest" "storage_class_gp3_retain" {
  manifest = {
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
  }
  
  depends_on = [module.eks]
} 