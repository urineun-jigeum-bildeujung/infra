# S3 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의
#
# 예시:
#   output "static_bucket_name" { value = aws_s3_bucket.static.bucket }
#   output "upload_bucket_name" { value = aws_s3_bucket.upload.bucket }
