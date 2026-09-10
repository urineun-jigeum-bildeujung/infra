variable "project_name" {
  description = "프로젝트 식별용 접두사"
  type        = string
}

variable "environment" {
  description = "환경 식별자"
  type        = string
}

variable "vpc_id" {
  description = "Tailscale Router Security Group을 생성할 VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "Tailscale에서 광고할 AWS VPC CIDR"
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr는 유효한 IPv4 CIDR이어야 합니다."
  }
}

variable "eks_cluster_security_group_id" {
  description = "Tailscale Router에서 TCP 443 접근을 허용할 EKS Cluster Security Group ID"
  type        = string
}

variable "private_subnet_id" {
  description = "Public IP 없이 Router EC2를 배치할 Private Subnet ID"
  type        = string
}

variable "instance_type" {
  description = "Tailscale Subnet Router EC2 Instance Type"
  type        = string
  default     = "t3.micro"

  validation {
    condition     = length(trimspace(var.instance_type)) > 0
    error_message = "instance_type은 비어 있을 수 없습니다."
  }
}

variable "root_volume_size" {
  description = "Router EC2 root EBS 크기 (GiB)"
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size >= 8
    error_message = "root_volume_size는 최소 8GiB 이상이어야 합니다."
  }
}
