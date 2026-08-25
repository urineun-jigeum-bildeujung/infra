# Dev 환경 Terraform 및 AWS Provider 설정

terraform {
  # S3 Backend 의 native state locking(use_lockfile = true) 은 Terraform 1.10 부터 사용 가능하다.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# AWS 서울 리전을 기본 배포 리전으로 사용한다.
provider "aws" {
  region = var.aws_region
}
