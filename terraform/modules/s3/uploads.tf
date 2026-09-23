# 리뷰/프로필 이미지 직접 업로드, 고아 객체 정리 및 CloudFront 조회 경로를 구성한다.
resource "aws_s3_bucket_cors_configuration" "uploads" {
  count  = var.enable_image_uploads ? 1 : 0
  bucket = aws_s3_bucket.app["uploads"].id

  cors_rule {
    allowed_origins = var.uploads_allowed_origins
    allowed_methods = ["PUT"]
    allowed_headers = ["Content-Type", "x-amz-*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  count  = var.enable_image_uploads ? 1 : 0
  bucket = aws_s3_bucket.app["uploads"].id

  rule {
    id     = "expire-pending-uploads"
    status = "Enabled"

    filter {
      tag {
        key   = "status"
        value = "pending"
      }
    }

    expiration {
      days = var.pending_upload_expiration_days
    }
  }
}

resource "aws_cloudfront_origin_access_control" "uploads" {
  count                             = var.enable_image_uploads ? 1 : 0
  name                              = "${var.project_name}-${var.environment}-uploads"
  description                       = "이미지 비공개 S3 origin 접근"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_cloudfront_distribution" "uploads" {
  count           = var.enable_image_uploads ? 1 : 0
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.project_name}-${var.environment} 이미지"
  price_class     = "PriceClass_200"
  aliases         = var.uploads_custom_domain_name == null ? [] : [var.uploads_custom_domain_name]

  origin {
    domain_name              = aws_s3_bucket.app["uploads"].bucket_regional_domain_name
    origin_id                = "uploads-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.uploads[0].id

    # OAC만 지정한다. Provider가 AWS 요청에 필요한 빈 S3OriginConfig를 자동 생성한다.
    # 빈 s3_origin_config를 명시하면 AWS Provider 5.100.0의 refresh 때 생략되어 반복 diff가 발생한다.
  }

  origin {
    domain_name              = aws_s3_bucket.app["product-images"].bucket_regional_domain_name
    origin_id                = "product-images-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.uploads[0].id
  }

  ordered_cache_behavior {
    path_pattern           = "products/*"
    target_origin_id       = "product-images-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = "uploads-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.uploads_cloudfront_certificate_arn == null
    acm_certificate_arn            = var.uploads_cloudfront_certificate_arn
    ssl_support_method             = var.uploads_cloudfront_certificate_arn == null ? null : "sni-only"
    minimum_protocol_version       = var.uploads_cloudfront_certificate_arn == null ? null : "TLSv1.2_2021"
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = (
        var.uploads_custom_domain_name == null && var.uploads_cloudfront_certificate_arn == null
        ) || (
        var.uploads_custom_domain_name != null && var.uploads_cloudfront_certificate_arn != null
      )
      error_message = "CloudFront 이미지 도메인과 us-east-1 ACM 인증서는 함께 지정해야 합니다."
    }
  }
}
