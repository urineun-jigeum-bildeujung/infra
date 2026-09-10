mock_provider "aws" {
  # aws_iam_role은 assume_role_policy의 JSON 형식을 provider 단계에서 검증한다.
  # 기본 mock 문자열은 빈 값이므로 유효한 최소 정책을 반환하게 한다. 각 run의
  # assertion은 data source의 statement 입력값을 직접 검증한다.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "s3_gateway_endpoint_uses_private_route_tables" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    project_name         = "petflow"
    aws_region           = "ap-northeast-2"
    vpc_cidr             = "10.0.0.0/16"
    azs                  = ["ap-northeast-2b", "ap-northeast-2d"]
    public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
    private_subnet_cidrs = ["10.0.10.0/24", "10.0.20.0/24"]
    single_nat_gateway   = true
  }

  assert {
    condition = (
      aws_vpc_endpoint.s3.service_name == "com.amazonaws.ap-northeast-2.s3" &&
      aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" &&
      length(aws_vpc_endpoint.s3.route_table_ids) == 1
    )
    error_message = "S3 Gateway Endpoint는 현재 DEV private route table에만 연결되어야 합니다."
  }
}

run "backup_bucket_is_versioned_and_all_buckets_are_protected" {
  command = plan

  module {
    source = "../../modules/s3"
  }

  variables {
    project_name    = "petflow"
    environment     = "dev"
    bucket_purposes = ["static", "product-images", "uploads", "db-backups"]
    bucket_settings = {
      db-backups = {
        enable_versioning = true
      }
    }
  }

  assert {
    condition     = !aws_s3_bucket.app["db-backups"].force_destroy && !aws_s3_bucket.app["uploads"].force_destroy
    error_message = "백업 버킷과 기존 앱 버킷은 객체 강제 삭제가 차단되어야 합니다."
  }

  assert {
    condition     = keys(aws_s3_bucket_versioning.app) == ["db-backups"]
    error_message = "백업 버킷만 Versioning 을 활성화해야 합니다."
  }
}

run "cnpg_pod_identity_scope" {
  command = plan

  module {
    source = "../../modules/workload-iam"
  }

  variables {
    project_name              = "petflow"
    environment               = "dev"
    cluster_name              = "petflow-eks"
    db_backups_bucket_arn     = "arn:aws:s3:::petflow-dev-db-backups"
    cnpg_namespace            = "database"
    cnpg_service_account_name = "petflow-db"
    cnpg_backup_prefix        = "cnpg"
  }

  assert {
    condition = alltrue([
      for statement in data.aws_iam_policy_document.cnpg_trust.statement :
      toset(statement.actions) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      length(statement.principals) == 1 &&
      alltrue([
        for principal in statement.principals :
        principal.type == "Service" &&
        toset(principal.identifiers) == toset(["pods.eks.amazonaws.com"])
      ])
    ])
    error_message = "Role은 EKS Pod Identity 서비스만 신뢰해야 합니다."
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.cnpg_backup.cluster_name == "petflow-eks" &&
      aws_eks_pod_identity_association.cnpg_backup.namespace == "database" &&
      aws_eks_pod_identity_association.cnpg_backup.service_account == "petflow-db"
    )
    error_message = "Pod Identity Association은 정확한 Cluster/namespace/ServiceAccount에 연결되어야 합니다."
  }

  assert {
    condition = alltrue([
      for statement in data.aws_iam_policy_document.cnpg_backup.statement :
      statement.sid == "CheckAndListBackupBucket" ? (
        toset(statement.resources) == toset(["arn:aws:s3:::petflow-dev-db-backups"]) && toset(statement.actions) == toset(["s3:ListBucket"])
        ) : (
        toset(statement.resources) == toset(["arn:aws:s3:::petflow-dev-db-backups/cnpg/*"]) &&
        toset(statement.actions) == toset(["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:DeleteObject"])
      )
    ])
    error_message = "백업 권한은 전용 버킷/prefix 에 한정하며 버전 영구 삭제를 허용하면 안 됩니다."
  }
}

run "reject_wildcard_prefix" {
  command = plan

  module {
    source = "../../modules/workload-iam"
  }

  variables {
    project_name              = "petflow"
    environment               = "dev"
    cluster_name              = "petflow-eks"
    db_backups_bucket_arn     = "arn:aws:s3:::petflow-dev-db-backups"
    cnpg_namespace            = "database"
    cnpg_service_account_name = "petflow-db"
    cnpg_backup_prefix        = "*"
  }

  expect_failures = [var.cnpg_backup_prefix]
}
