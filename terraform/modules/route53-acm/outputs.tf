output "zone_id" {
  description = "Route53 Public Hosted Zone ID"
  value       = aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "도메인 등록기관에 등록할 Route53 권한 네임서버 4개"
  value       = aws_route53_zone.this.name_servers
}
