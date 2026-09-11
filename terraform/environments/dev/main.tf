# Dev 환경 Root Module
#
# 이 파일은 terraform/modules/ 하위의 각 모듈을 호출하여 Dev 환경 인프라를 조립한다.
# 실제 리소스는 각 모듈 내부에서 정의하며, 여기서는 모듈 호출과 값 전달만 담당한다.

locals {
  # 기존 tfvars를 사용하는 팀원도 CNPG 백업 Bucket을 빠뜨리지 않도록 root에서 보장한다.
  dev_s3_bucket_purposes = distinct(concat(var.s3_bucket_purposes, ["db-backups"]))
}

module "network" {
  source = "../../modules/network"

  project_name         = var.project_name
  aws_region           = var.aws_region
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
}

# Windows 관리자 PC에서 Tailscale을 통해 VPC 관리 자원에 접근하기 위한
# 전용 Subnet Router. Private Subnet에 배치하고 SSM으로만 관리한다.
module "tailscale" {
  count  = var.enable_tailscale_router ? 1 : 0
  source = "../../modules/tailscale"

  project_name                  = var.project_name
  environment                   = var.environment
  vpc_id                        = module.network.vpc_id
  vpc_cidr                      = var.vpc_cidr
  private_subnet_id             = module.network.private_subnet_ids[0]
  instance_type                 = var.tailscale_instance_type
  eks_cluster_security_group_id = module.eks.cluster_security_group_id
  tailscale_oauth_secret_arn    = var.tailscale_oauth_secret_arn
  aws_region                    = var.aws_region

  # NAT Gateway/Route Table까지 모두 준비된 뒤 첫 부팅 설치를 실행한다.
  depends_on = [module.network]
}

module "iam" {
  source = "../../modules/iam"

  project_name = var.project_name
}

module "eks" {
  source = "../../modules/eks"

  project_name = var.project_name

  # Cluster
  cluster_version    = var.eks_cluster_version
  cluster_role_arn   = module.iam.eks_cluster_role_arn
  node_role_arn      = module.iam.eks_node_role_arn
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  public_subnet_ids  = module.network.public_subnet_ids

  # Endpoint
  endpoint_public_access  = var.eks_endpoint_public_access
  endpoint_private_access = var.eks_endpoint_private_access
  public_access_cidrs     = var.eks_public_access_cidrs

  # Access
  cluster_admin_principal_arns = var.eks_cluster_admin_principal_arns

  # Node Group
  node_instance_types = var.eks_node_instance_types
  node_ami_type       = var.eks_node_ami_type
  node_disk_size      = var.eks_node_disk_size
  node_desired_size   = var.eks_node_desired_size
  node_min_size       = var.eks_node_min_size
  node_max_size       = var.eks_node_max_size
}

# EKS 위 플랫폼 컴포넌트(ALB Controller, Karpenter)용 IAM — Pod Identity 방식
module "platform_iam" {
  source = "../../modules/platform-iam"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  cluster_name = module.eks.cluster_name
}

module "ecr" {
  source = "../../modules/ecr"

  project_name     = var.project_name
  repository_names = var.ecr_repository_names
  # image_tag_mutability / force_delete / lifecycle 설정은 모듈 기본값(DEV 기준) 사용
}

module "s3" {
  source = "../../modules/s3"

  project_name    = var.project_name
  environment     = var.environment
  bucket_purposes = local.dev_s3_bucket_purposes
  bucket_settings = {
    db-backups = {
      enable_versioning = true
    }
  }
  # 모든 애플리케이션 S3 Bucket은 force_destroy=false 및 prevent_destroy=true로 보호한다.
}

# Route53 도메인 위임 - DEV 인프라 destroy와 분리하여 계속 보존한다.
# Phase 1에서는 Hosted Zone만 생성하며, NS 전환 확인 후 ACM을 추가한다.
module "route53_acm" {
  source = "../../modules/route53-acm"

  domain_name = var.domain_name
}

# CNPG PostgreSQL Pod가 Barman Cloud를 통해 S3에 백업할 때 사용하는 Pod Identity Role.
module "workload_iam" {
  source = "../../modules/workload-iam"

  project_name              = var.project_name
  environment               = var.environment
  cluster_name              = module.eks.cluster_name
  db_backups_bucket_arn     = module.s3.bucket_arns["db-backups"]
  cnpg_namespace            = var.cnpg_namespace
  cnpg_service_account_name = var.cnpg_service_account_name
  cnpg_backup_prefix        = var.cnpg_backup_prefix
}
