# Platform IAM 모듈이 노출하는 값 정의
# Pod Identity 방식이므로 GitOps Helm values 에 role-arn annotation 은 필요 없지만,
# EC2NodeClass(role 필드)와 운영 확인용으로 아래 값들을 노출한다.

output "alb_controller_role_arn" {
  description = "AWS Load Balancer Controller Role ARN (Pod Identity 로 kube-system/aws-load-balancer-controller 에 연결됨)"
  value       = aws_iam_role.alb_controller.arn
}

output "karpenter_controller_role_arn" {
  description = "Karpenter Controller Role ARN (Pod Identity 로 kube-system/karpenter 에 연결됨)"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_role_name" {
  description = "Karpenter 가 만드는 Worker 노드용 Role 이름. GitOps 의 EC2NodeClass spec.role 에 이 값을 사용한다."
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_node_role_arn" {
  description = "Karpenter Node Role ARN"
  value       = aws_iam_role.karpenter_node.arn
}
