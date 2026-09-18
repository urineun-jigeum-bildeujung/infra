variable "aws_region" {
  description = "Management Internal ALB가 배포된 AWS Region"
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
  description = "Public Route53 Hosted Zone의 루트 도메인"
  type        = string

  validation {
    condition     = can(regex("^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name은 leechs.shop과 같은 유효한 소문자 루트 도메인이어야 합니다."
  }
}

variable "grafana_hostname" {
  description = "Grafana에 연결할 FQDN"
  type        = string

  validation {
    condition     = startswith(var.grafana_hostname, "grafana.") && endswith(var.grafana_hostname, var.domain_name)
    error_message = "grafana_hostname은 domain_name 아래의 grafana 서브도메인이어야 합니다."
  }
}

variable "prometheus_hostname" {
  description = "Prometheus에 연결할 FQDN"
  type        = string

  validation {
    condition     = startswith(var.prometheus_hostname, "prometheus.") && endswith(var.prometheus_hostname, var.domain_name)
    error_message = "prometheus_hostname은 domain_name 아래의 prometheus 서브도메인이어야 합니다."
  }
}

variable "management_alb_name" {
  description = "AWS Load Balancer Controller가 생성한 Management Internal ALB 이름"
  type        = string

  validation {
    condition     = var.management_alb_name == "petflow-dev-management"
    error_message = "management_alb_name은 petflow-dev-management여야 합니다."
  }
}

variable "alb_ingress_stack" {
  description = "ALB의 ingress.k8s.aws/stack 태그 기대값"
  type        = string
  default     = "petflow-dev-management"
}

variable "eks_cluster_name" {
  description = "ALB의 elbv2.k8s.aws/cluster 태그와 VPC를 검증할 EKS 이름"
  type        = string
  default     = "petflow-eks"
}
