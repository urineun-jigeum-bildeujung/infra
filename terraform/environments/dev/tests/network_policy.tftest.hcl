mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "vpc_cni_enables_network_policy_without_strict_mode" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    project_name                 = "petflow"
    cluster_version              = "1.35"
    cluster_role_arn             = "arn:aws:iam::297165773875:role/petflow-eks-cluster"
    node_role_arn                = "arn:aws:iam::297165773875:role/petflow-eks-node"
    vpc_id                       = "vpc-0123456789abcdef0"
    private_subnet_ids           = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    public_subnet_ids            = ["subnet-0123456789abcdef2", "subnet-0123456789abcdef3"]
    cluster_admin_principal_arns = ["arn:aws:iam::297165773875:user/terraform-test"]
  }

  assert {
    condition     = jsondecode(aws_eks_addon.vpc_cni.configuration_values).enableNetworkPolicy == "true"
    error_message = "VPC CNI는 NetworkPolicy 집행 기능을 활성화해야 합니다."
  }

  assert {
    condition = lookup(
      lookup(jsondecode(aws_eks_addon.vpc_cni.configuration_values), "env", {}),
      "NETWORK_POLICY_ENFORCING_MODE",
      "standard"
    ) == "standard"
    error_message = "허용 정책 준비 전에는 기본 standard 모드를 유지해야 합니다."
  }
}
