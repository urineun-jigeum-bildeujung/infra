# Terraform 실행 기반 IAM 을 정의하는 스택
#
# 관리 대상:
#   - GitHub Actions Terraform OIDC Role (신뢰: repo:<org>/<repo>:*)
#   - GitHub OIDC Identity Provider
#   - State Backend (S3 Bucket + .tflock) 접근 Policy
#   - 프로젝트 인프라 관리 권한 (초기 단계: AdministratorAccess, 추후 축소 TODO)
#   - (선택) Terraform 을 실행하는 개발자용 IAM Role  ← 이번 스켈레톤에는 미포함
#
# ⚠️ 이 스택의 리소스는 DEV 인프라의 terraform destroy 대상이 아니다.
#    최초 1회 생성 후 계속 유지하며, 함부로 삭제하지 않는다.
#
# -----------------------------------------------------------------------------
# [체크리스트] Terraform 실행 주체(GitHub Actions OIDC Role, 개발자 Role 등)에
# 반드시 부여해야 하는 State Backend 관련 IAM 권한
#
# S3 Backend 의 native state locking(use_lockfile = true) 을 사용하므로
# lock 파일(<state_key>.tflock) 에 대한 별도 권한이 필요하다.
# DeleteObject 가 빠지면 lock 이 해제되지 않아 다음 apply 가 무한 대기하거나
# lock 획득에 실패한다.
#
# 최소 요구 권한 예시 (dev 환경 기준):
#
#   # State 파일 자체
#   {
#     "Effect": "Allow",
#     "Action": ["s3:GetObject", "s3:PutObject"],
#     "Resource": "arn:aws:s3:::<STATE_BUCKET>/dev/terraform.tfstate"
#   },
#
#   # Lock 파일 (native locking 전용)
#   {
#     "Effect": "Allow",
#     "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
#     "Resource": "arn:aws:s3:::<STATE_BUCKET>/dev/terraform.tfstate.tflock"
#   },
#
#   # Bucket 리스팅
#   {
#     "Effect": "Allow",
#     "Action": "s3:ListBucket",
#     "Resource": "arn:aws:s3:::<STATE_BUCKET>"
#   }
#
# State Bucket 을 SSE-KMS 로 암호화한 경우, 위 권한에 더해 대상 KMS Key 에
# kms:Encrypt / kms:Decrypt / kms:GenerateDataKey / kms:DescribeKey 도 필요하다.
# -----------------------------------------------------------------------------

# 공통 값
locals {
  # GitHub Actions 신뢰 대상 subject 패턴.
  # repo:<org>/<repo>:* 로 두면 해당 리포지토리의 모든 브랜치 / PR / 태그 워크플로에서 사용 가능하다.
  # 특정 브랜치로만 제한하려면 예: "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/dev"
  github_actions_subject = "repo:${var.github_org}/${var.github_repo}:*"

  # State Bucket ARN — Policy 리소스 지정에 반복 사용
  state_bucket_arn = "arn:aws:s3:::${var.state_bucket_name}"

  # 이 프로젝트가 사용할 State Key 목록.
  # 새 환경/스택이 늘어나면 이 목록에 State Key 를 추가하기만 하면 접근 권한이 자동으로 확장된다.
  managed_state_keys = [
    "bootstrap/terraform-access/terraform.tfstate",
    "dev/terraform.tfstate",
  ]
}

# =============================================================================
# GitHub Actions OIDC Provider
# =============================================================================
# 참고: 2023년부터 AWS 는 GitHub OIDC 요청 검증 시 자체 유지하는 신뢰할 수 있는
# CA 목록을 우선 사용하므로 thumbprint 값이 실제 검증에서 결정적이지는 않다.
# 다만 aws_iam_openid_connect_provider 리소스 자체는 thumbprint_list 를 필수로 요구하므로
# GitHub Actions OIDC 의 널리 알려진 thumbprint 두 개를 그대로 지정한다.
# 필요 시 hashicorp/tls 프로바이더의 data "tls_certificate" 로 실시간 조회하도록 대체 가능하다.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# =============================================================================
# GitHub Actions 용 Terraform 실행 Role
# =============================================================================
# 신뢰 정책: 지정된 GitHub 리포지토리의 워크플로만 이 Role 을 assume 가능.
# aud 조건은 aws-actions/configure-aws-credentials 액션이 발급하는 토큰의 audience 값이다.
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    sid     = "AllowGitHubOIDCFromRepo"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_actions_subject]
    }
  }
}

resource "aws_iam_role" "github_actions_terraform" {
  name        = "${var.project_name}-github-actions-terraform"
  description = "GitHub Actions 에서 이 프로젝트의 Terraform apply / destroy 를 실행하기 위한 Role"

  assume_role_policy   = data.aws_iam_policy_document.github_actions_trust.json
  max_session_duration = 3600
}

# =============================================================================
# State S3 / .tflock 접근 Policy
# =============================================================================
data "aws_iam_policy_document" "terraform_state_access" {
  # Bucket 자체 리스팅 권한 (Terraform 이 backend init 시 필요)
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  # State 파일 read/write
  statement {
    sid    = "ReadWriteStateObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]

    resources = [for key in local.managed_state_keys : "${local.state_bucket_arn}/${key}"]
  }

  # Lock 파일 (<state_key>.tflock) read/write/delete
  # DeleteObject 가 반드시 있어야 apply 종료 시 lock 이 정상 해제된다.
  statement {
    sid    = "ManageStateLockObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [for key in local.managed_state_keys : "${local.state_bucket_arn}/${key}.tflock"]
  }
}

resource "aws_iam_policy" "terraform_state_access" {
  name        = "${var.project_name}-terraform-state-access"
  description = "Terraform State S3 및 .tflock 파일 접근용 Policy (Bucket 리스팅 + State read/write + Lock read/write/delete)"
  policy      = data.aws_iam_policy_document.terraform_state_access.json
}

resource "aws_iam_role_policy_attachment" "github_actions_state_access" {
  role       = aws_iam_role.github_actions_terraform.name
  policy_arn = aws_iam_policy.terraform_state_access.arn
}

# =============================================================================
# 프로젝트 인프라 관리 권한
# =============================================================================
# TODO: 초기 단계에서는 AdministratorAccess 로 광범위하게 열어두었다.
#       프로젝트가 안정화되고 사용하는 리소스 범위가 확정되면
#       VPC/EKS/IAM/ECR/S3/ELB 등에 대한 최소 권한 Policy 로 축소한다.
#       예: PowerUserAccess + IAMFullAccess 조합, 또는 커스텀 최소 권한 세트.
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# TODO: AWS 계정 발급 후 실제 apply 로 아래 항목 검증
#   - OIDC Provider 정상 생성 (Console → IAM → Identity providers)
#   - Role 신뢰 정책이 지정 리포 sub 패턴을 정확히 매칭하는지 (GitHub Actions dry-run)
#   - State Access Policy 로 실제 backend init / apply / destroy 가 lock 이슈 없이 완료되는지
#   - DEV 인프라의 apply / destroy 반복 후에도 이 스택의 리소스는 그대로 유지되는지
