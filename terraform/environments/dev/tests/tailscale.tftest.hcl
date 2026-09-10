mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "router_is_private_and_ssm_managed" {
  command = apply

  module {
    source = "../../modules/tailscale"
  }

  variables {
    project_name                  = "petflow"
    environment                   = "dev"
    vpc_id                        = "vpc-0123456789abcdef0"
    vpc_cidr                      = "10.0.0.0/20"
    private_subnet_id             = "subnet-0123456789abcdef0"
    eks_cluster_security_group_id = "sg-0123456789abcdef0"
    instance_type                 = "t3.micro"
    root_volume_size              = 8
  }

  assert {
    condition = (
      aws_instance.router.subnet_id == "subnet-0123456789abcdef0" &&
      aws_instance.router.associate_public_ip_address == false
    )
    error_message = "Router는 지정한 Private Subnet에 Public IP 없이 배치되어야 합니다."
  }

  assert {
    condition     = length(aws_security_group.router.ingress) == 0
    error_message = "Router Security Group에는 Public SSH/RDP를 포함한 inbound 규칙이 없어야 합니다."
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.eks_api_from_router.security_group_id == "sg-0123456789abcdef0" &&
      aws_vpc_security_group_ingress_rule.eks_api_from_router.referenced_security_group_id == aws_security_group.router.id &&
      aws_vpc_security_group_ingress_rule.eks_api_from_router.from_port == 443 &&
      aws_vpc_security_group_ingress_rule.eks_api_from_router.to_port == 443
    )
    error_message = "EKS Private API는 Router Security Group에서 들어오는 TCP 443만 허용해야 합니다."
  }


  assert {
    condition = (
      aws_instance.router.metadata_options[0].http_endpoint == "enabled" &&
      aws_instance.router.metadata_options[0].http_tokens == "required"
    )
    error_message = "Router EC2는 IMDSv2를 강제해야 합니다."
  }

  assert {
    condition = (
      aws_instance.router.root_block_device[0].encrypted == true &&
      aws_instance.router.root_block_device[0].delete_on_termination == true
    )
    error_message = "Router root EBS는 암호화하고 인스턴스와 함께 정리해야 합니다."
  }

  assert {
    condition = (
      aws_iam_role_policy_attachment.ssm.policy_arn ==
      "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    )
    error_message = "Router IAM Role에는 SSM Managed Instance Core 정책만 연결해야 합니다."
  }

  assert {
    condition = alltrue([
      for statement in data.aws_iam_policy_document.ec2_trust.statement :
      toset(statement.actions) == toset(["sts:AssumeRole"]) &&
      length(statement.principals) == 1 &&
      alltrue([
        for principal in statement.principals :
        principal.type == "Service" &&
        toset(principal.identifiers) == toset(["ec2.amazonaws.com"])
      ])
    ])
    error_message = "Router IAM Role은 EC2 서비스만 신뢰해야 합니다."
  }

  assert {
    condition = (
      strcontains(aws_instance.router.user_data, "net.ipv4.ip_forward = 1") &&
      strcontains(aws_instance.router.user_data, "https://tailscale.com/install.sh") &&
      strcontains(aws_instance.router.user_data, "--advertise-routes=\"10.0.0.0/20\"") &&
      !strcontains(lower(aws_instance.router.user_data), "tskey-")
    )
    error_message = "User Data는 forwarding/Tailscale/Route 헬퍼를 준비하되 Auth Key를 포함하면 안 됩니다."
  }

  assert {
    condition     = aws_instance.router.source_dest_check == true
    error_message = "초기 Tailscale 기본 SNAT 구성에서는 source/destination check를 유지합니다."
  }
}

run "reject_too_small_root_volume" {
  command = plan

  module {
    source = "../../modules/tailscale"
  }

  variables {
    project_name                  = "petflow"
    environment                   = "dev"
    vpc_id                        = "vpc-0123456789abcdef0"
    vpc_cidr                      = "10.0.0.0/20"
    private_subnet_id             = "subnet-0123456789abcdef0"
    eks_cluster_security_group_id = "sg-0123456789abcdef0"
    root_volume_size              = 4
  }

  expect_failures = [var.root_volume_size]
}
