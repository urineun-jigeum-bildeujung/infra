output "trail_arn" {
  description = "생성된 CloudTrail ARN"
  value       = aws_cloudtrail.this.arn
}

output "s3_bucket_name" {
  description = "CloudTrail 로그가 저장되는 S3 Bucket 이름"
  value       = aws_s3_bucket.this.id
}

output "cloudwatch_log_group_name" {
  description = "CloudTrail 이벤트가 실시간 전달되는 CloudWatch Log Group 이름"
  value       = aws_cloudwatch_log_group.this.name
}
