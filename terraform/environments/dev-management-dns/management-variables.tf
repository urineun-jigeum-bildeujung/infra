variable "argocd_hostname" {
  description = "Tailscale과 Management Internal ALB를 통해 접근할 Argo CD FQDN"
  type        = string
  default     = "argocd.leechs.shop"

  validation {
    condition     = startswith(var.argocd_hostname, "argocd.") && endswith(var.argocd_hostname, var.domain_name)
    error_message = "argocd_hostname은 domain_name 아래의 argocd 서브도메인이어야 합니다."
  }
}

variable "jenkins_hostname" {
  description = "Tailscale과 Management Internal ALB를 통해 접근할 Jenkins FQDN"
  type        = string
  default     = "jenkins.leechs.shop"

  validation {
    condition     = startswith(var.jenkins_hostname, "jenkins.") && endswith(var.jenkins_hostname, var.domain_name)
    error_message = "jenkins_hostname은 domain_name 아래의 jenkins 서브도메인이어야 합니다."
  }
}
