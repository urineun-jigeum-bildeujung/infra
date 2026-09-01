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
