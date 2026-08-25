# EKS 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의
#
# 예시:
#   output "cluster_name"     { value = aws_eks_cluster.main.name }
#   output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
#   output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.eks.arn }
