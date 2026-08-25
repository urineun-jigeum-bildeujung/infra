# S3 모듈: 애플리케이션에서 사용하는 S3 Bucket 을 정의한다.
#
# 관리 대상 예시:
#   - Frontend 정적 파일
#   - 상품 이미지
#   - 사용자 업로드 파일
#
# 주의:
#   Terraform State 저장용 S3 Bucket 은 terraform/bootstrap/state-backend 에서 별도로 관리한다.
#   이 모듈에서 만드는 Bucket 은 절대 State 저장 용도로 사용하지 않는다.

