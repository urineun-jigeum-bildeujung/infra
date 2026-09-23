output "web_url" {
  description = "DEV Web HTTPS 주소"
  value       = "https://${var.domain_name}"
}

output "web_alb_dns_name" {
  description = "현재 Web Public ALB DNS 이름"
  value       = data.aws_lb.web.dns_name
}

output "route53_zone_id" {
  description = "기존 Public Hosted Zone ID"
  value       = data.aws_route53_zone.public.zone_id
}
