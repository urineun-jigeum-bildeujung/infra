# terraform-access 스택 입력 변수 정의

variable "aws_region" {
  description = "IAM 리소스를 배포할 AWS 리전 (IAM 은 글로벌이지만 Provider 기본 리전이 필요하다)"
  type        = string
}

variable "project_name" {
  description = "프로젝트 식별용 접두사. Role / Policy 이름에 사용한다."
  type        = string
}

variable "state_bucket_name" {
  description = "Terraform State 가 저장된 S3 Bucket 이름. IAM Policy Resource ARN 을 구성할 때 사용한다."
  type        = string
}

variable "github_org" {
  description = "GitHub Actions OIDC Role 을 부여할 GitHub Organization 또는 사용자 이름"
  type        = string
}

variable "github_repo" {
  description = "GitHub Actions OIDC Role 을 부여할 GitHub Repository 이름. 예: infra"
  type        = string
}

variable "protected_route53_zone_ids" {
  description = "삭제를 명시적으로 거부할 Route53 Public Hosted Zone ID 목록"
  type        = set(string)

  validation {
    condition = length(var.protected_route53_zone_ids) > 0 && alltrue([
      for zone_id in var.protected_route53_zone_ids : can(regex("^Z[A-Z0-9]+$", zone_id))
    ])
    error_message = "protected_route53_zone_ids에는 Z로 시작하는 Hosted Zone ID를 하나 이상 입력해야 합니다."
  }
}

variable "route53_protection_user_names" {
  description = "Route53 Hosted Zone 삭제 차단 Policy를 연결할 IAM 사용자 이름 목록"
  type        = set(string)
}
