# CloudTrail 모듈: AWS 계정/리전 전체의 관리 API 호출(누가 무엇을 언제 호출했는지)을 감사 로그로 남긴다.
#
# 구성:
#   - S3 Bucket: 로그 장기보관 (Public 차단 + 암호화 + 라이프사이클 + 삭제/정책변경 제한)
#   - CloudWatch Logs: 실시간 조회/알림 연동용 (S3와 별도 보관기간)
#   - CloudTrail: is_multi_region_trail=true 로 단일 트레일이 전 리전 + 글로벌 서비스 이벤트까지 포괄
#
# Naming Rule: <project_name>-<environment>-cloudtrail

locals {
  resource_prefix = "${var.project_name}-${var.environment}-cloudtrail"
  bucket_name     = "${local.resource_prefix}-logs-${var.aws_account_id}"
}

# ---------------------------------------------------------------------------
# S3: 로그 저장 Bucket (s3 모듈과 동일한 보안 기본값 패턴)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name

  # 감사 로그는 실수로도 지워지면 안 되므로 강제 삭제를 허용하지 않는다.
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = local.bucket_name
    Purpose = "cloudtrail-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# 라이프사이클: var.s3_retention_days 경과 시 만료
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-cloudtrail-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.s3_retention_days
    }
  }
}

# ---------------------------------------------------------------------------
# Bucket Policy: CloudTrail 쓰기 허용 + 삭제/정책변경 제한
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "bucket_policy" {
  # CloudTrail 서비스가 계정 로그 경로에 로그 파일을 쓸 수 있도록 허용 (AWS 필수 정책)
  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/AWSLogs/${var.aws_account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.this.arn]
  }

  # 관리자 IAM User/Role(var.allowed_admin_role_arns) 외에는 로그 삭제/버킷 정책·라이프사이클 변경을 차단한다.
  # allowed_admin_role_arns는 variables.tf에서 비어 있지 않은 IAM User/Role ARN 목록만
  # 허용한다. 따라서 빈 NotPrincipal을 AWS에 전송하기 전에 Plan 단계에서 실패한다.
  statement {
    sid    = "DenyLogTamperingByNonAdmins"
    effect = "Deny"

    # 버킷 정책(Resource-based Policy)에서는 Principal을 생략하고 NotPrincipal만
    # 단독으로 써야 "예외 목록 제외 전체"를 의미한다. 둘을 같이 쓰면 AWS가
    # MalformedPolicy(Statement already has instance of Principal)로 거부한다.
    not_principals {
      type        = "AWS"
      identifiers = var.allowed_admin_role_arns
    }

    actions = [
      "s3:DeleteObject",
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:PutLifecycleConfiguration",
    ]

    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket_policy.json

  # Public Access Block의 block_public_policy와의 경합을 피하기 위해 순서를 보장한다.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------------------
# CloudWatch Logs: 실시간 조회/알림 연동용
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/cloudtrail/${local.resource_prefix}"
  retention_in_days = var.cloudwatch_log_retention_days
}

data "aws_iam_policy_document" "cloudtrail_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudtrail_to_cloudwatch" {
  name = "${local.resource_prefix}-to-cloudwatch"
  # IAM Role description은 Latin-1 범위만 허용(정규식 [\t\n\r\x20-\x7E\xA1-\xFF]*)되어 한글을 쓸 수 없다.
  description        = "Allows CloudTrail to deliver events to CloudWatch Logs in real time"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume_role.json
}

data "aws_iam_policy_document" "cloudtrail_to_cloudwatch" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail_to_cloudwatch" {
  name   = "${local.resource_prefix}-to-cloudwatch"
  role   = aws_iam_role.cloudtrail_to_cloudwatch.id
  policy = data.aws_iam_policy_document.cloudtrail_to_cloudwatch.json
}

# ---------------------------------------------------------------------------
# CloudTrail 본체
# ---------------------------------------------------------------------------

resource "aws_cloudtrail" "this" {
  name           = local.resource_prefix
  s3_bucket_name = aws_s3_bucket.this.id

  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = var.enable_log_file_validation

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.this.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_to_cloudwatch.arn

  tags = {
    Name = local.resource_prefix
  }

  depends_on = [aws_s3_bucket_policy.this]
}
