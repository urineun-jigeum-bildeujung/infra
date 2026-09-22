# Dev 환경 Root Module
#
# 이 파일은 terraform/modules/ 하위의 각 모듈을 호출하여 Dev 환경 인프라를 조립한다.
# 실제 리소스는 각 모듈 내부에서 정의하며, 여기서는 모듈 호출과 값 전달만 담당한다.

locals {
  # 개인 IAM 사용자가 아닌 Bootstrap 공용 Role을 Terraform 실행 주체로 고정한다.
  terraform_execution_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.terraform_execution_role_name}"

  # 공용 Role이 EKS 생성 후 kubectl/GitOps 자동화까지 이어서 수행할 수 있어야 한다.
  eks_cluster_admin_principal_arns = distinct(concat(
    var.eks_cluster_admin_principal_arns,
    [local.terraform_execution_role_arn],
  ))

  # 감사 로그 Bucket 변조 방지 예외는 공용 실행 Role을 필수로 포함한다.
  # cloudtrail_admin_role_arns는 비상 전환용 추가 ARN만 받는 하위 호환 입력이다.
  audit_log_admin_principal_arns = distinct(concat(
    [local.terraform_execution_role_arn],
    var.cloudtrail_admin_role_arns,
  ))

  # 기존 tfvars에서도 사용자 이미지 업로드와 CNPG 백업 Bucket을 보장한다.
  dev_s3_bucket_purposes = distinct(concat(var.s3_bucket_purposes, ["uploads", "db-backups"]))

  # 앱에는 CloudFront 기본 도메인 대신 이 고정 이미지 도메인을 전달한다.
  uploads_custom_domain_name = "image.${var.domain_name}"

  # CNPG 기반 이미지와 Web/API Gateway Repository는 오래된 로컬 tfvars에서 빠져 있어도 보존한다.
  # 실제 PostgreSQL 이미지는 tapply.sh가 apply 후 push한다.
  dev_ecr_repository_names = distinct(concat(var.ecr_repository_names, [
    "api-gateway",
    "postgresql-pg-bigm",
    "web",
  ]))
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

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

  # 감사 로그
  enabled_cluster_log_types  = var.eks_cluster_log_types
  cluster_log_retention_days = var.eks_cluster_log_retention_days

  # Endpoint
  endpoint_public_access  = var.eks_endpoint_public_access
  endpoint_private_access = var.eks_endpoint_private_access
  public_access_cidrs     = var.eks_public_access_cidrs

  # Access
  cluster_admin_principal_arns = local.eks_cluster_admin_principal_arns

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
  enable_image_uploads               = true
  uploads_allowed_origins            = var.uploads_allowed_origins
  pending_upload_expiration_days     = var.pending_upload_expiration_days
  uploads_custom_domain_name         = local.uploads_custom_domain_name
  uploads_cloudfront_certificate_arn = aws_acm_certificate_validation.uploads_cloudfront.certificate_arn
  # 모든 애플리케이션 S3 Bucket은 force_destroy=false 및 prevent_destroy=true로 보호한다.
}

# Route53 도메인 위임 - DEV 인프라 destroy와 분리하여 계속 보존한다.
# Phase 1에서는 Hosted Zone만 생성하며, NS 전환 확인 후 ACM을 추가한다.
module "route53_acm" {
  source = "../../modules/route53-acm"

  domain_name = var.domain_name
}

# CloudFront는 Viewer 인증서를 반드시 us-east-1 ACM에서 사용해야 한다.
# 기존 route53_acm 모듈의 서울 리전 인증서는 ALB HTTPS 용도로 계속 유지한다.
resource "aws_acm_certificate" "uploads_cloudfront" {
  provider          = aws.us_east_1
  domain_name       = local.uploads_custom_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "uploads_cloudfront_acm_validation" {
  for_each = {
    for option in aws_acm_certificate.uploads_cloudfront.domain_validation_options :
    option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  zone_id = module.route53_acm.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "uploads_cloudfront" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.uploads_cloudfront.arn
  validation_record_fqdns = [for record in aws_route53_record.uploads_cloudfront_acm_validation : record.fqdn]
}

# image.leechs.shop -> private S3를 origin으로 하는 CloudFront Distribution
resource "aws_route53_record" "uploads_cloudfront" {
  zone_id = module.route53_acm.zone_id
  name    = local.uploads_custom_domain_name
  type    = "A"

  alias {
    name                   = module.s3.uploads_cloudfront_domain_name
    zone_id                = module.s3.uploads_cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
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
    order-service = {
      namespace       = "order-service"
      service_account = "generic-service"
      prefix          = "orders"
    }
  }

  # 운영 DB와 분리된 복원 검증 Cluster도 같은 cnpg/ prefix를 읽을 수 있게 한다.
  additional_service_account_names = [
    var.cnpg_restore_service_account_name,
  ]
}

# AWS 계정/리전 전체의 관리 API 호출(CloudTrail) 감사 로그.
# 공용 Terraform 실행 Role은 항상 삭제/정책변경 Deny의 예외로 포함한다.
module "cloudtrail" {
  source = "../../modules/cloudtrail"

  project_name   = var.project_name
  environment    = var.environment
  aws_account_id = data.aws_caller_identity.current.account_id

  s3_retention_days             = var.cloudtrail_s3_retention_days
  cloudwatch_log_retention_days = var.cloudtrail_cloudwatch_retention_days
  allowed_admin_role_arns       = local.audit_log_admin_principal_arns
}

module "vpc_flow_log" {
  source = "../../modules/vpc-flow-log"

  project_name   = var.project_name
  environment    = var.environment
  aws_region     = var.aws_region
  aws_account_id = data.aws_caller_identity.current.account_id
  vpc_id         = module.network.vpc_id

  s3_retention_days       = var.vpc_flow_log_s3_retention_days
  allowed_admin_role_arns = local.audit_log_admin_principal_arns
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
