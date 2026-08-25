# IAM 모듈: DEV 애플리케이션 / 플랫폼 인프라에서 사용하는 IAM Role 및 Policy 를 정의한다.
#
# 이 모듈이 생성하는 IAM 은 DEV 인프라와 동일한 생명주기를 갖는다.
# 즉 terraform destroy 로 함께 삭제되어도 무방하며, terraform apply 로 다시 생성된다.
#
# 관리 대상 (DEV 삭제 대상):
#   - EKS Cluster Role
#   - EKS Worker Node Role
#   - AWS Load Balancer Controller Role
#   - Karpenter Role
#   - 애플리케이션용 IAM Role
#   - 기타 DEV 서비스용 IAM Role
#
# ❌ 이 모듈에서 관리하지 않는 것 (Bootstrap 영역):
#   - Terraform 실행용 개발자 Role
#   - GitHub Actions Terraform OIDC Role
#   - State Backend (S3 Bucket / .tflock) 접근 Policy
#
#   위 리소스들은 DEV destroy 대상이 되면 안 되므로
#   terraform/bootstrap/terraform-access/ 스택에서 별도로 관리한다.
#
# 실제 리소스 정의는 feat/iam 브랜치에서 추가한다.
