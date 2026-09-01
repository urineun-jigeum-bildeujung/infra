# EKS 모듈이 외부에서 전달받는 값 정의

# =============================================================================
# 공통
# =============================================================================
variable "project_name" {
  description = "프로젝트 식별용 접두사. Cluster/Node Group 이름에 사용한다."
  type        = string
}

# =============================================================================
# Cluster
# =============================================================================
variable "cluster_version" {
  description = "EKS 버전. 예: 1.31, 1.32, 1.35"
  type        = string
}

variable "cluster_role_arn" {
  description = "EKS Cluster Role ARN (modules/iam 에서 생성)"
  type        = string
}

variable "node_role_arn" {
  description = "EKS Worker Node Role ARN (modules/iam 에서 생성). Managed Node Group EC2 인스턴스가 사용."
  type        = string
}

variable "vpc_id" {
  description = "EKS 가 배포될 VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "EKS control plane 및 Node Group 이 사용할 Private Subnet ID 목록"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Cluster 의 endpoint_public_access 를 위한 Public Subnet ID 목록. Node 는 여기 배치되지 않음."
  type        = list(string)
}

# =============================================================================
# Endpoint
# =============================================================================
variable "endpoint_public_access" {
  description = "Cluster API 서버의 Public Endpoint 활성화 여부"
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Cluster API 서버의 Private Endpoint (VPC 내부에서 접근) 활성화 여부"
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "Public Endpoint 접근을 허용할 CIDR 목록. 초기엔 넓게 열고 Tailscale 연결 후 좁힌다."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# =============================================================================
# Access Entry
# =============================================================================
variable "cluster_admin_principal_arns" {
  description = <<-EOT
    Cluster Admin 권한을 부여할 IAM User/Role ARN 목록.
    예: ["arn:aws:iam::297165773875:user/ujibil2"]
    빈 리스트로 두면 API 인증 모드에서 아무도 kubectl 접근 불가하므로 최소 1개 이상 필요.
  EOT
  type        = list(string)
  default     = []
}

# =============================================================================
# Managed Node Group
# =============================================================================
variable "node_instance_types" {
  description = "Managed Node Group 의 EC2 인스턴스 타입 후보 목록"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_ami_type" {
  description = "Managed Node Group AMI 종류. AL2023_x86_64_STANDARD / AL2_x86_64 등"
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "node_disk_size" {
  description = "Managed Node Group 각 노드의 root EBS 크기 (GB)"
  type        = number
  default     = 20
}

variable "node_desired_size" {
  description = "Managed Node Group desired 노드 수"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Managed Node Group 최소 노드 수"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Managed Node Group 최대 노드 수. Karpenter 도입 전 임시 상한."
  type        = number
  default     = 3
}
