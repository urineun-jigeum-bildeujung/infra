# ECR 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의
#
# 예시:
#   output "repository_urls" {
#     value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
#   }
