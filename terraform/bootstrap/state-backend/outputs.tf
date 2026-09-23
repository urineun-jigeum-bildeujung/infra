# State Backend 스택이 다른 스택에서 참조할 값을 노출한다.
# terraform-access 스택의 IAM Policy 등에서 이 값을 재사용한다.
# (참조 방식은 backend.hcl 로 하드코딩하거나, terraform_remote_state data 로 조회할 수 있다.)

output "state_bucket_name" {
  description = "Terraform State 저장용 S3 Bucket 이름"
  value       = aws_s3_bucket.tfstate.bucket
}

output "state_bucket_arn" {
  description = "Terraform State 저장용 S3 Bucket ARN"
  value       = aws_s3_bucket.tfstate.arn
}

output "state_bucket_region" {
  description = "State Bucket 이 생성된 AWS 리전"
  value       = var.aws_region
}
