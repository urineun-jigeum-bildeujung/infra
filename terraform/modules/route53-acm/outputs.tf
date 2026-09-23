output "zone_id" {
  description = "Route53 Public Hosted Zone ID"
  value       = aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "도메인 등록기관에 등록할 Route53 권한 네임서버 4개"
  value       = aws_route53_zone.this.name_servers
}

output "acm_certificate_arn" {
  description = "ALB HTTPS Listener와 Ingress에서 사용할 ACM 인증서 ARN"
  value       = aws_acm_certificate_validation.this.certificate_arn
}
