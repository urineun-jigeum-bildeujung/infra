output "cnpg_backup_role_arn" {
  description = "GitOps Cluster.spec.serviceAccountTemplate.metadata.annotations 의 eks.amazonaws.com/role-arn 값"
  value       = aws_iam_role.cnpg_backup.arn
}
