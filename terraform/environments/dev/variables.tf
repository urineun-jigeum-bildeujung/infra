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
# ECR (이후 feat/ecr 브랜치에서 사용)
# =============================================================================
variable "ecr_repository_names" {
  description = "생성할 ECR Repository 이름 목록. MSA 서비스 단위로 지정한다."
  type        = list(string)
  default     = []
}
