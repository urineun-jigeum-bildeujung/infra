# S3 모듈: 애플리케이션에서 사용하는 S3 Bucket 을 정의한다.
#
# 용도별 Bucket (var.bucket_purposes 로 관리):
#   - static         : Frontend 정적 파일
#   - product-images : 상품 이미지
#   - uploads        : 사용자 업로드 파일
#
# Naming Rule:
#   <project_name>-<environment>-<용도>   예: petflow-dev-static
#   S3 Bucket 이름은 전역 유일해야 하므로 프로젝트/환경 접두사로 충돌을 피한다.
#
# 주의:
#   Terraform State 저장용 S3 Bucket 은 terraform/bootstrap/state-backend 에서 별도로 관리한다.
#   이 모듈에서 만드는 Bucket 은 절대 State 저장 용도로 사용하지 않는다.
#
# 보안 기본값 (state-backend 와 동일 패턴):
#   - Public Access Block 4항목 모두 차단
#   - AES256 서버측 암호화
#   - HTTPS(TLS) 이외 요청 거부 Bucket Policy
#
# 이번 브랜치에서 하지 않는 것:
#   - CORS 설정 — 프론트 직접 업로드 도메인이 확정되면 추가한다.
#   - CloudFront 연동 — 정적 파일 CDN 이 필요해지는 시점에 별도 브랜치에서 진행한다.

locals {
  # 용도 → 실제 Bucket 이름 map
  buckets = { for p in var.bucket_purposes : p => "${var.project_name}-${var.environment}-${p}" }
}

resource "aws_s3_bucket" "app" {
  for_each = local.buckets

  bucket = each.value

  # DEV 는 반복 destroy/apply 를 전제로 하므로 객체가 있어도 삭제 가능하게 둔다.
  force_destroy = var.force_destroy

  tags = {
    Name    = each.value
    Purpose = each.key
  }
}

# Public 접근 4가지 항목 모두 차단
resource "aws_s3_bucket_public_access_block" "app" {
  for_each = aws_s3_bucket.app

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 서버측 암호화 (SSE-S3, AES256)
resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  for_each = aws_s3_bucket.app

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning — DEV 기본 비활성 (var.enable_versioning=true 일 때만 리소스 생성)
resource "aws_s3_bucket_versioning" "app" {
  for_each = var.enable_versioning ? aws_s3_bucket.app : {}

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

# HTTPS(TLS) 이외의 모든 요청 거부
data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.app

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      each.value.arn,
      "${each.value.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tls_only" {
  for_each = aws_s3_bucket.app

  bucket = each.value.id
  policy = data.aws_iam_policy_document.tls_only[each.key].json

  # Public Access Block 의 block_public_policy 와의 경합을 피하기 위해 순서를 보장한다.
  depends_on = [aws_s3_bucket_public_access_block.app]
}
