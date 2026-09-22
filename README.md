# EKS 오토스케일링 인프라 (ap-northeast-2, 2 AZ)

## 파일 구성

| 파일 | 역할 | 관리 주체 |
|---|---|---|
| `versions.tf` | 프로바이더 버전 선언, backend 설정 | Terraform |
| `vpc.tf` | VPC, Subnet x2 AZ, NAT Gateway(변수화), IGW | Terraform |
| `eks.tf` | EKS 클러스터, 로깅/암호화, 코어 Node Group | Terraform |
| `eks-addons.tf` | 관리형 애드온, EBS CSI, gp3 SC, Access Entry, ALB Controller | Terraform |
| `karpenter-iam.tf` | Karpenter IRSA, SQS + 큐 정책, EventBridge 4종 | Terraform |
| `addons.tf` | Metrics Server, Prometheus Stack, Adapter, KEDA | Terraform (Helm) |
| `k8s-namespace.yaml` | msa 네임스페이스, ResourceQuota, LimitRange | ArgoCD (GitOps) — **가장 먼저 적용** |
| `karpenter-nodepool.yaml` | NodePool / EC2NodeClass | ArgoCD (GitOps) |
| `k8s-pdb-overprovisioning.yaml` | PDB, PriorityClass, Overprovisioning, HPA | ArgoCD (GitOps) |
| `k8s-keda-scaledobject.yaml` | KEDA ScaledObject | ArgoCD (GitOps) |

---

## 적용 순서

```bash
terraform init
terraform plan
terraform apply

aws eks update-kubeconfig --name msa-eks-cluster --region ap-northeast-2

# Karpenter 컨트롤러 설치
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.0.0 --namespace kube-system \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$(terraform output -raw karpenter_controller_role_arn)" \
  --set settings.clusterName=msa-eks-cluster \
  --set settings.interruptionQueue=$(terraform output -raw karpenter_interruption_queue_name) \
  --set nodeSelector.node-role=core

kubectl apply -f k8s-namespace.yaml
kubectl apply -f karpenter-nodepool.yaml
kubectl apply -f k8s-pdb-overprovisioning.yaml
kubectl apply -f k8s-keda-scaledobject.yaml
```
