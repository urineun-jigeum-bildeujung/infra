# IAM 모듈: DEV 애플리케이션 / 플랫폼 인프라에서 사용하는 IAM Role 및 Policy 를 정의한다.
#
# 이 모듈이 생성하는 IAM 은 DEV 인프라와 동일한 생명주기를 갖는다.
# 즉 terraform destroy 로 함께 삭제되어도 무방하며, terraform apply 로 다시 생성된다.
#
# 관리 대상 (DEV 삭제 대상):
#   [이번 브랜치 feat/iam]
#   - EKS Cluster Role   (control plane 이 사용)
#   - EKS Worker Node Role  (Managed Node Group EC2 인스턴스가 사용)
#
#   [feat/eks 이후에 확장 예정 — OIDC Provider 가 필요한 IRSA Role]
#   - AWS Load Balancer Controller Role
#   - Karpenter Role
#   - External Secrets Operator Role
#   - 애플리케이션용 IAM Role
#
# ❌ 이 모듈에서 관리하지 않는 것 (Bootstrap 영역):
#   - Terraform 실행용 개발자 Role
#   - GitHub Actions Terraform OIDC Role
#   - State Backend (S3 Bucket / .tflock) 접근 Policy
#
#   위 리소스들은 DEV destroy 대상이 되면 안 되므로
#   terraform/bootstrap/terraform-access/ 스택에서 별도로 관리한다.

# =============================================================================
# EKS Cluster Role
# =============================================================================
# EKS control plane (관리형 서비스) 이 AWS 리소스를 조작할 때 사용하는 Role.
# 신뢰 대상은 eks.amazonaws.com 서비스 principal.
data "aws_iam_policy_document" "eks_cluster_trust" {
  statement {
    sid     = "AllowEKSAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-eks-cluster"
  # AWS IAM description 필드는 ASCII + Latin-1 만 허용하므로 영어로 작성한다.
  description        = "Role assumed by the EKS control plane to manage AWS resources on behalf of the cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_trust.json
}

# EKS 가 control plane 을 운영하기 위한 최소 AWS 관리 정책.
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# VPC ENI / Security Group 관리를 EKS 가 수행할 수 있도록 부여.
resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# =============================================================================
# EKS Worker Node Role
# =============================================================================
# Managed Node Group 의 EC2 인스턴스가 부여받는 Instance Profile 의 Role.
# kubelet, VPC CNI, ECR pull 등을 위해 필요한 권한을 붙인다.
data "aws_iam_policy_document" "eks_node_trust" {
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

resource "aws_iam_role" "eks_node" {
  name               = "${var.project_name}-eks-node"
  description        = "Role attached to EKS managed worker nodes (EC2 instance profile) for kubelet, CNI, and ECR pull"
  assume_role_policy = data.aws_iam_policy_document.eks_node_trust.json
}

# kubelet 이 EKS control plane 과 통신하고 로그/메트릭을 보고하기 위한 권한.
resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# VPC CNI 플러그인이 Pod 에 ENI/IP 를 할당하기 위한 권한.
# (IRSA 방식으로 옮기려면 이 attachment 를 해제하고 vpc-cni ServiceAccount 에 IRSA Role 부착)
resource "aws_iam_role_policy_attachment" "eks_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# 노드가 ECR 에서 컨테이너 이미지를 pull 하기 위한 권한.
resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# =============================================================================
# (예약) IRSA Role — feat/eks 에서 OIDC Provider 생성 후 이 모듈에 확장 추가 예정
# =============================================================================
# 아래와 같이 var.eks_oidc_provider_arn / var.eks_oidc_provider_url 을 받아
# aws-load-balancer-controller, karpenter 등의 IRSA Role 을 만들 예정이다.
# 예시:
#
#   data "aws_iam_policy_document" "alb_controller_trust" {
#     statement {
#       actions = ["sts:AssumeRoleWithWebIdentity"]
#       principals {
#         type        = "Federated"
#         identifiers = [var.eks_oidc_provider_arn]
#       }
#       condition {
#         test     = "StringEquals"
#         variable = "${var.eks_oidc_provider_url}:sub"
#         values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
#       }
#     }
#   }
