# 재구매 배치의 모델 읽기 권한. 기존 recommendation과 같은 Pod Identity 방식이며
# 다른 모델 경로나 업로드/삭제 권한은 부여하지 않는다.
resource "aws_iam_role" "repurchase_model_reader" {
  name               = "${local.name_prefix}-repurchase-model-reader"
  description        = "Read-only role for repurchase jobs to download model artifacts from S3"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "repurchase_model_reader" {
  statement {
    sid       = "ListMlArtifactsRepurchasePrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.ml_artifacts_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["repurchase/", "repurchase/*"]
    }
  }

  statement {
    sid       = "GetMlArtifactsRepurchaseObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.ml_artifacts_bucket_arn}/repurchase/*"]
  }
}

resource "aws_iam_policy" "repurchase_model_reader" {
  name        = "${local.name_prefix}-repurchase-model-reader"
  description = "Read-only access to the repurchase/* prefix of the ml-artifacts bucket"
  policy      = data.aws_iam_policy_document.repurchase_model_reader.json
}

resource "aws_iam_role_policy_attachment" "repurchase_model_reader" {
  role       = aws_iam_role.repurchase_model_reader.name
  policy_arn = aws_iam_policy.repurchase_model_reader.arn
}

resource "aws_eks_pod_identity_association" "repurchase_model_reader" {
  cluster_name    = var.cluster_name
  namespace       = "repurchase"
  service_account = "generic-service"
  role_arn        = aws_iam_role.repurchase_model_reader.arn

  depends_on = [aws_iam_role_policy_attachment.repurchase_model_reader]
}
