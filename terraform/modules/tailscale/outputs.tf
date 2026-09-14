output "instance_id" {
  description = "SSM Session Manager 접속에 사용할 Tailscale Router EC2 ID"
  value       = aws_instance.router.id
}

output "private_ip" {
  description = "Tailscale Router EC2 Private IP"
  value       = aws_instance.router.private_ip
}

output "security_group_id" {
  description = "Tailscale Router 전용 outbound-only Security Group ID"
  value       = aws_security_group.router.id
}

output "iam_role_name" {
  description = "Tailscale Router가 SSM 접속에 사용하는 IAM Role 이름"
  value       = aws_iam_role.router.name
}

output "state_parameter_name" {
  description = "tailscaled가 Machine Identity를 직접 관리하는 SSM Parameter 이름"
  value       = local.tailscale_state_parameter_name
}

output "state_parameter_arn" {
  description = "Router IAM Role과 tailscaled --state에 사용하는 SSM Parameter ARN"
  value       = local.tailscale_state_parameter_arn
}
