variable "domain_name" {
  description = "Route53에서 관리할 루트 도메인 이름"
  type        = string

  validation {
    condition     = can(regex("^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name은 leechs.shop과 같은 유효한 소문자 루트 도메인이어야 합니다."
  }
}
