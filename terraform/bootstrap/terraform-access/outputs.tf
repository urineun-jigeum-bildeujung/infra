# terraform-access 스택이 노출하는 값 정의
# 이 값들은 GitHub Actions Workflow / 개발자 문서 등에서 참조한다.
#
# 예시:
#   output "github_actions_role_arn" { value = aws_iam_role.github_actions_terraform.arn }
#   output "developer_role_arn"      { value = aws_iam_role.developer_terraform.arn }
