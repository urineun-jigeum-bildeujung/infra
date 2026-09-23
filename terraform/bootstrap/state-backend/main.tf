# Terraform State 저장용 S3 Bucket 및 관련 보안 설정을 정의하는 파일
# 이 스택은 최초 1회만 생성하며, 이후에는 유지 목적으로만 관리한다.
#
# 주의: 이 Bucket 은 절대 terraform destroy 로 삭제하지 않는다.
#       lifecycle { prevent_destroy = true } 로 실수 삭제를 1차 차단하며,
#       Public Access Block / Versioning / SSE / TLS 강제 정책까지 함께 적용한다.

# Terraform State 저장용 S3 Bucket
resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  # 이 Bucket 은 어떠한 상황에서도 terraform destroy 로 삭제되면 안 된다.
  # 삭제가 실제로 필요하면 코드에서 lifecycle 블록을 제거한 뒤 별도로 진행한다.
  lifecycle {
    prevent_destroy = true
  }
}

# Public 접근 4가지 항목 모두 차단
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 버전 관리 활성화 - State 손상/실수 덮어쓰기 시 이전 버전으로 복구 가능
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 서버측 암호화 (SSE-S3, AES256)
# 감사/규제 요구가 생기면 SSE-KMS 로 전환하고 terraform-access 스택의
# 실행 Role 에 kms:Encrypt/Decrypt/GenerateDataKey/DescribeKey 를 추가한다.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# HTTPS(TLS) 이외의 모든 요청 거부
# State 파일은 반드시 암호화된 전송 채널로만 오가도록 강제한다.
data "aws_iam_policy_document" "tfstate_tls" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate_tls" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls.json
}

# TODO: AWS 계정 발급 후 실제 apply 로 아래 항목 검증
#   - S3 Bucket 생성 여부
#   - Public Access Block 4 항목 활성화
#   - Versioning Enabled
#   - Default Encryption (AES256) 적용
#   - HTTPS 강제 Bucket Policy 동작 (HTTP 요청 시 403)
#   - prevent_destroy 로 실수 삭제 방지 동작
