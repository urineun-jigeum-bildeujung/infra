variable "project_name" {
  description = "IAM Role 이름의 프로젝트 접두사"
  type        = string
}

variable "environment" {
  description = "IAM Role 이름의 환경 식별자"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS IAM OIDC Provider ARN"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC issuer URL. https:// 접두사는 선택 사항."
  type        = string
}

variable "db_backups_bucket_arn" {
  description = "Terraform 으로 미리 생성하는 db-backups Bucket ARN"
  type        = string
}

variable "cnpg_namespace" {
  description = "PostgreSQL Cluster namespace (CNPG Operator namespace 가 아님)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.cnpg_namespace))
    error_message = "유효한 Kubernetes namespace 이름을 지정하세요 (소문자/숫자/하이픈, 최대 63자)."
  }
}

variable "cnpg_service_account_name" {
  description = "PostgreSQL Pod ServiceAccount 이름. 기본 CNPG 구성에서는 Cluster.metadata.name."
  type        = string

  validation {
    condition     = length(var.cnpg_service_account_name) <= 253 && can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.cnpg_service_account_name))
    error_message = "ServiceAccount 이름에는 소문자/숫자/점/하이픈만 사용하며 와일드카드를 허용하지 않습니다."
  }
}

variable "cnpg_backup_prefix" {
  description = "CNPG 백업 객체 접근 범위. 앞뒤 / 및 IAM wildcard 를 허용하지 않는다."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*$", var.cnpg_backup_prefix))
    error_message = "prefix 는 비어 있지 않은 경로여야 하며 문자/숫자/_/- 및 중간 / 만 허용합니다."
  }
}
