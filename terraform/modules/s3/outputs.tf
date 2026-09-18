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

output "uploads_cdn_base_url" {
  description = "리뷰/프로필 fileUrl 생성에 사용할 HTTPS 조회 기본 URL"
  value       = var.enable_image_uploads ? "https://${coalesce(var.uploads_custom_domain_name, aws_cloudfront_distribution.uploads[0].domain_name)}" : null
}

output "uploads_cloudfront_distribution_id" {
  description = "이미지 조회용 CloudFront Distribution ID"
  value       = try(aws_cloudfront_distribution.uploads[0].id, null)
}

output "uploads_cloudfront_domain_name" {
  description = "Route53 Alias 대상으로 사용할 CloudFront 기본 도메인"
  value       = try(aws_cloudfront_distribution.uploads[0].domain_name, null)
}

output "uploads_cloudfront_hosted_zone_id" {
  description = "Route53 Alias 대상으로 사용할 CloudFront Hosted Zone ID"
  value       = try(aws_cloudfront_distribution.uploads[0].hosted_zone_id, null)
}
