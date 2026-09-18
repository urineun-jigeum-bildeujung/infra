output "grafana_url" {
  description = "Tailscale 연결 후 사용할 Grafana HTTPS 주소"
  value       = "https://${var.grafana_hostname}"
}

output "prometheus_url" {
  description = "Tailscale 연결 후 사용할 Prometheus HTTPS 주소"
  value       = "https://${var.prometheus_hostname}"
}

output "management_alb_dns_name" {
  description = "현재 Management Internal ALB DNS 이름"
  value       = data.aws_lb.management.dns_name
}

output "management_alb_zone_id" {
  description = "현재 Management Internal ALB Canonical Hosted Zone ID"
  value       = data.aws_lb.management.zone_id
}

output "route53_zone_id" {
  description = "기존 Public Hosted Zone ID"
  value       = data.aws_route53_zone.public.zone_id
}
