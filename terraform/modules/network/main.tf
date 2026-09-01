# Network 모듈: VPC 및 서브넷, 라우팅, NAT 등 네트워크 계층 리소스를 정의한다.
#
# 관리 대상:
#   - VPC
#   - Public / Private Subnet (AZ 별)
#   - Internet Gateway
#   - NAT Gateway + EIP (single_nat_gateway 로 1개 또는 AZ 별 N개)
#   - Public Route Table (1개, 모든 Public Subnet 공유)
#   - Private Route Table (single_nat_gateway=true 이면 1개 공유, false 이면 AZ 별 N개)
#   - Route Table Association
#   - EKS 자동 인식용 subnet 태그
#
# 참고:
#   Public / Private Subnet 은 azs 리스트 순서에 맞춰 public_subnet_cidrs /
#   private_subnet_cidrs 를 소비한다. 세 리스트의 길이가 반드시 같아야 한다.

# =============================================================================
# 공통 값
# =============================================================================
locals {
  # for_each 에 넘기기 위해 AZ 이름을 key 로 하는 map 을 만든다.
  #   public_subnets_config  = { "ap-northeast-2a" = "10.0.1.0/24",  "ap-northeast-2c" = "10.0.2.0/24" }
  #   private_subnets_config = { "ap-northeast-2a" = "10.0.10.0/24", "ap-northeast-2c" = "10.0.20.0/24" }
  public_subnets_config  = { for i, az in var.azs : az => var.public_subnet_cidrs[i] }
  private_subnets_config = { for i, az in var.azs : az => var.private_subnet_cidrs[i] }

  # NAT Gateway 를 배치할 AZ 집합
  #   single_nat_gateway=true  : 첫 번째 AZ 하나에만 NAT 를 둔다.
  #   single_nat_gateway=false : 모든 AZ 에 NAT 를 하나씩 둔다.
  nat_gateway_azs = toset(var.single_nat_gateway ? [var.azs[0]] : var.azs)

  # Private Subnet 이 참조할 NAT Gateway 의 AZ.
  #   single_nat_gateway=true 이면 모든 Private Subnet 이 첫 번째 AZ 의 NAT 를 공유한다.
  #   single_nat_gateway=false 이면 각 Private Subnet 이 자기 AZ 의 NAT 를 사용한다.
  private_subnet_nat_az = {
    for az in var.azs : az => var.single_nat_gateway ? var.azs[0] : az
  }
}

# =============================================================================
# VPC
# =============================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# =============================================================================
# Internet Gateway
# =============================================================================
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# =============================================================================
# Public Subnet
# =============================================================================
resource "aws_subnet" "public" {
  for_each = local.public_subnets_config

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${each.key}"
    Tier = "public"
    # EKS 가 외부 노출용 (public) ALB 를 이 subnet 에 배치할 수 있도록 인식하는 태그
    "kubernetes.io/role/elb" = "1"
  }
}

# =============================================================================
# Private Subnet
# =============================================================================
resource "aws_subnet" "private" {
  for_each = local.private_subnets_config

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name = "${var.project_name}-private-${each.key}"
    Tier = "private"
    # EKS 가 내부 전용 (internal) ALB 를 이 subnet 에 배치할 수 있도록 인식하는 태그
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# =============================================================================
# NAT Gateway + Elastic IP
# =============================================================================
resource "aws_eip" "nat" {
  for_each = local.nat_gateway_azs

  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip-${each.key}"
  }

  # IGW 가 준비된 후에 EIP 할당 (일부 리전에서 순서 이슈 예방)
  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  for_each = local.nat_gateway_azs

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = {
    Name = "${var.project_name}-nat-${each.key}"
  }

  depends_on = [aws_internet_gateway.main]
}

# =============================================================================
# Public Route Table (모든 Public Subnet 이 공유)
# =============================================================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# =============================================================================
# Private Route Table (NAT Gateway 하나당 하나씩)
# =============================================================================
# single_nat_gateway=true  : 1개 RT 를 모든 Private Subnet 이 공유
# single_nat_gateway=false : AZ 마다 RT 하나씩, 자기 AZ NAT 로 outbound
resource "aws_route_table" "private" {
  for_each = local.nat_gateway_azs

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[each.key].id
  }

  tags = {
    Name = "${var.project_name}-private-rt-${each.key}"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[local.private_subnet_nat_az[each.key]].id
}
