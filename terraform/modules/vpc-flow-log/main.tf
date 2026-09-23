# VPC Flow Log 모듈: VPC 내 모든 트래픽(허용/거부)을 S3에 기록한다.
#
# 구성:
#   - S3 Bucket: 로그 장기보관 (Public 차단 + 암호화 + 라이프사이클 + 삭제/정책변경 제한)
#   - VPC Flow Log: traffic_type=ALL, max_aggregation_interval=600(10분) 로 VPC 전체를 대상으로 활성화
#
# CloudTrail 모듈과 달리 CloudWatch Logs 목적지는 두지 않는다(S3 단독) — Flow Log는
# 로그량이 훨씬 커서 CloudWatch 이중화 시 비용 부담이 크고, 목적도 실시간 조회보다는
# 감사 기록 보관(사후 조회)에 가깝기 때문이다.
#
# Naming Rule: <project_name>-<environment>-vpc-flow-log

locals {
  resource_prefix = "${var.project_name}-${var.environment}-vpc-flow-log"
  bucket_name     = "${local.resource_prefix}-logs-${var.aws_account_id}"
}

# ---------------------------------------------------------------------------
# S3: 로그 저장 Bucket (CloudTrail 모듈과 동일한 보안 기본값 패턴)
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
    Purpose = "vpc-flow-log"
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
    id     = "expire-vpc-flow-log"
    status = "Enabled"

    filter {}

    expiration {
      days = var.s3_retention_days
    }
  }
}

# ---------------------------------------------------------------------------
# Bucket Policy: Flow Log 쓰기 허용 + 삭제/정책변경 제한
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "bucket_policy" {
  # Flow Log 배송 서비스가 계정/리전 로그 경로에 로그 파일을 쓸 수 있도록 허용 (AWS 필수 정책)
  # SourceAccount/SourceArn 조건으로 "우리 계정의, 우리 VPC Flow Log"만 쓸 수 있도록 이중 제한한다.
  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/AWSLogs/${var.aws_account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:vpc-flow-log/*"]
    }
  }

  statement {
    sid    = "AWSLogDeliveryCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:vpc-flow-log/*"]
    }
  }

  # CreateFlowLogs API가 S3 대상 구성 시 Bucket Policy에 자동 추가하는 서비스 관리 문장.
  # 코드에서 함께 관리하여 다음 plan에서 해당 문장이 삭제되는 드리프트를 방지한다.
  statement {
    sid    = "AWSLogDeliveryWrite1"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/AWSLogs/${var.aws_account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.aws_region}:${var.aws_account_id}:*"]
    }
  }

  statement {
    sid    = "AWSLogDeliveryAclCheck1"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.this.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.aws_region}:${var.aws_account_id}:*"]
    }
  }

  # 관리자 IAM User/Role(var.allowed_admin_role_arns) 외에는 로그 삭제/버킷 정책·라이프사이클 변경을 차단한다.
  # CloudTrail 모듈은 NotPrincipal 단독 문법을 쓰지만, 이 버킷은 VPC Flow Log 목적지라
  # EC2가 생성 시점에 버킷 정책을 자체 검증하는데 그 로직이 NotPrincipal-only statement를
  # 파싱하지 못하고 "MalformedPolicy: Missing required field Principal"로 실패한다
  # (실제 aws_flow_log apply 중 확인됨). 그래서 여기서는 와일드카드 Principal +
  # Condition(ArnNotEquals)으로 같은 의미("예외 목록 제외 전체 차단")를 표현한다 —
  # 모든 statement에 Principal 필드가 존재하게 되어 EC2 검증도 통과한다.
  statement {
    sid    = "DenyLogTamperingByNonAdmins"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = var.allowed_admin_role_arns
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
# VPC Flow Log 본체
# ---------------------------------------------------------------------------

resource "aws_flow_log" "this" {
  vpc_id = var.vpc_id

  traffic_type             = "ALL"
  max_aggregation_interval = 600

  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.this.arn

  tags = {
    Name = local.resource_prefix
  }

  depends_on = [aws_s3_bucket_policy.this]
}
