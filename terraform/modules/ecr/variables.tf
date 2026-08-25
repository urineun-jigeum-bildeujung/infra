# ECR 모듈이 외부에서 전달받는 값 정의

variable "project_name" {
  description = "프로젝트 식별용 접두사. Repository 이름 태그에 사용한다."
  type        = string
}

variable "repository_names" {
  description = "생성할 ECR Repository 이름 목록. 예: [\"user-service\", \"product-service\"]"
  type        = list(string)
  default     = []
}
