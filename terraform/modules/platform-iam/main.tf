# Platform IAM 모듈: EKS 위에서 동작하는 플랫폼 컴포넌트(Pod)가 AWS API 를 호출할 수 있도록
# IAM Role 을 만들고 EKS Pod Identity 로 연결한다.
#
# ★ 방식: EKS Pod Identity (신방식) 로 통일한다.
#   - 기존 EBS CSI Driver (modules/eks) 와 동일한 패턴
#   - IRSA/OIDC 방식의 Trust Policy 와 eks.amazonaws.com/role-arn ServiceAccount
#     annotation 은 사용하지 않는다.
#   - GitOps 팀은 Helm 설치 시 아래 고정된 namespace / ServiceAccount 이름만 맞추면 된다.
#
# ★ GitOps 팀과의 인터페이스 (고정):
#   | 컴포넌트                     | namespace   | ServiceAccount               |
#   |------------------------------|-------------|------------------------------|
#   | AWS Load Balancer Controller | kube-system | aws-load-balancer-controller |
#   | Karpenter                    | kube-system | karpenter                    |
#
# 관리 대상 (DEV 생명주기 — destroy/apply 반복 가능):
#   - ALB Controller: Role + 공식 Policy + Pod Identity Association
#   - Karpenter Controller: Role + Policy + Pod Identity Association
#   - Karpenter Node Role: Karpenter 가 생성하는 Worker 노드용 (Managed Node Group Role 과 분리)
#     + EKS Access Entry (EC2_LINUX) — API 인증 모드에서 노드가 클러스터에 join 하기 위해 필수
#
# 이번 범위에서 제외:
#   - External Secrets Operator — Secrets Manager 구조와 GitOps 설치 범위 확정 후 추가
#   - Karpenter Interruption Queue (SQS) — Spot 중단 대응이 필요해지면 추가

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# =============================================================================
# 공통: Pod Identity 신뢰 정책
# =============================================================================
# EKS Pod Identity Agent 가 Pod 를 대신해 이 Role 을 assume 한다.
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    sid     = "AllowPodIdentityAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# =============================================================================
# AWS Load Balancer Controller
# =============================================================================
# Ingress / Service(LoadBalancer) 리소스를 보고 실제 ALB/NLB 를 생성·관리한다.
resource "aws_iam_role" "alb_controller" {
  name               = "${local.name_prefix}-alb-controller"
  description        = "Role for AWS Load Balancer Controller via EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

# 공식 IAM Policy (kubernetes-sigs/aws-load-balancer-controller 리포의 iam_policy.json 원본).
# Controller 버전 업그레이드 시 정책도 갱신이 필요할 수 있다 — policies/ 파일을 교체한다.
resource "aws_iam_policy" "alb_controller" {
  name        = "${local.name_prefix}-alb-controller"
  description = "Official IAM policy for AWS Load Balancer Controller"
  policy      = file("${path.module}/policies/alb-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.alb_controller.arn
}

# =============================================================================
# Karpenter — Node Role (Karpenter 가 만드는 Worker 노드가 사용)
# =============================================================================
# Managed Node Group 의 Role(petflow-eks-node) 과 의도적으로 분리한다.
#   - 권한 변경/삭제 영향 범위를 Karpenter 노드로 한정
#   - CloudTrail 등에서 노드 출처(Managed vs Karpenter) 구분 용이
# Instance Profile 은 Terraform 으로 만들지 않는다 — Karpenter v1 은 EC2NodeClass 의
# role 필드에 이 Role 이름을 받아 Instance Profile 을 스스로 생성·관리한다.
data "aws_iam_policy_document" "karpenter_node_trust" {
  statement {
    sid     = "AllowEC2Assume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  name               = "${local.name_prefix}-karpenter-node"
  description        = "Role for worker nodes provisioned by Karpenter (separate from the managed node group role)"
  assume_role_policy = data.aws_iam_policy_document.karpenter_node_trust.json
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # Karpenter 노드는 SSM 기반 접속/관리를 기본으로 한다 (SSH 키 불필요)
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

# API 인증 모드에서는 노드 Role 을 Access Entry 로 등록해야 노드가 클러스터에 join 할 수 있다.
# (Managed Node Group 은 EKS 가 자동 등록해주지만 Karpenter 노드는 명시적 등록이 필요)
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# =============================================================================
# Karpenter — Controller Role (Karpenter Pod 가 사용)
# =============================================================================
resource "aws_iam_role" "karpenter_controller" {
  name               = "${local.name_prefix}-karpenter-controller"
  description        = "Role for the Karpenter controller via EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

# Karpenter v1 컨트롤러가 필요로 하는 권한.
# 공식 getting-started CloudFormation 을 기반으로 DEV 수준에서 실용적으로 정리했다.
# 운영 전환 시 리소스 태그 조건 등으로 더 좁히는 것을 검토한다.
data "aws_iam_policy_document" "karpenter_controller" {
  # 노드 생성/삭제 및 조회
  statement {
    sid    = "EC2NodeManagement"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeImages",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeSpotPriceHistory",
    ]
    resources = ["*"]
  }

  # AMI 별칭 해석(SSM public parameter) 및 인스턴스 가격 조회
  statement {
    sid    = "AmiAndPricingLookup"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "pricing:GetProducts",
    ]
    resources = ["*"]
  }

  # Karpenter 노드에 Node Role 을 넘겨주기 위한 PassRole (해당 Role 로 한정)
  statement {
    sid       = "PassNodeRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.karpenter_node.arn]
  }

  # Karpenter v1 은 EC2NodeClass 기반으로 Instance Profile 을 스스로 생성/관리한다.
  # ListInstanceProfiles 는 최근 버전 공식 정책에서 명시적으로 요구되는 권한이며
  # 리소스 조건을 지원하지 않아 "*" 대상이다.
  statement {
    sid    = "ManageInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:ListInstanceProfiles",
    ]
    resources = ["*"]
  }

  # 자기 클러스터 정보 조회
  statement {
    sid       = "DescribeCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }
}

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${local.name_prefix}-karpenter-controller"
  description = "Permissions for the Karpenter controller (node provisioning, AMI lookup, instance profile management)"
  policy      = data.aws_iam_policy_document.karpenter_controller.json
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn
}
