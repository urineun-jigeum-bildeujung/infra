# 지정된 태그가 있는 EBS Volume만 AWS Backup으로 보호한다.
# CNPG StorageClass가 같은 backup_tag_key/value를 EBS에 부여해야 한다.

locals {
  resource_prefix = "${var.project_name}-${var.environment}-cnpg-ebs"
}

data "aws_iam_policy_document" "backup_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${local.resource_prefix}-backup"
  description        = "AWS Backup service role for tagged CNPG EBS volumes"
  assume_role_policy = data.aws_iam_policy_document.backup_assume_role.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_vault" "this" {
  name          = local.resource_prefix
  force_destroy = false
}

# Governance Mode Vault Lock. changeable_for_days를 지정하지 않아 Compliance
# Mode로 전환하지 않으며, 권한 있는 관리자는 구성을 변경할 수 있다. Lock이
# 활성화된 동안에는 최소 보존기간 전 Recovery Point 직접 삭제를 차단한다.
resource "aws_backup_vault_lock_configuration" "this" {
  backup_vault_name  = aws_backup_vault.this.name
  min_retention_days = var.retention_days
}

resource "aws_backup_plan" "this" {
  name = "${local.resource_prefix}-daily"

  rule {
    rule_name         = "daily-tagged-cnpg-ebs"
    target_vault_name = aws_backup_vault.this.name
    schedule          = var.schedule
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.retention_days
    }

    recovery_point_tags = {
      DataClass = "cnpg-ebs-snapshot"
      Source    = var.backup_tag_value
    }
  }
}

resource "aws_backup_selection" "this" {
  name         = "${local.resource_prefix}-tagged-volumes"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn

  # Resource ARN으로 EBS만 제한하고 태그 조건을 AND로 적용한다.
  resources = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:volume/*"]

  condition {
    string_equals {
      key   = "aws:ResourceTag/${var.backup_tag_key}"
      value = var.backup_tag_value
    }
  }

  depends_on = [aws_iam_role_policy_attachment.backup]
}
