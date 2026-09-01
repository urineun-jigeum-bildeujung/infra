# Network 모듈이 외부에서 전달받는 값 정의

variable "project_name" {
  description = "프로젝트 식별용 접두사. VPC 및 서브넷 이름 태그에 사용한다."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC 에서 사용할 CIDR 대역. 예: 10.0.0.0/16"
  type        = string
}

variable "azs" {
  description = "리소스를 배치할 Availability Zone 목록. 순서가 subnet_cidrs 리스트와 매칭된다."
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
  description = <<-EOT
    NAT Gateway 배치 전략.
    true  : NAT 1개만 첫 번째 AZ 에 배치 후 모든 Private Subnet 이 공유 (DEV 비용 절약)
    false : AZ 마다 NAT 를 하나씩 배치 (HA, Prod 권장)
  EOT
  type        = bool
  default     = true
}
