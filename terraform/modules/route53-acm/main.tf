# Route53 / ACM 모듈
#
# Route53 Public Hosted Zone과 루트/와일드카드 도메인용 ACM 인증서를 관리한다.

resource "aws_route53_zone" "this" {
  name = var.domain_name

  # 도메인 위임은 DEV 인프라보다 생명주기가 길다. 일반적인 destroy나
  # 모듈 제거로 Hosted Zone이 실수로 삭제되지 않도록 보호한다.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = var.domain_name
  }
}

resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = var.domain_name
  }
}

# ACM은 루트 도메인과 해당 와일드카드 도메인에 동일한 DNS 검증 토큰을
# 발급한다. 동일한 Route53 CNAME을 두 리소스가 중복 관리하지 않도록
# 루트 도메인의 검증 옵션으로 레코드 하나만 생성한다.
resource "aws_route53_record" "acm_validation" {
  zone_id = aws_route53_zone.this.zone_id
  name = one([
    for option in aws_acm_certificate.this.domain_validation_options :
    option.resource_record_name if option.domain_name == var.domain_name
  ])
  type = one([
    for option in aws_acm_certificate.this.domain_validation_options :
    option.resource_record_type if option.domain_name == var.domain_name
  ])
  ttl = 300
  records = [one([
    for option in aws_acm_certificate.this.domain_validation_options :
    option.resource_record_value if option.domain_name == var.domain_name
  ])]
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [aws_route53_record.acm_validation.fqdn]
}
