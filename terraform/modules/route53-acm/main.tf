# Route53 / ACM 모듈 - Phase 1
#
# 먼저 Route53 Public Hosted Zone만 생성한다. 생성 후 출력되는 NS 4개를
# 도메인 등록기관(카페24)에 등록하고 위임 전파를 확인한 뒤 ACM을 추가한다.

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
