mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "cnpg_ebs_backup_selects_only_tagged_volumes" {
  command = plan

  module {
    source = "../../modules/ebs-backup"
  }

  variables {
    project_name     = "petflow"
    environment      = "dev"
    aws_region       = "ap-northeast-2"
    aws_account_id   = "297165773875"
    backup_tag_key   = "PetflowBackup"
    backup_tag_value = "petflow-cnpg"
    schedule         = "cron(0 19 * * ? *)"
    retention_days   = 7
  }

  assert {
    condition = toset(aws_backup_selection.this.resources) == toset([
      "arn:aws:ec2:ap-northeast-2:297165773875:volume/*",
    ])
    error_message = "Backup Selection은 대상 Account/Region의 EBS ARN으로 제한되어야 합니다."
  }

  assert {
    condition = alltrue(flatten([
      for condition in aws_backup_selection.this.condition : [
        for rule in condition.string_equals :
        rule.key == "aws:ResourceTag/PetflowBackup" && rule.value == "petflow-cnpg"
      ]
    ]))
    error_message = "Backup Selection은 CNPG 전용 태그를 AND 조건으로 사용해야 합니다."
  }

  assert {
    condition = alltrue([
      for rule in aws_backup_plan.this.rule :
      rule.schedule == "cron(0 19 * * ? *)" && alltrue([
        for lifecycle in rule.lifecycle : lifecycle.delete_after == 7
      ])
    ])
    error_message = "Backup Plan은 매일 04:00 KST 일정과 7일 보관 정책을 사용해야 합니다."
  }

  assert {
    condition     = aws_backup_vault.this.force_destroy == false
    error_message = "Recovery Point가 남은 Backup Vault를 강제로 삭제하면 안 됩니다."
  }
}

run "cnpg_restore_service_account_uses_the_same_s3_role" {
  command = plan

  module {
    source = "../../modules/workload-iam"
  }

  variables {
    project_name              = "petflow"
    environment               = "dev"
    cluster_name              = "petflow-eks"
    db_backups_bucket_arn     = "arn:aws:s3:::petflow-dev-db-backups"
    cnpg_namespace            = "database"
    cnpg_service_account_name = "petflow-db"
    cnpg_backup_prefix        = "cnpg"
    additional_service_account_names = [
      "petflow-db-restore",
    ]
  }

  assert {
    condition = (
      keys(aws_eks_pod_identity_association.cnpg_backup_additional) == ["petflow-db-restore"] &&
      aws_eks_pod_identity_association.cnpg_backup_additional["petflow-db-restore"].cluster_name == "petflow-eks" &&
      aws_eks_pod_identity_association.cnpg_backup_additional["petflow-db-restore"].namespace == "database"
    )
    error_message = "복원 CNPG ServiceAccount는 운영 Cluster와 같은 S3 Role을 사용해야 합니다."
  }
}
