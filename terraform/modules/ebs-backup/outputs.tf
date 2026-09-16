output "backup_vault_name" {
  description = "CNPG EBS Recovery Point를 보관하는 AWS Backup Vault 이름"
  value       = aws_backup_vault.this.name
}

output "backup_plan_id" {
  description = "CNPG EBS 일일 Backup Plan ID"
  value       = aws_backup_plan.this.id
}

output "backup_role_arn" {
  description = "예약/온디맨드 EBS 백업과 복원에 사용하는 AWS Backup Role ARN"
  value       = aws_iam_role.backup.arn
}

output "backup_selection_id" {
  description = "태그 기반 EBS Backup Selection ID"
  value       = aws_backup_selection.this.id
}

output "backup_tag" {
  description = "CNPG StorageClass가 EBS에 부여해야 하는 선택 태그"
  value = {
    key   = var.backup_tag_key
    value = var.backup_tag_value
  }
}
