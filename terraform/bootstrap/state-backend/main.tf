# Terraform State 저장용 S3 Bucket 및 관련 보안 설정을 정의하는 파일
# 실제 리소스 코드는 이후 별도 브랜치에서 추가한다.
#
# 이 스택에서 생성해야 하는 리소스 예시:
#   - aws_s3_bucket                     : State 저장 Bucket
#   - aws_s3_bucket_versioning          : 버전 관리 활성화
#   - aws_s3_bucket_public_access_block : 퍼블릭 접근 차단
#   - aws_s3_bucket_server_side_encryption_configuration : 서버측 암호화
#
# 주의: 이 Bucket 은 절대 terraform destroy 로 삭제하지 않는다.
