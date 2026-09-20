output "grafana_url" {
  description = "인터넷에서 HTTPS와 로그인으로 접근하는 Grafana 주소"
  value       = "https://${var.grafana_hostname}"
}

output "public_alb_dns_name" {
  description = "Grafana가 재사용하는 Public ALB DNS 이름"
  value       = data.aws_lb.public.dns_name
}

output "public_alb_zone_id" {
  description = "Grafana가 재사용하는 Public ALB Canonical Hosted Zone ID"
  value       = data.aws_lb.public.zone_id
}

output "route53_zone_id" {
  description = "기존 Public Hosted Zone ID"
  value       = data.aws_route53_zone.public.zone_id
}
