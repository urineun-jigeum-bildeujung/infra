# VPC Flow Log 모듈이 외부에서 전달받는 값 정의

variable "project_name" {
  description = "프로젝트 식별용 접두사. 리소스 이름/태그에 사용한다."
  type        = string
}

variable "environment" {
  description = "환경 이름 (dev/prod 등). 리소스 이름/태그에 사용한다."
  type        = string
}

variable "aws_region" {
  description = "Flow Log 리소스 ARN 패턴(버킷 정책 조건)을 구성할 AWS 리전. 예: ap-northeast-2"
  type        = string
}

variable "aws_account_id" {
  description = "버킷 이름 유일성 및 버킷 정책 조건(SourceAccount)에 사용할 AWS 계정 ID"
  type        = string
}

variable "vpc_id" {
  description = "Flow Log를 활성화할 VPC ID. network 모듈의 vpc_id 출력값을 전달한다."
  type        = string
}

variable "s3_retention_days" {
  description = "Flow Log S3 보관 일수. 지금은 짧게 시작하고 이후 값만 늘린다(예: 1년 요구 시 365)."
  type        = number
  default     = 30
}

variable "allowed_admin_role_arns" {
  description = "Flow Log 버킷의 삭제/정책변경이 허용되는 관리자 IAM User/Role ARN 목록. CloudTrail과 동일 목록을 재사용한다."
  type        = list(string)

  validation {
    condition = length(var.allowed_admin_role_arns) > 0 && alltrue([
      for arn in var.allowed_admin_role_arns :
      can(regex("^arn:(aws|aws-us-gov|aws-cn):iam::[0-9]{12}:(user|role)/[A-Za-z0-9+=,.@_/-]+$", arn))
    ])
    error_message = "allowed_admin_role_arns에는 비어 있지 않은 IAM User/Role ARN 목록을 지정해야 합니다."
  }
}
