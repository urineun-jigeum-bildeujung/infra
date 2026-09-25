output "management_alb_security_group_id" {
  description = "Tailscale Router SG에서만 HTTPS를 허용하는 Management ALB frontend SG ID"
  value       = try(aws_security_group.management_alb[0].id, null)
}

output "management_alb_security_group_name" {
  description = "AWS Load Balancer Controller Ingress가 동적으로 찾는 Management ALB frontend SG 이름"
  value       = try(aws_security_group.management_alb[0].name, null)
}
