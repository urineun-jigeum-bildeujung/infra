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
#   | Jenkins Kaniko                | jenkins     | jenkins-kaniko               |
#   | External Secrets Operator    | external-secrets | external-secrets        |
#   | Trivy Operator                | trivy-system | trivy-operator              |
#   | recommendation (모델 아티팩트 읽기) | recommendation | generic-service        |
#
# 관리 대상 (DEV 생명주기 — destroy/apply 반복 가능):
#   - ALB Controller: Role + 공식 Policy + Pod Identity Association
#   - Karpenter Controller: Role + Policy + Pod Identity Association
#   - Karpenter Node Role: Karpenter 가 생성하는 Worker 노드용 (Managed Node Group Role 과 분리)
#     + EKS Access Entry (EC2_LINUX) — API 인증 모드에서 노드가 클러스터에 join 하기 위해 필수
#   - Jenkins Kaniko: ECR Push/Pull 최소 권한 Role + Policy + Pod Identity Association
#   - External Secrets Operator: Secrets Manager 읽기 Role + Policy + Pod Identity Association
#   - Trivy Operator: ECR Pull-only 최소 권한 Role + Policy + Pod Identity Association
#     (지금까지 이 Role 이 없어서 petflow 자체 이미지 취약점 스캔이 전부 401로 실패하고
#     있었음 — 재시도만 반복되며 NAT 트래픽만 낭비. 이번에 신설)
#   - recommendation: ml-artifacts S3 Bucket의 recommendation/* prefix만 읽는
#     최소 권한 Role + Policy + Pod Identity Association. DeepFM 모델 파일을
#     이미지에 넣지 않고 기동 시 S3에서 받아오는 방식으로 전환하면서 신설
#     (2026-10-01, AI팀 요청 — 모델 아티팩트가 어디에도 없어 추천 API가 전부
#     500으로 실패하던 문제의 해결책).
#
# 이번 범위에서 제외:
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
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeCapacityReservations",
      "ec2:DescribePlacementGroups",
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

# =============================================================================
# Jenkins Kaniko — ECR Push Role
# =============================================================================
# Jenkins가 생성하는 Kaniko Build Pod는 고정 ServiceAccount를 사용하며,
# EKS Pod Identity를 통해 프로젝트 ECR Repository에만 이미지를 Push/Pull한다.
resource "aws_iam_role" "jenkins_kaniko" {
  name               = "${local.name_prefix}-jenkins-kaniko"
  description        = "Role for Jenkins Kaniko pods to push images to project ECR repositories"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "jenkins_ecr" {
  # ECR 인증 토큰은 Repository ARN 단위 제한을 지원하지 않는다.
  statement {
    sid       = "GetECRAuthorizationToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # 실제 이미지 Push/Pull 권한은 이 프로젝트의 Repository로 제한한다.
  statement {
    sid    = "PushPullPetflowRepositories"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}/*",
    ]
  }
}

resource "aws_iam_policy" "jenkins_ecr" {
  name        = "${local.name_prefix}-jenkins-ecr"
  description = "Permissions for Jenkins Kaniko to push and pull project ECR images"
  policy      = data.aws_iam_policy_document.jenkins_ecr.json
}

resource "aws_iam_role_policy_attachment" "jenkins_ecr" {
  role       = aws_iam_role.jenkins_kaniko.name
  policy_arn = aws_iam_policy.jenkins_ecr.arn
}

resource "aws_eks_pod_identity_association" "jenkins_kaniko" {
  cluster_name    = var.cluster_name
  namespace       = "jenkins"
  service_account = "jenkins-kaniko"
  role_arn        = aws_iam_role.jenkins_kaniko.arn
}

# =============================================================================
# External Secrets Operator — Secrets Manager Read Role
# =============================================================================
resource "aws_iam_role" "external_secrets" {
  name               = "${local.name_prefix}-external-secrets"
  description        = "Role for External Secrets Operator via EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "ReadPetflowSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/*",
    ]
  }
}

resource "aws_iam_policy" "external_secrets" {
  name        = "${local.name_prefix}-external-secrets"
  description = "Read-only access for External Secrets Operator to project secrets"
  policy      = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}

# =============================================================================
# Trivy Operator — ECR Pull-only Role
# =============================================================================
# Trivy Operator 의 스캔 Job 은 kubelet 이 아니라 별도 Pod 로 떠서 이미지를 직접
# Pull 하기 때문에, 워커 노드의 IAM Role(kubelet 용)과는 별개로 자체 ECR 인증이
# 필요하다. 지금까지 이 Role 자체가 없어서(ServiceAccount 에 아무 Pod Identity 도
# 안 붙어 있었음) petflow/* 이미지 스캔이 전부 401 Unauthorized 로 실패하고,
# Standalone 모드의 재시도 로직(OPERATOR_SCAN_JOB_RETRY_AFTER)이 계속 반복
# 호출하면서 NAT 트래픽만 낭비하고 있었다 — 취약점 스캔 자체는 한 번도 성공한
# 적이 없는 상태였음.
#
# 이미지를 Push 할 일은 없으므로 Pull 권한만 부여한다. 다른 서비스처럼
# repository ARN을 이 프로젝트(petflow/*)로 제한한다 — 이 Role 로는 EKS 관리형
# 애드온 이미지(602401143452 계정의 kube-proxy 등)는 원래도 못 읽는다(크로스
# 계정이라 이 정책 범위 밖) — 그건 gitops 쪽에서 스캔 대상 자체를 제외한다.
resource "aws_iam_role" "trivy_operator" {
  name               = "${local.name_prefix}-trivy-operator"
  description        = "Read-only role for Trivy Operator to pull project ECR images for scanning"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "trivy_operator_ecr" {
  # ECR 인증 토큰은 Repository ARN 단위 제한을 지원하지 않는다.
  statement {
    sid       = "GetECRAuthorizationToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullPetflowRepositories"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}/*",
    ]
  }
}

resource "aws_iam_policy" "trivy_operator_ecr" {
  name        = "${local.name_prefix}-trivy-operator-ecr"
  description = "Read-only access for Trivy Operator to pull project ECR images"
  policy      = data.aws_iam_policy_document.trivy_operator_ecr.json
}

resource "aws_iam_role_policy_attachment" "trivy_operator_ecr" {
  role       = aws_iam_role.trivy_operator.name
  policy_arn = aws_iam_policy.trivy_operator_ecr.arn
}

resource "aws_eks_pod_identity_association" "trivy_operator" {
  cluster_name    = var.cluster_name
  namespace       = "trivy-system"
  service_account = "trivy-operator"
  role_arn        = aws_iam_role.trivy_operator.arn
}

# =============================================================================
# recommendation — 모델 아티팩트 S3 읽기
# =============================================================================
# DeepFM 모델(feature_encoder.json 등)을 이미지에 포함하지 않고, 파드 기동 시
# S3에서 내려받는 방식으로 전환한다. ml-artifacts Bucket 전체가 아니라
# recommendation/* prefix만 읽을 수 있게 범위를 제한한다 — 다른 서비스가
# 쓰게 될 prefix(향후)까지 이 Role로 읽을 수 없어야 한다.
resource "aws_iam_role" "recommendation_model_reader" {
  name               = "${local.name_prefix}-recommendation-model-reader"
  description        = "Read-only role for recommendation service to download model artifacts from S3"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "recommendation_model_reader" {
  statement {
    sid       = "ListMlArtifactsRecommendationPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.ml_artifacts_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["recommendation/*"]
    }
  }

  statement {
    sid       = "GetMlArtifactsRecommendationObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.ml_artifacts_bucket_arn}/recommendation/*"]
  }
}

resource "aws_iam_policy" "recommendation_model_reader" {
  name        = "${local.name_prefix}-recommendation-model-reader"
  description = "Read-only access to the recommendation/* prefix of the ml-artifacts bucket"
  policy      = data.aws_iam_policy_document.recommendation_model_reader.json
}

resource "aws_iam_role_policy_attachment" "recommendation_model_reader" {
  role       = aws_iam_role.recommendation_model_reader.name
  policy_arn = aws_iam_policy.recommendation_model_reader.arn
}

resource "aws_eks_pod_identity_association" "recommendation_model_reader" {
  cluster_name    = var.cluster_name
  namespace       = "recommendation"
  service_account = "generic-service"
  role_arn        = aws_iam_role.recommendation_model_reader.arn
}
