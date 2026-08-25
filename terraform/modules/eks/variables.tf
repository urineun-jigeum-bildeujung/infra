# EKS 모듈이 외부에서 전달받는 값 정의

variable "project_name" {
  description = "프로젝트 식별용 접두사. EKS Cluster 및 Node Group 이름에 사용한다."
  type        = string
}

variable "private_subnet_ids" {
  description = "EKS 컨트롤 플레인 및 노드가 배치될 Private Subnet ID 목록"
  type        = list(string)
}
