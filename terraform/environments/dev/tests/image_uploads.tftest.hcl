# 이미지 권한 분리, pending 태그 강제와 삭제 대상 범위를 AWS 호출 없이 검증한다.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "pending_expiration_and_private_cdn" {
  command = apply

  module {
    source = "../../modules/s3"
  }

  variables {
    project_name                       = "petflow"
    environment                        = "dev"
    enable_image_uploads               = true
    uploads_allowed_origins            = ["https://leechs.shop", "http://localhost:3000"]
    uploads_custom_domain_name         = "image.leechs.shop"
    uploads_cloudfront_certificate_arn = "arn:aws:acm:us-east-1:297165773875:certificate/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition = alltrue([
      for rule in aws_s3_bucket_lifecycle_configuration.uploads[0].rule :
      rule.status == "Enabled" && alltrue([
        for filter in rule.filter : alltrue([
          for tag in filter.tag : tag.key == "status" && tag.value == "pending"
        ]) && length(filter.tag) == 1
        ]) && alltrue([
        for expiration in rule.expiration : expiration.days == 3
      ]) && length(rule.filter) == 1
    ]) && length(aws_s3_bucket_lifecycle_configuration.uploads[0].rule) == 1
    error_message = "라이프사이클은 pending 태그 이미지만 생성 후 3일에 삭제해야 합니다."
  }

  assert {
    condition = alltrue([
      for rule in aws_s3_bucket_cors_configuration.uploads[0].cors_rule :
      toset(rule.allowed_origins) == toset(["https://leechs.shop", "http://localhost:3000"]) &&
      toset(rule.allowed_methods) == toset(["PUT"]) &&
      toset(rule.allowed_headers) == toset(["Content-Type", "x-amz-*"])
    ])
    error_message = "CORS는 지정한 프론트 origin에서 태그 헤더를 포함한 PUT만 허용해야 합니다."
  }

  assert {
    condition = (
      !aws_s3_bucket.app["uploads"].force_destroy &&
      !contains(keys(aws_s3_bucket_versioning.app), "uploads") &&
      aws_s3_bucket_public_access_block.app["uploads"].block_public_acls &&
      aws_s3_bucket_public_access_block.app["uploads"].block_public_policy &&
      aws_s3_bucket_public_access_block.app["uploads"].ignore_public_acls &&
      aws_s3_bucket_public_access_block.app["uploads"].restrict_public_buckets
    )
    error_message = "uploads 버킷은 비공개 및 강제 삭제 금지를 유지하고 Versioning을 활성화하지 않아야 합니다."
  }

  assert {
    condition = (
      aws_cloudfront_origin_access_control.uploads[0].signing_behavior == "always" &&
      aws_cloudfront_origin_access_control.uploads[0].signing_protocol == "sigv4" &&
      alltrue([
        for behavior in aws_cloudfront_distribution.uploads[0].default_cache_behavior :
        toset(behavior.allowed_methods) == toset(["GET", "HEAD"]) &&
        behavior.viewer_protocol_policy == "redirect-to-https" &&
        behavior.target_origin_id == "uploads-s3"
      ]) &&
      length(aws_cloudfront_distribution.uploads[0].ordered_cache_behavior) == 1 &&
      alltrue([
        for behavior in aws_cloudfront_distribution.uploads[0].ordered_cache_behavior :
        behavior.path_pattern == "products/*" &&
        behavior.target_origin_id == "product-images-s3" &&
        toset(behavior.allowed_methods) == toset(["GET", "HEAD"]) &&
        behavior.viewer_protocol_policy == "redirect-to-https"
      ]) &&
      length(aws_cloudfront_distribution.uploads[0].origin) == 2 &&
      alltrue([
        for origin in aws_cloudfront_distribution.uploads[0].origin :
        (
          (origin.origin_id == "uploads-s3" && origin.domain_name == aws_s3_bucket.app["uploads"].bucket_regional_domain_name) ||
          (origin.origin_id == "product-images-s3" && origin.domain_name == aws_s3_bucket.app["product-images"].bucket_regional_domain_name)
        ) &&
        origin.origin_access_control_id == aws_cloudfront_origin_access_control.uploads[0].id &&
        length(origin.s3_origin_config) == 0
      ])
    )
    error_message = "CloudFront는 빈 s3_origin_config 없이 OAC로 S3 REST origin에 접근하고 읽기 전용 HTTPS 경로를 제공해야 합니다."
  }

  assert {
    condition = (
      toset(aws_cloudfront_distribution.uploads[0].aliases) == toset(["image.leechs.shop"]) &&
      !aws_cloudfront_distribution.uploads[0].viewer_certificate[0].cloudfront_default_certificate &&
      aws_cloudfront_distribution.uploads[0].viewer_certificate[0].acm_certificate_arn == "arn:aws:acm:us-east-1:297165773875:certificate/00000000-0000-0000-0000-000000000000" &&
      aws_cloudfront_distribution.uploads[0].viewer_certificate[0].ssl_support_method == "sni-only" &&
      aws_cloudfront_distribution.uploads[0].viewer_certificate[0].minimum_protocol_version == "TLSv1.2_2021"
    )
    error_message = "커스텀 이미지 도메인은 us-east-1 ACM 인증서와 TLS 1.2 이상을 사용해야 합니다."
  }

  assert {
    condition = alltrue([
      for statement in data.aws_iam_policy_document.tls_only["uploads"].statement :
      statement.sid != "AllowUploadsCloudFrontRead" || (
        toset(statement.actions) == toset(["s3:GetObject"]) &&
        toset(statement.resources) == toset([
          "${aws_s3_bucket.app["uploads"].arn}/reviews/*",
          "${aws_s3_bucket.app["uploads"].arn}/profiles/*",
        ]) &&
        alltrue([
          for principal in statement.principals :
          principal.type == "Service" && toset(principal.identifiers) == toset(["cloudfront.amazonaws.com"])
        ]) &&
        alltrue([
          for condition in statement.condition :
          condition.test == "StringEquals" && condition.variable == "AWS:SourceArn" &&
          toset(condition.values) == toset([aws_cloudfront_distribution.uploads[0].arn])
        ])
      )
      ]) && toset([
      for statement in data.aws_iam_policy_document.tls_only["uploads"].statement : statement.sid
    ]) == toset(["DenyInsecureTransport", "AllowUploadsCloudFrontRead"])
    error_message = "TLS 강제와 해당 배포의 reviews/profiles 조회 권한을 하나의 버킷 정책에 보존해야 합니다."
  }

  assert {
    condition = alltrue([
      for statement in data.aws_iam_policy_document.tls_only["product-images"].statement :
      statement.sid != "AllowProductImagesCloudFrontRead" || (
        toset(statement.actions) == toset(["s3:GetObject"]) &&
        toset(statement.resources) == toset(["${aws_s3_bucket.app["product-images"].arn}/products/*"]) &&
        alltrue([
          for principal in statement.principals :
          principal.type == "Service" && toset(principal.identifiers) == toset(["cloudfront.amazonaws.com"])
        ]) &&
        alltrue([
          for condition in statement.condition :
          condition.test == "StringEquals" && condition.variable == "AWS:SourceArn" &&
          toset(condition.values) == toset([aws_cloudfront_distribution.uploads[0].arn])
        ])
      )
      ]) && toset([
      for statement in data.aws_iam_policy_document.tls_only["product-images"].statement : statement.sid
    ]) == toset(["DenyInsecureTransport", "AllowProductImagesCloudFrontRead"])
    error_message = "상품 이미지 버킷은 해당 CloudFront 배포에 products/* 읽기만 허용해야 합니다."
  }

  assert {
    condition = alltrue([
      for name, document in data.aws_iam_policy_document.tls_only :
      contains(["uploads", "product-images"], name) || length(document.statement) == 1
    ])
    error_message = "이미지 조회 권한을 다른 버킷에 부여하면 안 됩니다."
  }
}

run "service_permissions_and_pod_identity" {
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
    uploads_bucket_arn        = "arn:aws:s3:::petflow-dev-uploads"
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
  }

  assert {
    condition = alltrue([
      for name, association in aws_eks_pod_identity_association.image_upload :
      association.cluster_name == "petflow-eks" && association.namespace == name &&
      association.service_account == "generic-service"
    ]) && toset(keys(aws_eks_pod_identity_association.image_upload)) == toset(["review-service", "member-service"])
    error_message = "각 서비스 namespace의 실제 generic-service ServiceAccount에 Pod Identity를 연결해야 합니다."
  }

  assert {
    condition = alltrue(flatten([
      for document in data.aws_iam_policy_document.image_upload_trust : [
        for statement in document.statement :
        statement.effect == "Allow" &&
        toset(statement.actions) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
        alltrue([
          for principal in statement.principals :
          principal.type == "Service" && toset(principal.identifiers) == toset(["pods.eks.amazonaws.com"])
        ])
      ]
    ]))
    error_message = "이미지 Role은 EKS Pod Identity 서비스만 신뢰해야 합니다."
  }

  assert {
    condition = alltrue(flatten([
      for name, document in data.aws_iam_policy_document.image_upload : [
        for statement in document.statement :
        toset(statement.resources) == toset([
          "arn:aws:s3:::petflow-dev-uploads/${name == "review-service" ? "reviews" : "profiles"}/*",
          ]) && alltrue([
          for action in statement.actions : contains([
            "s3:PutObject", "s3:PutObjectTagging", "s3:GetObject", "s3:GetObjectTagging",
          ], action)
        ])
      ]
    ]))
    error_message = "서비스 Role은 자기 경로의 업로드/조회/태그 권한만 가져야 하며 삭제 또는 다른 경로를 허용하면 안 됩니다."
  }

  assert {
    condition = alltrue(flatten([
      for document in data.aws_iam_policy_document.image_upload : [
        for statement in document.statement :
        !contains(statement.actions, "s3:PutObject") || (
          length(statement.condition) == 1 && alltrue([
            for condition in statement.condition :
            condition.test == "StringEquals" && condition.variable == "s3:RequestObjectTag/status" &&
            toset(condition.values) == toset(["pending"])
          ])
        )
      ]
    ]))
    error_message = "이미지 업로드에는 반드시 status=pending 태그를 요구해야 합니다."
  }

  assert {
    condition = alltrue(flatten([
      for document in data.aws_iam_policy_document.image_upload : [
        for statement in document.statement :
        !contains(statement.actions, "s3:PutObjectTagging") || (
          length(statement.condition) == 1 && alltrue([
            for condition in statement.condition :
            condition.test == "StringEquals" && condition.variable == "s3:RequestObjectTag/status" &&
            toset(condition.values) == toset(["pending", "confirmed"])
          ])
        )
      ]
    ]))
    error_message = "pending 태그 업로드와 confirmed 태그 변경을 모두 허용해야 합니다."
  }
}

run "reject_versioned_image_bucket" {
  command = plan

  module {
    source = "../../modules/s3"
  }

  variables {
    project_name            = "petflow"
    environment             = "dev"
    enable_image_uploads    = true
    uploads_allowed_origins = ["https://leechs.shop"]
    enable_versioning       = true
  }

  expect_failures = [var.enable_image_uploads]
}

run "reject_wildcard_frontend_origin" {
  command = plan

  module {
    source = "../../modules/s3"
  }

  variables {
    project_name            = "petflow"
    environment             = "dev"
    enable_image_uploads    = true
    uploads_allowed_origins = ["*"]
  }

  expect_failures = [var.uploads_allowed_origins]
}
