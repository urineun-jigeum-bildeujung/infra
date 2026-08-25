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
