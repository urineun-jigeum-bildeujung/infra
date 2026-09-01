# EKS 모듈: 쿠버네티스 컨트롤 플레인 및 워커 노드 관련 리소스를 정의한다.
#
# 관리 대상 (이번 브랜치 feat/eks):
#   - EKS Cluster (control plane)
#   - Managed Node Group
#   - EKS OIDC Provider (향후 IRSA 사용을 위해 미리 생성)
#   - EKS Access Entry + Access Policy Association (kubectl 접근 권한)
#   - EKS Add-on 5종:
#       coredns, kube-proxy, vpc-cni, eks-pod-identity-agent, aws-ebs-csi-driver
#   - EBS CSI Driver 전용 IAM Role (Pod Identity 방식으로 부착)
#
# ❌ 이번 브랜치에서 하지 않는 것 (이후 별도 브랜치):
#   - IRSA Role for ALB Controller / Karpenter / External Secrets Operator / App
#     → modules/iam 에 var.eks_oidc_provider_arn 을 받아 확장 예정
#   - AWS Load Balancer Controller / Karpenter / ArgoCD 등의 Helm 설치는
#     gitops repo 담당

# =============================================================================
# EKS Cluster
# =============================================================================
resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-eks"
  version  = var.cluster_version
  role_arn = var.cluster_role_arn

  vpc_config {
    # control plane 이 통신할 subnet. private + public 모두 포함해 endpoint 두 모드 지원.
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
    public_access_cidrs     = var.public_access_cidrs
  }

  # 인증 방식: API (Access Entry) — 신방식. aws-auth ConfigMap 은 사용하지 않는다.
  # bootstrap_cluster_creator_admin_permissions=true 로 두면
  # 최초 apply 하는 IAM 이 자동으로 admin 이 되어 안전장치가 된다.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = {
    Name = "${var.project_name}-eks"
  }
}

# =============================================================================
# EKS OIDC Provider (IRSA 및 Pod Identity 이외 통합 목적)
# =============================================================================
# EKS Cluster 는 각자의 OIDC issuer URL 을 가진다. 이를 AWS IAM OIDC Provider 로
# 등록해두면, 향후 ServiceAccount 에 IRSA Role 을 붙일 수 있다.
# 참고: 2023년 이후 AWS 는 OIDC 토큰 검증 시 자체 신뢰 CA 를 사용하므로
# thumbprint 값 자체가 결정적이지 않지만 리소스 필수 필드라 널리 알려진 값을 사용한다.
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
}

# =============================================================================
# Managed Node Group
# =============================================================================
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-node-group"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.node_instance_types
  ami_type       = var.node_ami_type
  capacity_type  = "ON_DEMAND"
  disk_size      = var.node_disk_size

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  # cluster 가 준비된 뒤 node group 생성
  depends_on = [aws_eks_cluster.main]

  tags = {
    Name = "${var.project_name}-node-group"
  }

  # Node Group 의 desired_size 는 오토스케일러(향후 Karpenter 등) 로도 변경되므로
  # Terraform 이 이후 drift 로 감지해 되돌리지 않도록 무시한다.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# =============================================================================
# Access Entry — kubectl 접근 권한
# =============================================================================
# var.cluster_admin_principal_arns 목록의 IAM User/Role 을 EKS 에 등록하고
# AmazonEKSClusterAdminPolicy 를 cluster scope 로 붙인다.
resource "aws_eks_access_entry" "cluster_admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "cluster_admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.cluster_admin]
}

# =============================================================================
# EBS CSI Driver IAM Role (Pod Identity 방식)
# =============================================================================
# EBS CSI 컨트롤러가 AWS EBS API 를 호출해서 PV 를 provisioning 하려면
# IAM 권한이 필요하다. 신방식인 EKS Pod Identity 를 사용한다.
data "aws_iam_policy_document" "ebs_csi_trust" {
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

resource "aws_iam_role" "ebs_csi" {
  name = "${var.project_name}-ebs-csi-driver"
  # AWS IAM description 은 ASCII+Latin-1 만 허용 (한글 금지)
  description        = "IAM role for the EBS CSI driver controller service account via EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

# =============================================================================
# EKS Add-ons
# =============================================================================
# addon_version 을 명시하지 않으면 EKS 가 cluster_version 과 호환되는 기본 최신 안정 버전을 자동 선택.
# 특정 버전 고정 필요 시 addon_version 인자 추가.

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
  # kube-proxy 는 DaemonSet 이지만 노드가 없어도 등록만 되면 되므로 node group 의존 없음
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
  # 초기에는 node role 에 AmazonEKS_CNI_Policy 가 붙어있어 별도 IRSA/Pod Identity 없이 동작
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  # coredns 는 Deployment 라 실제 스케줄될 노드가 있어야 함
  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
  # DaemonSet, 노드가 있어야 실제로 뜨지만 등록은 언제든 가능
  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"

  # Pod Identity 로 IAM 권한 부착이 준비된 뒤에 addon 을 설치해야
  # 컨트롤러가 처음부터 AWS API 호출 가능하다.
  depends_on = [
    aws_eks_node_group.main,
    aws_eks_pod_identity_association.ebs_csi,
    aws_eks_addon.pod_identity_agent,
  ]
}
