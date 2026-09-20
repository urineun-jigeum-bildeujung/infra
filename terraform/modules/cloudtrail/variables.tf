variable "project_name" {
  description = "프로젝트 이름 (Naming Prefix)"
  type        = string
}

variable "environment" {
  description = "배포 환경 (dev, prod 등)"
  type        = string
}

variable "aws_account_id" {
  description = "S3 Bucket 정책의 CloudTrail 로그 경로(AWSLogs/<계정ID>/*) 구성에 사용"
  type        = string
}

variable "s3_retention_days" {
  description = "CloudTrail 로그 S3 보관 일수. 지금은 짧게 시작하고 이후 컴플라이언스 요구(예: 1년)에 맞춰 값만 조정한다."
  type        = number
  default     = 30
}

variable "cloudwatch_log_retention_days" {
  description = "CloudTrail 로그 CloudWatch Logs 보관 일수 (실시간 조회/알림용, S3 보관기간과는 별도로 관리)"
  type        = number
  default     = 30
}

variable "enable_log_file_validation" {
  description = "로그 파일 무결성 검증(다이제스트 파일 생성) 활성화 여부"
  type        = bool
  default     = true
}

variable "allowed_admin_role_arns" {
  description = "CloudTrail 로그 버킷의 삭제/정책변경(DeleteObject, PutBucketPolicy 등)이 허용되는 관리자 IAM User/Role ARN 목록. 여기 없는 주체는 전부 차단된다."
  type        = list(string)

  validation {
    condition = length(var.allowed_admin_role_arns) > 0 && alltrue([
      for arn in var.allowed_admin_role_arns :
      can(regex("^arn:(aws|aws-us-gov|aws-cn):iam::[0-9]{12}:(user|role)/[A-Za-z0-9+=,.@_/-]+$", arn))
    ])
    error_message = "allowed_admin_role_arns에는 비어 있지 않은 IAM User/Role ARN 목록을 지정해야 합니다."
  }
}
