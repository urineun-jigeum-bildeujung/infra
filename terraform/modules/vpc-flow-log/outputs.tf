# VPC Flow Log 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의

output "flow_log_id" {
  description = "생성된 VPC Flow Log의 ID"
  value       = aws_flow_log.this.id
}

output "s3_bucket_name" {
  description = "Flow Log가 저장되는 S3 Bucket 이름"
  value       = aws_s3_bucket.this.id
}
