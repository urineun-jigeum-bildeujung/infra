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
# 이후 모듈 output 예시 (해당 module 활성화 시 주석 해제)
# =============================================================================
# output "eks_cluster_name" { value = module.eks.cluster_name }
# output "ecr_repository_urls" { value = module.ecr.repository_urls }
