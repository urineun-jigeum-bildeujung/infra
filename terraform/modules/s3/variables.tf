# S3 모듈이 외부에서 전달받는 값 정의

variable "project_name" {
  description = "프로젝트 식별용 접두사. Bucket 이름에 사용한다."
  type        = string
}
