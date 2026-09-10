# Tailscale Subnet Router 모듈
#
# AWS VPC 관리 트래픽 전용 Router를 Private Subnet에 배치한다.
# EC2에는 Public IP와 inbound 규칙을 두지 않고 SSM Session Manager로만 관리한다.
# Tailscale Auth Key는 Terraform State에 남기지 않기 위해 다루지 않으며,
# 인스턴스 생성 후 관리자가 SSM에서 `tailscale up`을 직접 실행한다.

locals {
  name = "${var.project_name}-${var.environment}-tailscale-router"
}

# Amazon Linux 2023 최신 x86_64 AMI는 AWS가 관리하는 Public Parameter로 조회한다.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    sid     = "AllowEC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "router" {
  name               = local.name
  description        = "SSM access role for the Petflow Tailscale subnet router"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.router.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "router" {
  name = local.name
  role = aws_iam_role.router.name
}

# Inbound 규칙은 의도적으로 만들지 않는다. SSH/RDP/Public 관리 포트를 열지 않고,
# SSM과 Tailscale 제어 서버 통신에 필요한 outbound만 NAT Gateway를 통해 허용한다.
resource "aws_security_group" "router" {
  name        = local.name
  description = "Outbound-only security group for the Tailscale subnet router"
  vpc_id      = var.vpc_id

  egress {
    description = "Tailscale, SSM and package installation through the NAT gateway"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = local.name
  }
}
# EKS Private API는 Router Security Group에서 들어오는 HTTPS만 추가 허용한다.
# 다른 관리 대상은 각 대상 Security Group에서 이 Router SG를 별도로 허용해야 한다.
resource "aws_vpc_security_group_ingress_rule" "eks_api_from_router" {
  security_group_id            = var.eks_cluster_security_group_id
  referenced_security_group_id = aws_security_group.router.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "EKS private API access from Tailscale subnet router"
}


resource "aws_instance" "router" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.private_subnet_id
  vpc_security_group_ids      = [aws_security_group.router.id]
  iam_instance_profile        = aws_iam_instance_profile.router.name
  associate_public_ip_address = false

  # Tailscale 기본 Subnet Router SNAT을 사용하므로 초기 구성에서는 AWS의
  # source/destination check를 유지한다. SNAT을 끄는 설계로 바꿀 때 재검토한다.
  source_dest_check = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  # Auth Key나 로그인 명령은 넣지 않는다. 설치와 IP Forwarding까지만 자동화한다.
  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    hostnamectl set-hostname "${local.name}"

    cat > /etc/sysctl.d/99-tailscale.conf <<'SYSCTL'
    net.ipv4.ip_forward = 1
    SYSCTL
    sysctl --system

    # Amazon Linux 2023은 curl-minimal에 curl 바이너리가 포함되어 있으므로
    # 일반 curl 패키지를 별도로 설치하지 않는다.
    command -v curl >/dev/null 2>&1 || dnf install -y curl-minimal

    curl -fsSL https://tailscale.com/install.sh | sh

    systemctl enable --now amazon-ssm-agent
    systemctl enable --now tailscaled

    # 관리자가 SSM 접속 후 명시적으로 실행하는 무인증 헬퍼다.
    # Auth Key를 포함하지 않으며 실행 시 브라우저 인증 URL이 출력된다.
    cat > /usr/local/sbin/petflow-tailscale-up <<'TAILSCALE_UP'
    #!/bin/bash
    exec tailscale up \
      --hostname="${local.name}" \
      --advertise-routes="${var.vpc_cidr}" \
      "$@"
    TAILSCALE_UP
    chmod 0755 /usr/local/sbin/petflow-tailscale-up
  EOT

  # User Data 변경이 실제 인스턴스에도 적용되도록 교체한다. 교체된 Router는
  # Tailnet 재인증과 Route 재승인이 필요하므로 plan에서 replacement를 확인한다.
  user_data_replace_on_change = true

  tags = {
    Name = local.name
    Role = "TailscaleSubnetRouter"
  }

  depends_on = [aws_iam_role_policy_attachment.ssm]
}
