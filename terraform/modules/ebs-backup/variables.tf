variable "project_name" {
  description = "AWS Backup 리소스 이름의 프로젝트 접두사"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,31}$", var.project_name))
    error_message = "project_name은 영문 소문자, 숫자, 하이픈으로 구성된 1~32자여야 합니다."
  }
}

variable "environment" {
  description = "환경 식별자"
  type        = string
}

variable "aws_region" {
  description = "백업 대상 EBS가 있는 AWS Region"
  type        = string
}

variable "aws_account_id" {
  description = "백업 대상 EBS가 있는 AWS Account ID"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id는 12자리여야 합니다."
  }
}

variable "backup_tag_key" {
  description = "AWS Backup이 EBS를 선택할 때 사용하는 태그 Key"
  type        = string
  default     = "PetflowBackup"

  validation {
    condition     = length(trimspace(var.backup_tag_key)) > 0
    error_message = "backup_tag_key는 비어 있을 수 없습니다."
  }
}

variable "backup_tag_value" {
  description = "AWS Backup이 EBS를 선택할 때 사용하는 태그 Value"
  type        = string

  validation {
    condition     = length(trimspace(var.backup_tag_value)) > 0
    error_message = "backup_tag_value는 비어 있을 수 없습니다."
  }
}

variable "schedule" {
  description = "AWS Backup UTC cron 표현식"
  type        = string
  default     = "cron(0 19 * * ? *)"

  validation {
    condition     = can(regex("^cron\\(.+\\)$", var.schedule))
    error_message = "schedule은 AWS Backup cron(...) 형식이어야 합니다."
  }
}

variable "retention_days" {
  description = "EBS Recovery Point 보관 일수"
  type        = number
  default     = 7

  validation {
    condition     = var.retention_days >= 1 && floor(var.retention_days) == var.retention_days
    error_message = "retention_days는 1 이상의 정수여야 합니다."
  }
}
