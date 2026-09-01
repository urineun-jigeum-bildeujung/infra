# Network 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의
# 결과는 subnet key(=AZ 이름) 순으로 정렬된 list 로 반환한다.

output "vpc_id" {
  description = "생성된 VPC 의 ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC 의 CIDR"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public Subnet ID 목록 (AZ 이름 오름차순)"
  value       = [for az in sort(keys(aws_subnet.public)) : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private Subnet ID 목록 (AZ 이름 오름차순). EKS Cluster / Node Group 이 이 subnet 을 사용한다."
  value       = [for az in sort(keys(aws_subnet.private)) : aws_subnet.private[az].id]
}

output "public_subnets_by_az" {
  description = "AZ 이름을 key 로 하는 Public Subnet ID map. 예: { \"ap-northeast-2a\" = \"subnet-xxx\" }"
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "private_subnets_by_az" {
  description = "AZ 이름을 key 로 하는 Private Subnet ID map."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

output "nat_gateway_ids" {
  description = "생성된 NAT Gateway ID 목록 (AZ 이름 오름차순)"
  value       = [for az in sort(keys(aws_nat_gateway.main)) : aws_nat_gateway.main[az].id]
}

output "nat_gateway_public_ips" {
  description = "NAT Gateway 에 연결된 Elastic IP 목록. 외부에서 우리 VPC 로부터의 outbound IP 를 화이트리스트할 때 참고한다."
  value       = [for az in sort(keys(aws_eip.nat)) : aws_eip.nat[az].public_ip]
}
