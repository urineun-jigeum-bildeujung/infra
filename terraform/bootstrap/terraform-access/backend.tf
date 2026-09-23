# terraform-access 스택 Terraform Remote Backend 선언
# state-backend 스택이 먼저 생성해둔 S3 Bucket 을 사용한다.
# 실제 Bucket / Key 값은 코드에 하드코딩하지 않고 backend.hcl 로 관리한다.
#
# 초기화 예시:
#   terraform init -backend-config=backend.hcl

terraform {
  backend "s3" {}
}
