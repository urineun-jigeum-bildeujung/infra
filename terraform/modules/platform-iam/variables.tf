# Platform IAM 모듈이 외부에서 전달받는 값 정의

variable "project_name" {
  description = "프로젝트 식별용 접두사. Role 이름은 <project>-<environment>-<이름> 형태가 된다."
  type        = string
}

variable "environment" {
  description = "환경 식별자 (dev / prod). Role 이름에 포함된다."
  type        = string
}

variable "cluster_name" {
  description = "Pod Identity Association 과 Access Entry 를 연결할 EKS Cluster 이름 (modules/eks 의 output)"
  type        = string
}

variable "aws_region" {
  description = "Karpenter 정책의 리소스 조건에 사용할 리전"
  type        = string
}
