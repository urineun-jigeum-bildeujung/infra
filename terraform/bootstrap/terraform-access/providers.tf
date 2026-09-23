# Terraform 실행 IAM 을 관리하기 위한 Provider 설정
# 이 스택은 최초 1회 생성 후 계속 유지된다.
# DEV 인프라의 terraform destroy 대상에 절대 포함되지 않도록 별도 스택으로 분리한다.

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
# default_tags 로 이 스택이 만드는 모든 AWS 리소스에 공통 태그가 자동 부여된다.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "bootstrap"
      ManagedBy   = "Terraform"
      Stack       = "terraform-access"
    }
  }
}
