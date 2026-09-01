# S3 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의
# 애플리케이션 환경변수 / IAM 정책 / (향후) CloudFront origin 설정에 사용된다.

output "bucket_names" {
  description = "용도를 key 로 하는 Bucket 이름 map. 예: { \"uploads\" = \"petflow-dev-uploads\" }"
  value       = { for k, v in aws_s3_bucket.app : k => v.bucket }
}

output "bucket_arns" {
  description = "용도를 key 로 하는 Bucket ARN map. 애플리케이션 IAM 정책 작성 시 사용."
  value       = { for k, v in aws_s3_bucket.app : k => v.arn }
}

output "bucket_regional_domain_names" {
  description = "용도를 key 로 하는 리전 도메인 map. 향후 CloudFront origin 설정 등에 사용."
  value       = { for k, v in aws_s3_bucket.app : k => v.bucket_regional_domain_name }
}
