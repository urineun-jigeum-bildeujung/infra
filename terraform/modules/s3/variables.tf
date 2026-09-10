# S3 모듈이 외부에서 전달받는 값 정의

variable "project_name" {
  description = "프로젝트 식별용 접두사. Bucket 이름은 <project>-<environment>-<용도> 형태가 된다."
  type        = string
}

variable "environment" {
  description = "환경 식별자 (dev / prod). Bucket 이름에 포함되어 환경 간 충돌을 방지한다."
  type        = string
}

variable "bucket_purposes" {
  description = <<-EOT
    생성할 애플리케이션용 Bucket 의 용도 목록. 용도별로 Bucket 이 하나씩 생성된다.
    예: ["static", "product-images", "uploads"]
    → petflow-dev-static / petflow-dev-product-images / petflow-dev-uploads
    새 용도가 필요하면 이 목록에 추가만 하면 된다 (기존 Bucket 영향 없음).
  EOT
  type        = list(string)
  default     = ["static", "product-images", "uploads"]
}

variable "enable_versioning" {
  description = "Bucket Versioning 활성화 여부. DEV 는 버전 누적으로 인한 용량 과금을 피하기 위해 기본 비활성. 운영 전환 시 활성 검토."
  type        = bool
  default     = false
}

variable "bucket_settings" {
  description = "용도별 설정 override. 생략한 항목은 공통 force_destroy / enable_versioning 값을 사용한다."
  type = map(object({
    force_destroy     = optional(bool)
    enable_versioning = optional(bool)
  }))
  default = {}

  validation {
    condition     = alltrue([for purpose in keys(var.bucket_settings) : contains(var.bucket_purposes, purpose)])
    error_message = "bucket_settings 의 key 는 bucket_purposes 에 포함되어야 합니다."
  }
}
