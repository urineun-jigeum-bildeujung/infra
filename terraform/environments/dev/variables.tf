# Dev 환경 Root Module 입력 변수 정의
# 값은 terraform.tfvars 로 전달한다.

variable "aws_region" {
  description = "Dev 환경 리소스를 배포할 AWS 리전"
  type        = string
}

variable "project_name" {
  description = "프로젝트 식별용 접두사. 리소스 이름 및 태그에 사용한다."
  type        = string
}

variable "environment" {
  description = "환경 식별자. Dev 환경에서는 \"dev\" 값을 사용한다."
  type        = string
  default     = "dev"
}

# =============================================================================
# DNS
# =============================================================================
variable "domain_name" {
  description = "Route53에서 관리할 서비스 루트 도메인"
  type        = string
}

# =============================================================================
# Network
# =============================================================================
variable "vpc_cidr" {
  description = "Dev 환경 VPC 에서 사용할 CIDR 대역"
  type        = string
}

variable "azs" {
  description = "리소스를 배치할 Availability Zone 목록"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Public Subnet CIDR 목록. azs 와 같은 순서/길이여야 한다."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private Subnet CIDR 목록. azs 와 같은 순서/길이여야 한다."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "true 이면 NAT Gateway 1개만 배치 (DEV 비용 절약). false 면 AZ 마다 NAT 하나씩 (HA)."
  type        = bool
  default     = true
}

# =============================================================================
# Tailscale 관리자 VPN
# =============================================================================
variable "enable_tailscale_router" {
  description = "DEV 관리자 접근용 Tailscale Subnet Router 생성 여부"
  type        = bool
  default     = true
}

variable "tailscale_instance_type" {
  description = "Tailscale Subnet Router EC2 Instance Type"
  type        = string
  default     = "t3.micro"

  validation {
    condition     = length(trimspace(var.tailscale_instance_type)) > 0
    error_message = "tailscale_instance_type은 비어 있을 수 없습니다."
  }
}

variable "tailscale_oauth_secret_arn" {
  description = "Tailscale Router 자동 인증용 Secrets Manager Secret ARN"
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:[^*]+$", var.tailscale_oauth_secret_arn))
    error_message = "tailscale_oauth_secret_arn은 와일드카드가 없는 AWS Secrets Manager Secret ARN이어야 합니다."
  }
}

# =============================================================================
# EKS
# =============================================================================
variable "eks_cluster_version" {
  description = "EKS 버전. 1.35 는 2026-09 실제 apply 로 검증 완료. tfvars 로 override 가능."
  type        = string
  default     = "1.35"
}

variable "eks_endpoint_public_access" {
  description = "EKS API 서버의 Public Endpoint 활성화 여부"
  type        = bool
  default     = false
}

variable "eks_endpoint_private_access" {
  description = "EKS API 서버의 Private Endpoint (VPC 내부에서 접근) 활성화 여부"
  type        = bool
  default     = true
}

variable "eks_public_access_cidrs" {
  description = "EKS Public Endpoint 접근을 허용할 CIDR 목록. 초기엔 넓게 열고 이후 관리자 IP 로 좁힌다."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "eks_cluster_admin_principal_arns" {
  description = "EKS Cluster Admin 권한을 부여할 IAM User/Role ARN 목록. 예: [\"arn:aws:iam::297165773875:user/ujibil2\"]"
  type        = list(string)
  default     = []
}

variable "eks_node_instance_types" {
  description = "Managed Node Group EC2 인스턴스 타입 후보"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_ami_type" {
  description = "Managed Node Group AMI 타입 (AL2023_x86_64_STANDARD 등)"
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "eks_node_disk_size" {
  description = "Managed Node Group Worker Node root EBS 크기 (GiB)"
  type        = number
  default     = 50

  validation {
    condition     = var.eks_node_disk_size >= 20
    error_message = "eks_node_disk_size는 최소 20GiB 이상이어야 합니다."
  }
}

variable "eks_node_desired_size" {
  description = "Managed Node Group desired 노드 수"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "Managed Node Group 최소 노드 수"
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Managed Node Group 최대 노드 수"
  type        = number
  default     = 3
}

# =============================================================================
# ECR (이후 feat/ecr 브랜치에서 사용)
# =============================================================================
# =============================================================================
# S3 (애플리케이션용)
# =============================================================================
variable "s3_bucket_purposes" {
  description = "애플리케이션용 S3 Bucket 의 용도 목록. 용도별로 <project>-<env>-<용도> Bucket 이 생성된다."
  type        = list(string)
  default     = ["static", "product-images", "uploads", "db-backups"]
}

variable "cnpg_namespace" {
  description = "CNPG PostgreSQL Cluster namespace (Operator namespace 가 아님). GitOps 와 맞춘다."
  type        = string
  default     = "database"
}

variable "cnpg_service_account_name" {
  description = "CNPG PostgreSQL Pod ServiceAccount 이름. 기본적으로 GitOps 의 Cluster.metadata.name 과 같다."
  type        = string
  default     = "petflow-db"
}

variable "cnpg_backup_prefix" {
  description = "db-backups 안의 CNPG 전용 prefix. 앞뒤 / 는 포함하지 않는다."
  type        = string
  default     = "cnpg"
}

variable "ecr_repository_names" {
  description = "생성할 ECR Repository 이름 목록. MSA 서비스 단위로 지정한다."
  type        = list(string)
  default     = []
}
