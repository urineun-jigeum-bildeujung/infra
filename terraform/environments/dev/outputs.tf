# Dev 환경 Root Module 출력 값 정의
# 각 module 이 활성화되면 그 module 의 output 을 여기서 pass-through 한다.

# =============================================================================
# Network
# =============================================================================
output "vpc_id" {
  description = "Dev 환경 VPC ID"
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "Dev 환경 VPC CIDR"
  value       = module.network.vpc_cidr
}

output "public_subnet_ids" {
  description = "Dev 환경 Public Subnet ID 목록"
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Dev 환경 Private Subnet ID 목록. EKS Cluster/Node Group 이 사용한다."
  value       = module.network.private_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "Dev 환경 NAT Gateway 의 Elastic IP 목록. 외부 서비스에 outbound IP 를 화이트리스트 할 때 참고."
  value       = module.network.nat_gateway_public_ips
}

# =============================================================================
# IAM
# =============================================================================
output "eks_cluster_role_arn" {
  description = "EKS control plane Role ARN. feat/eks 의 aws_eks_cluster 가 이 값을 참조."
  value       = module.iam.eks_cluster_role_arn
}

output "eks_node_role_arn" {
  description = "EKS Worker Node Role ARN. feat/eks 의 aws_eks_node_group 이 이 값을 참조."
  value       = module.iam.eks_node_role_arn
}

# =============================================================================
# EKS
# =============================================================================
output "eks_cluster_name" {
  description = "EKS Cluster 이름 (kubectl update-kubeconfig 명령에 사용)"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API 서버 endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_version" {
  description = "실제 배포된 EKS 버전"
  value       = module.eks.cluster_version
}

output "eks_oidc_provider_arn" {
  description = "EKS OIDC Provider ARN. 이후 IRSA Role 생성 시 modules/iam 에 전달."
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider_url" {
  description = "EKS OIDC Issuer URL (https 접두어 제거됨)"
  value       = module.eks.oidc_provider_url
}

output "eks_ebs_csi_role_arn" {
  description = "EBS CSI Driver 가 사용하는 IAM Role ARN (Pod Identity 부착됨)"
  value       = module.eks.ebs_csi_role_arn
}

# kubectl 접근 헬퍼 — output 확인 후 이 명령으로 kubeconfig 갱신
#   aws eks update-kubeconfig --name <cluster_name> --region <region> --alias petflow-dev

# =============================================================================
# Platform IAM (ALB Controller / Karpenter — Pod Identity)
# =============================================================================
output "alb_controller_role_arn" {
  description = "ALB Controller Role ARN (Pod Identity: kube-system/aws-load-balancer-controller)"
  value       = module.platform_iam.alb_controller_role_arn
}

output "karpenter_controller_role_arn" {
  description = "Karpenter Controller Role ARN (Pod Identity: kube-system/karpenter)"
  value       = module.platform_iam.karpenter_controller_role_arn
}

output "karpenter_node_role_name" {
  description = "Karpenter Worker 노드용 Role 이름. GitOps 의 EC2NodeClass spec.role 에 사용."
  value       = module.platform_iam.karpenter_node_role_name
}

# =============================================================================
# ECR
# =============================================================================
output "ecr_repository_urls" {
  description = "서비스별 ECR Repository URL map. CI 의 push 대상 / Helm values 의 이미지 경로에 사용."
  value       = module.ecr.repository_urls
}

# =============================================================================
# S3 (애플리케이션용)
# =============================================================================
output "s3_bucket_names" {
  description = "용도별 애플리케이션 S3 Bucket 이름 map. 앱 환경변수 설정에 사용."
  value       = module.s3.bucket_names
}

output "s3_bucket_arns" {
  description = "용도별 애플리케이션 S3 Bucket ARN map. 애플리케이션 IAM 정책 작성에 사용."
  value       = module.s3.bucket_arns
}
