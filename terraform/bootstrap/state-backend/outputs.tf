# State Backend 스택에서 다른 스택이 참조할 값들을 출력한다.
#
# 예시:
#   output "state_bucket_name" { value = aws_s3_bucket.tfstate.bucket }
#   output "state_bucket_arn"  { value = aws_s3_bucket.tfstate.arn    }
