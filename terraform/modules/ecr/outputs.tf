# ECR 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의
# CI(Jenkins) 의 Image Push 대상과 GitOps Helm values 의 이미지 경로에 사용된다.

output "repository_urls" {
  description = "서비스 이름을 key 로 하는 Repository URL map. 예: { \"auth-service\" = \"...amazonaws.com/petflow/auth-service\" }"
  value       = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}

output "repository_arns" {
  description = "서비스 이름을 key 로 하는 Repository ARN map. IAM 정책 작성 시 사용."
  value       = { for k, v in aws_ecr_repository.services : k => v.arn }
}

output "repository_names" {
  description = "실제 생성된 Repository 이름 목록. 예: [\"petflow/auth-service\", ...]"
  value       = [for v in aws_ecr_repository.services : v.name]
}
