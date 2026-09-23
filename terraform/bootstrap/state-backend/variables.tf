# State Backend 스택에서 사용하는 입력 변수 정의

variable "aws_region" {
  description = "State 저장용 Bucket 을 생성할 AWS 리전"
  type        = string
}

variable "project_name" {
  description = "프로젝트 식별용 접두사. Bucket 이름 등에 사용한다."
  type        = string
}

variable "state_bucket_name" {
  description = "Terraform State 를 저장할 S3 Bucket 이름"
  type        = string
}
