# DEV Web DNS는 Kubernetes가 생성한 ALB 이후에 적용되므로 코어 DEV 인프라와
# 별도 State에서 관리한다.
terraform {
  backend "s3" {}
}
