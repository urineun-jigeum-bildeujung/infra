
locals {
  region   = "ap-northeast-2"
  azs      = ["ap-northeast-2a", "ap-northeast-2c"]
  vpc_cidr = "10.0.0.0/16"

  public_subnets  = ["10.0.0.0/20", "10.0.16.0/20"]
  private_subnets = ["10.0.128.0/20", "10.0.144.0/20"]

  cluster_name = "msa-eks-cluster"

  nat_gateway_count = var.single_nat_gateway ? 1 : length(local.azs)

  tags = {
    Project     = "msa-autoscaling"
    ManagedBy   = "terraform"
    Environment = var.environment
  }
}

variable "environment" {
  description = "배포 환경 (dev / staging / production)"
  type        = string
  default     = "dev"
}

variable "single_nat_gateway" {
  description = <<-EOT
    NAT Gateway를 1개만 생성할지 여부.
    [개선사항] 단일 NAT는 비용이 절반이지만, NAT가 위치한 AZ에 장애가 발생하면
    다른 AZ의 private subnet도 외부 통신이 끊기는 SPOF가 됩니다.
    dev/staging은 true, production은 false를 권장합니다.
  EOT
  type        = bool
  default     = true
}

provider "aws" {
  region = local.region
}

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-vpc"
  })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-igw"
  })
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name                                          = "${local.cluster_name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-nat-eip-${count.index}"
  })
}

resource "aws_nat_gateway" "nat" {
  count         = local.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-nat-${count.index}"
  })

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name                                          = "${local.cluster_name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "karpenter.sh/discovery" = local.cluster_name
  })
}

resource "aws_route_table" "private" {
  count  = local.nat_gateway_count
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }

  tags = merge(local.tags, {
    Name = "${local.cluster_name}-private-rt-${count.index}"
  })
}

resource "aws_route_table_association" "private" {
  count     = length(local.azs)
  subnet_id = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.single_nat_gateway ? 0 : count.index].id
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
