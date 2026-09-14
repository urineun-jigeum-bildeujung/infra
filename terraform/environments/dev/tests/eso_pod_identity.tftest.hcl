mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "297165773875"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "external_secrets_uses_least_privilege_pod_identity" {
  command = plan

  module {
    source = "../../modules/platform-iam"
  }

  variables {
    project_name = "petflow"
    environment  = "dev"
    cluster_name = "petflow-eks"
    aws_region   = "ap-northeast-2"
  }

  assert {
    condition = (
      aws_iam_role.external_secrets.name == "petflow-dev-external-secrets" &&
      aws_iam_role.external_secrets.assume_role_policy == data.aws_iam_policy_document.pod_identity_trust.json
    )
    error_message = "ESO Role은 공통 EKS Pod Identity Trust Policy를 사용해야 합니다."
  }

  assert {
    condition = alltrue([
      for statement in data.aws_iam_policy_document.pod_identity_trust.statement :
      statement.sid == "AllowPodIdentityAssume" &&
      toset(statement.actions) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      length(statement.principals) == 1 &&
      alltrue([
        for principal in statement.principals :
        principal.type == "Service" &&
        toset(principal.identifiers) == toset(["pods.eks.amazonaws.com"])
      ])
    ])
    error_message = "ESO Trust Policy는 pods.eks.amazonaws.com에 AssumeRole과 TagSession만 허용해야 합니다."
  }

  assert {
    condition = alltrue([
      for statement in data.aws_iam_policy_document.external_secrets.statement :
      statement.sid == "ReadPetflowSecrets" &&
      toset(statement.actions) == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]) &&
      toset(statement.resources) == toset(["arn:aws:secretsmanager:ap-northeast-2:297165773875:secret:petflow/*"])
    ])
    error_message = "ESO 권한은 petflow/* Secret의 GetSecretValue와 DescribeSecret으로 제한해야 합니다."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.external_secrets.role == "petflow-dev-external-secrets"
    error_message = "ESO 최소 권한 Policy는 ESO Role에만 연결되어야 합니다."
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.external_secrets.cluster_name == "petflow-eks" &&
      aws_eks_pod_identity_association.external_secrets.namespace == "external-secrets" &&
      aws_eks_pod_identity_association.external_secrets.service_account == "external-secrets"
    )
    error_message = "ESO Pod Identity Association은 external-secrets/external-secrets 계약을 사용해야 합니다."
  }
}
