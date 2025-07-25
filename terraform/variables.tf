variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "customderp-raj"
}

variable "cluster_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.33"
}

variable "instance_type" {
  description = "EC2 instance type for the EKS worker nodes"
  type        = string
  default     = "c6g.xlarge"
}

variable "desired_capacity" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 2
}

variable "key_name" {
  description = "Name of the AWS key pair for SSH access"
  type        = string
  default     = "raj_macbook"
}

variable "derp_http_port" {
  description = "DERP HTTP port"
  type        = number
  default     = 80
}

variable "derp_https_port" {
  description = "DERP HTTPS port"
  type        = number
  default     = 443
}

variable "derp_stun_port" {
  description = "DERP STUN port"
  type        = number
  default     = 3478
}

variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth client ID"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.tailscale_oauth_client_id) > 0
    error_message = "Tailscale OAuth client ID must not be empty."
  }
}

variable "tailscale_oauth_client_secret" {
  description = "Tailscale OAuth client secret"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.tailscale_oauth_client_secret) > 0
    error_message = "Tailscale OAuth client secret must not be empty."
  }
} 