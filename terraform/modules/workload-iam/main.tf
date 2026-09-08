# CNPG PostgreSQL Pod 의 S3 백업/복구 전용 IRSA. Operator Role 이 아니다.
data "aws_iam_policy_document" "cnpg_trust" {
  statement {
    sid     = "AllowCNPGServiceAccount"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${trimprefix(var.oidc_provider_url, "https://")}:sub"
      values   = ["system:serviceaccount:${var.cnpg_namespace}:${var.cnpg_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${trimprefix(var.oidc_provider_url, "https://")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cnpg_backup" {
  name               = "${var.project_name}-${var.environment}-cnpg-backup"
  description        = "CNPG Barman Cloud S3 backup and restore via IRSA"
  assume_role_policy = data.aws_iam_policy_document.cnpg_trust.json
}

data "aws_iam_policy_document" "cnpg_backup" {
  # HeadBucket 에는 s3:prefix 가 없으므로 전용 버킷의 목록 조회는 버킷 단위 허용.
  statement {
    sid       = "CheckAndListBackupBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.db_backups_bucket_arn]
  }

  statement {
    sid    = "ManageCNPGBackupObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      # Barman retention 정리용. Versioning 하에서 delete marker 를 생성한다.
      # DeleteObjectVersion 은 허용하지 않아 과거 버전 영구 삭제 권한은 주지 않는다.
      "s3:DeleteObject",
    ]
    resources = ["${var.db_backups_bucket_arn}/${var.cnpg_backup_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "cnpg_backup" {
  name   = "cnpg-backup-s3"
  role   = aws_iam_role.cnpg_backup.id
  policy = data.aws_iam_policy_document.cnpg_backup.json
}
