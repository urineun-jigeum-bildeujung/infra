# IAM 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의
#
# 예시:
#   output "eks_cluster_role_arn" { value = aws_iam_role.eks_cluster.arn }
#   output "eks_node_role_arn"    { value = aws_iam_role.eks_node.arn }
