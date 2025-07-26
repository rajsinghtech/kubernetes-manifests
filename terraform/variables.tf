variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "customderp"
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

variable "peer_relay_port" {
  description = "Peer relay UDP port"
  type        = number
  default     = 41641
}


variable "sops_gpg_key_path" {
  description = "Path to the SOPS GPG private key file for Flux secret decryption"
  type        = string

  validation {
    condition     = length(var.sops_gpg_key_path) > 0
    error_message = "SOPS GPG key path must not be empty."
  }
} 