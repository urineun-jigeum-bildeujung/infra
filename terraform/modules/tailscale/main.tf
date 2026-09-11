# Tailscale Subnet Router 모듈
#
# AWS VPC 관리 트래픽 전용 Router를 Private Subnet에 배치한다.
# EC2에는 Public IP와 inbound 규칙을 두지 않고 SSM Session Manager로만 관리한다.
# OAuth Secret 값은 Terraform State/User Data에 넣지 않고 Router가 부팅할 때
# Secrets Manager에서 직접 조회하여 Tailnet에 자동 등록한다.

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

data "aws_iam_policy_document" "tailscale_secret" {
  statement {
    sid       = "ReadTailscaleOAuthSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.tailscale_oauth_secret_arn]
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

resource "aws_iam_role_policy" "tailscale_secret" {
  name   = "${local.name}-secret"
  role   = aws_iam_role.router.id
  policy = data.aws_iam_policy_document.tailscale_secret.json
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

  # Secret 값은 User Data에 포함하지 않는다. 부팅 시 IAM Role로 Secrets Manager에서
  # 조회하고 root만 읽을 수 있는 임시 파일을 통해 Tailscale에 전달한다.
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail

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

    OAUTH_SECRET_FILE="/run/petflow/tailscale-oauth-secret"
    install -d -m 0700 /run/petflow
    umask 077
    trap 'rm -f "$${OAUTH_SECRET_FILE}" "$${OAUTH_SECRET_FILE}.tmp"' EXIT

    # Instance Profile/IAM Policy의 eventual consistency를 고려해 최대 3분 재시도한다.
    for attempt in $(seq 1 18); do
      if aws secretsmanager get-secret-value \
        --secret-id "${var.tailscale_oauth_secret_arn}" \
        --region "${var.aws_region}" \
        --query SecretString \
        --output text | tr -d '\r\n' > "$${OAUTH_SECRET_FILE}.tmp"; then
        mv "$${OAUTH_SECRET_FILE}.tmp" "$${OAUTH_SECRET_FILE}"
        break
      fi

      rm -f "$${OAUTH_SECRET_FILE}.tmp"
      if ((attempt == 18)); then
        echo "Tailscale OAuth Secret을 조회하지 못했습니다." >&2
        exit 1
      fi
      sleep 10
    done

    printf '%s\n' '?ephemeral=false&preauthorized=true' >> "$${OAUTH_SECRET_FILE}"

    tailscale up \
      --auth-key="file:$${OAUTH_SECRET_FILE}" \
      --hostname="${local.name}" \
      --advertise-tags="tag:petflow-router" \
      --advertise-routes="${var.vpc_cidr}"

    rm -f "$${OAUTH_SECRET_FILE}"
    trap - EXIT
  EOT

  # User Data 변경이 실제 인스턴스에도 적용되도록 교체한다.
  user_data_replace_on_change = true

  tags = {
    Name = local.name
    Role = "TailscaleSubnetRouter"
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.tailscale_secret,
  ]
}
