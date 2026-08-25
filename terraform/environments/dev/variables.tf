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

variable "vpc_cidr" {
  description = "Dev 환경 VPC 에서 사용할 CIDR 대역"
  type        = string
}

variable "ecr_repository_names" {
  description = "생성할 ECR Repository 이름 목록. MSA 서비스 단위로 지정한다."
  type        = list(string)
  default     = []
}
