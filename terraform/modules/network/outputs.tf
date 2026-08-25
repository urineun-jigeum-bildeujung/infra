# Network 모듈이 다른 모듈 또는 Environment 에 노출하는 값 정의
#
# 예시:
#   output "vpc_id"             { value = aws_vpc.main.id }
#   output "public_subnet_ids"  { value = aws_subnet.public[*].id }
#   output "private_subnet_ids" { value = aws_subnet.private[*].id }
