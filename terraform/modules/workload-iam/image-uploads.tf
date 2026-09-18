# 리뷰/프로필 서비스에 경로별 S3 권한을 EKS Pod Identity로 연결한다.
data "aws_iam_policy_document" "image_upload_trust" {
  for_each = var.image_upload_workloads

  statement {
    sid     = "AllowPodIdentityAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "image_upload" {
  for_each = var.image_upload_workloads
  name     = "${var.project_name}-${var.environment}-${each.key}-images"
  # IAM Description은 한글을 허용하지 않는다.
  description        = "Image upload and tagging via EKS Pod Identity"
  assume_role_policy = data.aws_iam_policy_document.image_upload_trust[each.key].json
}

data "aws_iam_policy_document" "image_upload" {
  for_each = var.image_upload_workloads

  statement {
    sid       = "UploadPendingImages"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${var.uploads_bucket_arn}/${each.value.prefix}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:RequestObjectTag/status"
      values   = ["pending"]
    }
  }

  # PutObject에 포함된 pending 태그 지정과 저장 후 confirmed 변경을 모두 허용한다.
  statement {
    sid       = "SetImageStatus"
    effect    = "Allow"
    actions   = ["s3:PutObjectTagging"]
    resources = ["${var.uploads_bucket_arn}/${each.value.prefix}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:RequestObjectTag/status"
      values   = ["pending", "confirmed"]
    }
  }

  # HeadObject는 GetObject 권한을 사용한다. 태그 조회는 기존 태그 보존에 사용한다.
  statement {
    sid       = "VerifyUploadedImages"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectTagging"]
    resources = ["${var.uploads_bucket_arn}/${each.value.prefix}/*"]
  }
}

resource "aws_iam_role_policy" "image_upload" {
  for_each = var.image_upload_workloads
  name     = "image-uploads-s3"
  role     = aws_iam_role.image_upload[each.key].id
  policy   = data.aws_iam_policy_document.image_upload[each.key].json
}

resource "aws_eks_pod_identity_association" "image_upload" {
  for_each        = var.image_upload_workloads
  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.image_upload[each.key].arn

  depends_on = [aws_iam_role_policy.image_upload]
}
