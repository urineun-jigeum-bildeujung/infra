variable "project_name" {
  description = "IAM Role 이름의 프로젝트 접두사"
  type        = string
}

variable "environment" {
  description = "IAM Role 이름의 환경 식별자"
  type        = string
}

variable "cluster_name" {
  description = "워크로드 Pod Identity Association을 생성할 EKS Cluster 이름"
  type        = string
}

variable "uploads_bucket_arn" {
  description = "리뷰/프로필 이미지용 uploads 버킷 ARN"
  type        = string
  default     = null

  validation {
    condition     = var.uploads_bucket_arn != null || length(var.image_upload_workloads) == 0
    error_message = "이미지 워크로드를 지정하면 uploads_bucket_arn도 지정해야 합니다."
  }
}

variable "image_upload_workloads" {
  description = "서비스별 Pod Identity 연결 대상과 독립적인 S3 객체 경로"
  type = map(object({
    namespace       = string
    service_account = string
    prefix          = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, workload in var.image_upload_workloads :
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", name)) &&
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", workload.namespace)) &&
      length(workload.service_account) <= 253 &&
      can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", workload.service_account)) &&
      contains(["reviews", "profiles"], workload.prefix)
    ])
    error_message = "서비스/namespace/ServiceAccount에는 유효한 Kubernetes 이름을, prefix에는 reviews 또는 profiles를 지정해야 합니다."
  }

  validation {
    condition     = length(distinct([for workload in var.image_upload_workloads : workload.prefix])) == length(var.image_upload_workloads)
    error_message = "이미지 서비스 간 객체 경로가 중복되면 안 됩니다."
  }
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

variable "additional_service_account_names" {
  description = "같은 S3 백업 Role을 사용할 복원 검증용 추가 CNPG ServiceAccount 목록"
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for name in var.additional_service_account_names :
      length(name) <= 253 && can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", name))
    ])
    error_message = "추가 ServiceAccount 이름에는 소문자/숫자/점/하이픈만 사용하며 와일드카드를 허용하지 않습니다."
  }

  validation {
    condition     = !contains(var.additional_service_account_names, var.cnpg_service_account_name)
    error_message = "additional_service_account_names에 기본 CNPG ServiceAccount를 중복 지정할 수 없습니다."
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
