variable "aws_region" {
  description = "Web ALB가 배포된 AWS Region"
  type        = string
}

variable "project_name" {
  description = "프로젝트 식별자"
  type        = string
}

variable "environment" {
  description = "환경 식별자"
  type        = string
  default     = "dev"
}

variable "domain_name" {
  description = "Web에 연결할 Route53 루트 도메인"
  type        = string

  validation {
    condition     = can(regex("^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name은 leechs.shop과 같은 유효한 소문자 루트 도메인이어야 합니다."
  }
}

variable "web_alb_name" {
  description = "AWS Load Balancer Controller가 생성한 Web Public ALB 이름"
  type        = string

  validation {
    condition     = length(trimspace(var.web_alb_name)) > 0
    error_message = "web_alb_name은 비어 있을 수 없습니다."
  }
}

variable "alb_ingress_stack" {
  description = "ALB의 ingress.k8s.aws/stack 태그 기대값"
  type        = string
  default     = "petflow-public"
}

variable "eks_cluster_name" {
  description = "ALB의 elbv2.k8s.aws/cluster 태그 기대값"
  type        = string
  default     = "petflow-eks"
}
