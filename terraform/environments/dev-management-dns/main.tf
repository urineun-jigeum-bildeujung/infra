# 기존 별도 State를 유지하면서 Grafana Alias를 Public ALB로 전환한다.
# ALB DNS/Canonical Hosted Zone ID/VPC ID는 재생성될 수 있으므로 동적으로 조회한다.
data "aws_route53_zone" "public" {
  name         = "${var.domain_name}."
  private_zone = false
}

data "aws_eks_cluster" "current" {
  name = var.eks_cluster_name
}

data "aws_lb" "public" {
  name = var.public_alb_name
}

resource "aws_route53_record" "grafana" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = var.grafana_hostname
  type    = "A"

  alias {
    name                   = data.aws_lb.public.dns_name
    zone_id                = data.aws_lb.public.zone_id
    evaluate_target_health = true
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = data.aws_lb.public.load_balancer_type == "application"
      error_message = "Grafana Alias 대상은 Application Load Balancer여야 합니다."
    }

    precondition {
      condition     = data.aws_lb.public.internal == false
      error_message = "Grafana Alias 대상은 internet-facing ALB여야 합니다."
    }

    precondition {
      condition     = data.aws_lb.public.vpc_id == data.aws_eks_cluster.current.vpc_config[0].vpc_id
      error_message = "Public ALB와 현재 DEV EKS의 VPC가 일치하지 않습니다."
    }

    precondition {
      condition     = lookup(data.aws_lb.public.tags, "ingress.k8s.aws/stack", "") == var.public_alb_ingress_stack
      error_message = "ALB의 ingress.k8s.aws/stack 태그가 기대값과 일치하지 않습니다."
    }

    precondition {
      condition     = lookup(data.aws_lb.public.tags, "elbv2.k8s.aws/cluster", "") == var.eks_cluster_name
      error_message = "ALB의 elbv2.k8s.aws/cluster 태그가 기대값과 일치하지 않습니다."
    }
  }
}
