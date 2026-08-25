# Dev 환경 Root Module 출력 값 정의
# 각 module 이 활성화되면 아래 예시처럼 노출한다.
#
# 예시:
#   output "vpc_id"           { value = module.network.vpc_id }
#   output "private_subnet_ids" { value = module.network.private_subnet_ids }
#   output "eks_cluster_name" { value = module.eks.cluster_name }
#   output "ecr_repository_urls" { value = module.ecr.repository_urls }
