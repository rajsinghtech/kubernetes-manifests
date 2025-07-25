output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_primary_security_group_id
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
}

output "node_security_group_id" {
  description = "Security group ID for EKS nodes"
  value       = module.eks.node_security_group_id
}

output "cluster_version" {
  description = "The Kubernetes version for the cluster"
  value       = module.eks.cluster_version
}

output "cluster_arn" {
  description = "The Amazon Resource Name (ARN) of the cluster"
  value       = module.eks.cluster_arn
}

output "node_group_arn" {
  description = "EKS node group ARN"
  value       = [for ng in module.eks.eks_managed_node_groups : ng.node_group_arn][0]
}

output "vpc_id" {
  description = "ID of the VPC where the cluster is deployed"
  value       = aws_vpc.main.id
}

output "vpc_ipv6_cidr_block" {
  description = "IPv6 CIDR block assigned to the VPC"
  value       = aws_vpc.main.ipv6_cidr_block
}

output "subnet_ids" {
  description = "List of subnet IDs where the cluster is deployed"
  value       = aws_subnet.public[*].id
}

output "subnet_details" {
  description = "Details of the dual-stack subnets"
  value = {
    for subnet in aws_subnet.public : 
    subnet.id => {
      availability_zone               = subnet.availability_zone
      cidr_block                     = subnet.cidr_block
      ipv6_cidr_block               = subnet.ipv6_cidr_block
      map_public_ip_on_launch       = subnet.map_public_ip_on_launch
      assign_ipv6_address_on_creation = subnet.assign_ipv6_address_on_creation
    }
  }
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "egress_only_internet_gateway_id" {
  description = "ID of the Egress-only Internet Gateway for IPv6"
  value       = aws_egress_only_internet_gateway.main.id
}

output "tailscale_operator_namespace" {
  description = "Kubernetes namespace where Tailscale operator is deployed"
  value       = kubernetes_namespace.tailscale_operator.metadata[0].name
}

output "cert_manager_namespace" {
  description = "Kubernetes namespace where cert-manager is deployed"
  value       = kubernetes_namespace.cert_manager.metadata[0].name
} 