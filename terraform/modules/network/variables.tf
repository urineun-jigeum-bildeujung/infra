# Network 모듈이 외부에서 전달받는 값 정의

variable "project_name" {
  description = "프로젝트 식별용 접두사. VPC 및 서브넷 이름 태그에 사용한다."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC 에서 사용할 CIDR 대역"
  type        = string
}
