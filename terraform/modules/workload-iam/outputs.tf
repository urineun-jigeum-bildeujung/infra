output "cnpg_backup_role_arn" {
  description = "CNPG Pod Identity Association에 연결된 S3 백업 Role ARN"
  value       = aws_iam_role.cnpg_backup.arn
}

output "cnpg_backup_pod_identity_association_id" {
  description = "CNPG PostgreSQL Pod용 EKS Pod Identity Association ID"
  value       = aws_eks_pod_identity_association.cnpg_backup.association_id
}

output "cnpg_additional_pod_identity_association_ids" {
  description = "복원 검증용 추가 CNPG ServiceAccount별 Pod Identity Association ID"
  value = {
    for name, association in aws_eks_pod_identity_association.cnpg_backup_additional :
    name => association.association_id
  }
}
