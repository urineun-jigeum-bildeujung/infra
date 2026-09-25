output "argocd_url" {
  description = "Tailscale 연결 상태에서 접근하는 Argo CD HTTPS 주소"
  value       = "https://${var.argocd_hostname}"
}

output "jenkins_url" {
  description = "Tailscale 연결 상태에서 접근하는 Jenkins HTTPS 주소"
  value       = "https://${var.jenkins_hostname}"
}

output "management_alb_dns_name" {
  description = "Argo CD와 Jenkins가 공유하는 Internal ALB DNS 이름"
  value       = data.aws_lb.management.dns_name
}

output "management_alb_zone_id" {
  description = "Management Internal ALB Canonical Hosted Zone ID"
  value       = data.aws_lb.management.zone_id
}
