# Terraform State 저장용 S3 Bucket을 생성하기 위한 Provider 설정
# 이 스택은 최초 1회만 생성하며, 이후에는 유지 목적으로만 관리한다.

terraform {
  # 일반 인프라 스택과 동일하게 Terraform 1.10 이상 사용을 요구한다.
  # (환경 전체의 Terraform 버전 정책을 일관되게 유지하기 위함)
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# 실제 리소스 정의는 main.tf 에 작성한다.
provider "aws" {
  region = var.aws_region
}
