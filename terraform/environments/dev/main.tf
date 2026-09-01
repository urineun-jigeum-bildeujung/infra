# Dev 환경 Root Module
#
# 이 파일은 terraform/modules/ 하위의 각 모듈을 호출하여 Dev 환경 인프라를 조립한다.
# 실제 리소스는 각 모듈 내부에서 정의하며, 여기서는 모듈 호출과 값 전달만 담당한다.

module "network" {
  source = "../../modules/network"

  project_name         = var.project_name
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
}

module "iam" {
  source = "../../modules/iam"

  project_name = var.project_name
}

# 아래 모듈들은 각 기능 브랜치에서 소스 파일이 완성되는 대로 주석을 해제한다.

# module "eks" {
#   source = "../../modules/eks"
#
#   project_name       = var.project_name
#   private_subnet_ids = module.network.private_subnet_ids
# }
#
# module "ecr" {
#   source = "../../modules/ecr"
#
#   project_name     = var.project_name
#   repository_names = var.ecr_repository_names
# }
#
# module "s3" {
#   source = "../../modules/s3"
#
#   project_name = var.project_name
# }
