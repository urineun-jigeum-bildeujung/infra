# Argo CD와 Jenkins가 공유하는 Internal ALB의 frontend Security Group이다.
# Tailscale Subnet Router는 기본 SNAT를 사용하므로 ALB가 보는 AWS 소스 ENI에는
# Router SG가 연결된다. IP 대신 SG를 참조해 Router EC2 재생성에도 규칙을 유지한다.
resource "aws_security_group" "management_alb" {
  count = var.enable_tailscale_router ? 1 : 0

  name        = "${var.project_name}-${var.environment}-management-alb"
  description = "HTTPS to the management ALB from the Tailscale subnet router only"
  vpc_id      = module.network.vpc_id

  tags = {
    Name    = "${var.project_name}-${var.environment}-management-alb"
    Purpose = "ManagementALBFrontend"
  }
}

resource "aws_vpc_security_group_ingress_rule" "management_alb_https_from_tailscale" {
  count = var.enable_tailscale_router ? 1 : 0

  security_group_id            = aws_security_group.management_alb[0].id
  referenced_security_group_id = module.tailscale[0].security_group_id
  description                  = "HTTPS from the Tailscale subnet router"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# ALB에서 Pod IP로 나가는 규칙이다. Backend inbound는 AWS Load Balancer
# Controller가 manage-backend-security-group-rules=true로 관리한다.
resource "aws_vpc_security_group_egress_rule" "management_alb_ipv4" {
  count = var.enable_tailscale_router ? 1 : 0

  security_group_id = aws_security_group.management_alb[0].id
  description       = "Management ALB egress to Kubernetes targets"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
