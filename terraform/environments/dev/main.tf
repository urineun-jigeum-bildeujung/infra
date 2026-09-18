# Dev 환경 Root Module
#
# 이 파일은 terraform/modules/ 하위의 각 모듈을 호출하여 Dev 환경 인프라를 조립한다.
# 실제 리소스는 각 모듈 내부에서 정의하며, 여기서는 모듈 호출과 값 전달만 담당한다.

locals {
  # 기존 tfvars에서도 사용자 이미지 업로드와 CNPG 백업 Bucket을 보장한다.
  dev_s3_bucket_purposes = distinct(concat(var.s3_bucket_purposes, ["uploads", "db-backups"]))

  # CNPG 기반 이미지와 Web Repository는 오래된 로컬 tfvars에서 빠져 있어도 보존한다.
  # 실제 PostgreSQL 이미지는 tapply.sh가 apply 후 push한다.
  dev_ecr_repository_names = distinct(concat(var.ecr_repository_names, [
    "postgresql-pg-bigm",
    "web",
  ]))
}

data "aws_caller_identity" "current" {}

# DEV 리전에서 이후 생성되는 모든 EBS(PVC 및 Worker Root Volume)를 기본 암호화한다.
# 기존 Volume은 제자리 암호화되지 않으며 다음 재생성부터 AWS 관리형 aws/ebs Key가 적용된다.
# tdestroy.sh는 모듈만 targeted destroy하므로 이 계정/리전 정책은 재구축 사이에도 유지된다.
resource "aws_ebs_encryption_by_default" "dev" {
  enabled = true

  lifecycle {
    prevent_destroy = true
  }
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
  repository_names = local.dev_ecr_repository_names
  force_delete     = false
  # Repository는 module lifecycle의 prevent_destroy로 보호하고 tdestroy.sh 대상에서도 제외한다.
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
  enable_image_uploads           = true
  uploads_allowed_origins        = var.uploads_allowed_origins
  pending_upload_expiration_days = var.pending_upload_expiration_days
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

  uploads_bucket_arn = module.s3.bucket_arns["uploads"]
  image_upload_workloads = {
    review-service = {
      namespace       = "review-service"
      service_account = "generic-service"
      prefix          = "reviews"
    }
    member-service = {
      namespace       = "member-service"
      service_account = "generic-service"
      prefix          = "profiles"
    }
  }

  # 운영 DB와 분리된 복원 검증 Cluster도 같은 cnpg/ prefix를 읽을 수 있게 한다.
  additional_service_account_names = [
    var.cnpg_restore_service_account_name,
  ]
}

# Petflow CNPG EBS만 태그로 선택해 일일 Recovery Point를 생성한다.
# 현재 PVC는 운영 절차에서 한 번 태그하고, 새 PVC는 GitOps gp3-cnpg StorageClass가
# 같은 태그를 생성 시점에 자동으로 부여한다.
module "ebs_backup" {
  source = "../../modules/ebs-backup"

  project_name     = var.project_name
  environment      = var.environment
  aws_region       = var.aws_region
  aws_account_id   = data.aws_caller_identity.current.account_id
  backup_tag_key   = var.cnpg_ebs_backup_tag_key
  backup_tag_value = var.cnpg_ebs_backup_tag_value
  schedule         = var.cnpg_ebs_snapshot_schedule
  retention_days   = var.cnpg_ebs_snapshot_retention_days
}
