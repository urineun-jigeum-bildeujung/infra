# Terraform 실행 기반 IAM 을 정의하는 스택
#
# 관리 대상:
#   - Terraform 을 실행하는 개발자용 IAM Role (필요 시)
#   - GitHub Actions Terraform OIDC Role
#   - State Backend (S3 Bucket + .tflock) 에 대한 접근 Policy
#   - (선택) State Bucket 을 SSE-KMS 로 암호화한 경우 KMS 접근 Policy
#
# ⚠️ 이 스택의 리소스는 DEV 인프라의 terraform destroy 대상이 아니다.
#    최초 1회 생성 후 계속 유지하며, 함부로 삭제하지 않는다.
#
# 실제 리소스 정의는 feat/bootstrap-iam (또는 feat/state-backend) 브랜치에서 추가한다.
#
# -----------------------------------------------------------------------------
# [체크리스트] Terraform 실행 주체(GitHub Actions OIDC Role, 개발자 Role 등)에
# 반드시 부여해야 하는 State Backend 관련 IAM 권한
#
# S3 Backend 의 native state locking(use_lockfile = true) 을 사용하므로
# lock 파일(<state_key>.tflock) 에 대한 별도 권한이 필요하다.
# DeleteObject 가 빠지면 lock 이 해제되지 않아 다음 apply 가 무한 대기하거나
# lock 획득에 실패한다.
#
# 최소 요구 권한 예시 (dev 환경 기준):
#
#   # State 파일 자체
#   {
#     "Effect": "Allow",
#     "Action": ["s3:GetObject", "s3:PutObject"],
#     "Resource": "arn:aws:s3:::<STATE_BUCKET>/dev/terraform.tfstate"
#   },
#
#   # Lock 파일 (native locking 전용)
#   {
#     "Effect": "Allow",
#     "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
#     "Resource": "arn:aws:s3:::<STATE_BUCKET>/dev/terraform.tfstate.tflock"
#   },
#
#   # Bucket 리스팅
#   {
#     "Effect": "Allow",
#     "Action": "s3:ListBucket",
#     "Resource": "arn:aws:s3:::<STATE_BUCKET>"
#   }
#
# State Bucket 을 SSE-KMS 로 암호화한 경우, 위 권한에 더해 대상 KMS Key 에
# kms:Encrypt / kms:Decrypt / kms:GenerateDataKey / kms:DescribeKey 도 필요하다.
# -----------------------------------------------------------------------------
