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
  description = "용도별 Versioning 설정 override. 생략한 항목은 공통 enable_versioning 값을 사용한다."
  type = map(object({
    enable_versioning = optional(bool)
  }))
  default = {}

  validation {
    condition     = alltrue([for purpose in keys(var.bucket_settings) : contains(var.bucket_purposes, purpose)])
    error_message = "bucket_settings 의 key 는 bucket_purposes 에 포함되어야 합니다."
  }
}

variable "enable_image_uploads" {
  description = "uploads 버킷의 이미지 직접 업로드 및 CloudFront 조회 구성 활성화"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_image_uploads || contains(var.bucket_purposes, "uploads")
    error_message = "이미지 업로드를 활성화하려면 bucket_purposes에 uploads가 있어야 합니다."
  }

  # 현재 버전 만료만으로 객체를 영구 삭제할 수 있는 비버전 버킷만 지원한다.
  validation {
    condition     = !var.enable_image_uploads || !coalesce(try(var.bucket_settings["uploads"].enable_versioning, null), var.enable_versioning)
    error_message = "이미지 uploads 버킷은 Versioning을 비활성화해야 합니다. 이전에 활성화한 버킷은 별도 버전 정리 정책이 필요합니다."
  }
}

variable "uploads_allowed_origins" {
  description = "S3 직접 PUT을 허용할 프론트엔드 origin 목록"
  type        = list(string)
  default     = []

  validation {
    condition = (!var.enable_image_uploads || length(var.uploads_allowed_origins) > 0) && alltrue([
      for origin in var.uploads_allowed_origins : can(regex("^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$", origin))
    ])
    error_message = "이미지 업로드에는 하나 이상의 정확한 HTTP(S) origin이 필요하며 wildcard와 경로는 허용하지 않습니다."
  }
}

variable "pending_upload_expiration_days" {
  description = "status=pending 객체가 생성 후 만료되는 일수"
  type        = number
  default     = 3

  validation {
    condition     = var.pending_upload_expiration_days >= 1 && floor(var.pending_upload_expiration_days) == var.pending_upload_expiration_days
    error_message = "pending 객체 만료 일수는 1 이상의 정수여야 합니다."
  }
}

variable "uploads_custom_domain_name" {
  description = "이미지 조회에 사용할 CloudFront 대체 도메인. null이면 CloudFront 기본 도메인을 사용한다."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.uploads_custom_domain_name == null || can(regex("^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.uploads_custom_domain_name))
    error_message = "uploads_custom_domain_name은 image.leechs.shop과 같은 유효한 소문자 도메인이어야 합니다."
  }
}

variable "uploads_cloudfront_certificate_arn" {
  description = "uploads_custom_domain_name에 연결할 us-east-1 ACM 인증서 ARN. 도메인을 사용하지 않으면 null이다."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.uploads_cloudfront_certificate_arn == null || can(regex("^arn:[^:]+:acm:us-east-1:[0-9]{12}:certificate/[0-9a-f-]+$", var.uploads_cloudfront_certificate_arn))
    error_message = "CloudFront 인증서는 us-east-1 ACM certificate ARN이어야 합니다."
  }
}
