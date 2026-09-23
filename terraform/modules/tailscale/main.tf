# Tailscale Subnet Router 모듈
#
# AWS VPC 관리 트래픽 전용 Router를 Private Subnet에 배치한다.
# EC2에는 Public IP와 inbound 규칙을 두지 않고 SSM Session Manager로만 관리한다.
# OAuth Secret 값과 Tailscale State 값은 Terraform State/User Data에 넣지 않는다.
# 최초 등록 시에만 Secrets Manager에서 OAuth Secret을 조회하고, 이후 Machine
# Identity는 tailscaled가 AWS SSM Parameter Store에 직접 저장하고 복구한다.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  name = "${var.project_name}-${var.environment}-tailscale-router"

  tailscale_state_parameter_name = "/${var.project_name}/${var.environment}/tailscale/router-state"
  tailscale_state_parameter_arn = format(
    "arn:%s:ssm:%s:%s:parameter%s",
    data.aws_partition.current.partition,
    var.aws_region,
    data.aws_caller_identity.current.account_id,
    local.tailscale_state_parameter_name,
  )
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

# tailscaled가 Machine Identity를 SecureString Parameter로 직접 생성/갱신한다.
# Parameter 값은 Terraform resource로 관리하지 않아 State 노출과 drift를 피한다.
data "aws_iam_policy_document" "tailscale_state" {
  statement {
    sid    = "ReadWriteTailscaleState"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:PutParameter",
    ]

    resources = [local.tailscale_state_parameter_arn]
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

resource "aws_iam_role_policy" "tailscale_state" {
  name   = "${local.name}-state"
  role   = aws_iam_role.router.id
  policy = data.aws_iam_policy_document.tailscale_state.json
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

  # Secret/State 값은 User Data에 포함하지 않는다. tailscaled는 SSM ARN만 전달받아
  # State를 직접 복구하고, Parameter가 없을 때만 OAuth Secret으로 최초 등록한다.
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

    # 설치 스크립트가 기본 로컬 State로 daemon을 시작했을 수 있으므로 중지한 뒤,
    # package unit을 직접 수정하지 않고 SSM State Backend override를 적용한다.
    systemctl stop tailscaled || true
    install -d -m 0755 /etc/systemd/system/tailscaled.service.d

    cat > /etc/systemd/system/tailscaled.service.d/10-persistent-state.conf <<'SYSTEMD'
    [Service]
    ExecStart=
    ExecStart=/usr/sbin/tailscaled --state=${local.tailscale_state_parameter_arn} --socket=/run/tailscale/tailscaled.sock --port=$${PORT} $FLAGS
    SYSTEMD

    systemctl daemon-reload

    # Parameter 값은 조회하지 않는다. 기존 Identity 유무만 metadata 조회로 판단한다.
    # IAM eventual consistency와 일시적인 SSM 오류는 재시도하되, ParameterNotFound만
    # 최초 등록으로 취급한다.
    STATE_PARAMETER_EXISTS=false
    STATE_CHECK_ERROR="/run/petflow-tailscale-state-check.err"
    trap 'rm -f "$${STATE_CHECK_ERROR}"' EXIT

    for attempt in $(seq 1 18); do
      if aws ssm get-parameter \
        --name "${local.tailscale_state_parameter_name}" \
        --region "${var.aws_region}" \
        --query 'Parameter.Name' \
        --output text >/dev/null 2>"$${STATE_CHECK_ERROR}"; then
        STATE_PARAMETER_EXISTS=true
        break
      fi

      if grep -q 'ParameterNotFound' "$${STATE_CHECK_ERROR}"; then
        break
      fi

      if ((attempt == 18)); then
        echo "Tailscale State Parameter metadata를 확인하지 못했습니다." >&2
        exit 1
      fi
      sleep 10
    done

    rm -f "$${STATE_CHECK_ERROR}"
    trap - EXIT

    systemctl enable --now tailscaled

    if [[ "$${STATE_PARAMETER_EXISTS}" == "true" ]]; then
      # State가 있는데 복구하지 못하면 OAuth fallback을 금지한다. 권한 오류/State
      # 손상 시 중복 Machine Identity가 생성되는 것을 방지하기 위한 fail-closed 동작이다.
      for attempt in $(seq 1 18); do
        if tailscale status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
          echo "Existing Tailscale identity restored from SSM."
          exit 0
        fi

        if ! systemctl is-active --quiet tailscaled; then
          systemctl restart tailscaled
        fi

        if ((attempt == 18)); then
          echo "기존 Tailscale State를 SSM에서 복구하지 못했습니다. OAuth 재등록은 수행하지 않습니다." >&2
          exit 1
        fi
        sleep 10
      done
    fi

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

    # 최초 daemon 시작은 빈 Parameter(Version 1)를 만들 수 있다. OAuth 등록 후
    # Backend가 Running이고 Version이 2 이상이어야 실제 Identity 저장으로 판단한다.
    for attempt in $(seq 1 18); do
      STATE_PARAMETER_VERSION=$(aws ssm get-parameter \
        --name "${local.tailscale_state_parameter_name}" \
        --region "${var.aws_region}" \
        --query 'Parameter.Version' \
        --output text 2>/dev/null || true)

      if tailscale status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"' && \
        [[ "$${STATE_PARAMETER_VERSION}" =~ ^[0-9]+$ ]] && \
        ((STATE_PARAMETER_VERSION >= 2)); then
        exit 0
      fi

      if ((attempt == 18)); then
        echo "최초 Tailscale Identity가 SSM에 저장되지 않았습니다." >&2
        exit 1
      fi
      sleep 10
    done
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
    aws_iam_role_policy.tailscale_state,
  ]
}
