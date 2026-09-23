# terraform-access 스택이 노출하는 값 정의
# 이 값들은 GitHub Actions Workflow / 팀 공유 문서 등에서 참조한다.

output "github_actions_role_arn" {
  description = "GitHub Actions workflow 에서 aws-actions/configure-aws-credentials 의 role-to-assume 로 사용할 값"
  value       = aws_iam_role.github_actions_terraform.arn
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC Identity Provider ARN. 향후 다른 GitHub 리포에서 재사용 시 참고."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "terraform_state_access_policy_arn" {
  description = "Terraform State/.tflock 접근용 Policy ARN. 향후 개발자 Role 등에 동일 Policy 를 attach 할 때 사용."
  value       = aws_iam_policy.terraform_state_access.arn
}

output "route53_delete_protection_policy_arn" {
  description = "보호 대상 Route53 Hosted Zone의 삭제를 명시적으로 거부하는 IAM Policy ARN"
  value       = aws_iam_policy.route53_delete_protection.arn
}


output "terraform_execution_role_arn" {
  description = "승인된 팀원이 로컬 Terraform 실행 시 Assume할 공용 Role ARN"
  value       = aws_iam_role.terraform_execution.arn
}

output "terraform_execution_assume_policy_arn" {
  description = "승인된 IAM 사용자에게 연결되는 공용 Terraform Role Assume Policy ARN"
  value       = aws_iam_policy.terraform_execution_assume.arn
}
