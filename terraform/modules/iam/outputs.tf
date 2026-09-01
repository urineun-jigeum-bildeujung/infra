# IAM 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의
# feat/eks 브랜치의 aws_eks_cluster / aws_eks_node_group 리소스가 이 값들을 참조한다.

output "eks_cluster_role_arn" {
  description = "EKS control plane 이 사용할 Role ARN"
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_cluster_role_name" {
  description = "EKS control plane Role 이름"
  value       = aws_iam_role.eks_cluster.name
}

output "eks_node_role_arn" {
  description = "EKS Managed Node Group EC2 인스턴스가 사용할 Role ARN"
  value       = aws_iam_role.eks_node.arn
}

output "eks_node_role_name" {
  description = "EKS Managed Node Group Role 이름"
  value       = aws_iam_role.eks_node.name
}
