# EKS 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의
# 이후 브랜치 (feat/iam 확장 - IRSA / feat/karpenter / gitops helm values) 등에서 참조한다.

# =============================================================================
# Cluster 기본 정보
# =============================================================================
output "cluster_name" {
  description = "EKS Cluster 이름"
  value       = aws_eks_cluster.main.name
}

output "cluster_arn" {
  description = "EKS Cluster ARN"
  value       = aws_eks_cluster.main.arn
}

output "cluster_endpoint" {
  description = "EKS API 서버 endpoint URL. kubectl config 에 사용."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "EKS Cluster 버전 (실제 적용된 값)"
  value       = aws_eks_cluster.main.version
}

output "cluster_certificate_authority_data" {
  description = "kubectl config 의 certificate-authority-data 로 사용할 값 (base64)"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS 가 자동 생성한 cluster security group ID"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

# =============================================================================
# OIDC Provider — 이후 IRSA Role 만들 때 필수
# =============================================================================
output "oidc_provider_arn" {
  description = "EKS OIDC Provider ARN. IRSA Role 의 신뢰 정책 principal 에 사용."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "EKS OIDC Issuer URL (https 접두어 제거된 형태). IRSA sub 조건 변수 이름에 사용. 예: <url>:sub"
  value       = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

# =============================================================================
# Node Group
# =============================================================================
output "node_group_arn" {
  description = "Managed Node Group ARN"
  value       = aws_eks_node_group.main.arn
}

output "node_group_name" {
  description = "Managed Node Group 이름"
  value       = aws_eks_node_group.main.node_group_name
}

# =============================================================================
# Add-on / IAM
# =============================================================================
output "ebs_csi_role_arn" {
  description = "EBS CSI Driver 가 Pod Identity 로 부여받는 IAM Role ARN"
  value       = aws_iam_role.ebs_csi.arn
}
