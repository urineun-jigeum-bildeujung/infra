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

variable "force_destroy" {
  description = <<-EOT
    true 면 객체가 남아있는 Bucket 도 terraform destroy 로 삭제할 수 있다.
    DEV 는 반복 destroy/apply 를 전제로 하므로 true 를 기본값으로 사용한다.
    운영 환경에서는 반드시 false 로 두어 데이터 유실을 방지한다.
  EOT
  type        = bool
  default     = true
}

variable "enable_versioning" {
  description = "Bucket Versioning 활성화 여부. DEV 는 버전 누적으로 인한 용량 과금을 피하기 위해 기본 비활성. 운영 전환 시 활성 검토."
  type        = bool
  default     = false
}
