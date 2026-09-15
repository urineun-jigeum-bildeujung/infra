# Hosted Zone과 ALB를 이름으로 조회한다. ALB DNS/Canonical Hosted Zone ID는
# 재생성 때 변경될 수 있으므로 코드나 tfvars에 고정하지 않는다.
data "aws_route53_zone" "public" {
  name         = "${var.domain_name}."
  private_zone = false
}

data "aws_lb" "web" {
  name = var.web_alb_name
}

resource "aws_route53_record" "web" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = data.aws_lb.web.dns_name
    zone_id                = data.aws_lb.web.zone_id
    evaluate_target_health = true
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = data.aws_lb.web.load_balancer_type == "application"
      error_message = "web_alb_name은 Application Load Balancer여야 합니다."
    }

    precondition {
      condition     = data.aws_lb.web.internal == false
      error_message = "Web Alias 대상은 internet-facing ALB여야 합니다."
    }

    precondition {
      condition     = lookup(data.aws_lb.web.tags, "ingress.k8s.aws/stack", "") == var.alb_ingress_stack
      error_message = "ALB의 ingress.k8s.aws/stack 태그가 기대값과 일치하지 않습니다."
    }

    precondition {
      condition     = lookup(data.aws_lb.web.tags, "elbv2.k8s.aws/cluster", "") == var.eks_cluster_name
      error_message = "ALB의 elbv2.k8s.aws/cluster 태그가 기대값과 일치하지 않습니다."
    }
  }
}
