# ECR 모듈이 외부에서 전달받는 값 정의

variable "project_name" {
  description = "프로젝트 식별용 접두사. Repository 이름은 <project_name>/<service_name> 형태가 된다."
  type        = string
}

variable "repository_names" {
  description = <<-EOT
    생성할 ECR Repository 의 서비스 이름 목록.
    백엔드 리포지토리(sever) dev 브랜치의 services/ 디렉터리를 Source of Truth 로 사용한다.
    새 서비스가 백엔드에 추가되면 이 목록에 이름만 추가하면 신규 Repository 만 생성된다.
    예: ["auth-service", "member-service"]
  EOT
  type        = list(string)
  default     = []
}

variable "image_tag_mutability" {
  description = "이미지 태그 재사용 허용 여부. DEV 는 MUTABLE, 운영 전환 시 IMMUTABLE 검토."
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability 는 MUTABLE 또는 IMMUTABLE 이어야 한다."
  }
}

variable "force_delete" {
  description = <<-EOT
    true 면 이미지가 남아있는 Repository 도 terraform destroy 로 삭제할 수 있다.
    DEV 는 반복적인 destroy/apply 를 전제로 하므로 true 를 기본값으로 사용한다.
    운영 환경에서는 false 로 두어 이미지가 있는 Repository 의 실수 삭제를 방지한다.
  EOT
  type        = bool
  default     = true
}

variable "lifecycle_keep_count" {
  description = "Repository 별로 유지할 최근 이미지 개수. 이 개수를 초과하는 오래된 이미지는 자동 삭제된다."
  type        = number
  default     = 20
}

variable "untagged_expire_days" {
  description = "태그가 없는(untagged) 이미지를 자동 삭제하기까지의 일수. 빌드 중간 산출물 정리 용도."
  type        = number
  default     = 7
}
