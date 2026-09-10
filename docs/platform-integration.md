# Karpenter / AWS Load Balancer Controller 연동 계약

이 문서는 Terraform이 제공하는 AWS 인프라와 GitOps가 배포하는 Kubernetes 리소스 사이의 인터페이스를 정의한다.

## 역할 구분

| 영역 | Infra(Terraform) | GitOps / CN |
|---|---|---|
| Karpenter | IAM, EKS Access Entry, Private Subnet/SG Discovery Tag | Helm, EC2NodeClass, NodePool |
| AWS Load Balancer Controller | IAM, Pod Identity Association, Subnet Tag, Helm 설치 인터페이스 | Ingress |

Terraform은 Controller의 AWS 권한 기반을 관리하고, Infra 저장소의 설치 스크립트가
AWS Load Balancer Controller Helm Release를 관리한다. ALB 자체는 Kubernetes Ingress를
감시하는 Controller가 생성한다. Karpenter Helm은 계속 GitOps 범위다.

## Karpenter 전달 값

| 항목 | 값 |
|---|---|
| Cluster Name | `petflow-eks` |
| Controller Namespace | `kube-system` |
| Controller ServiceAccount | `karpenter` |
| IAM 방식 | EKS Pod Identity |
| Node Role | `petflow-dev-karpenter-node` |
| Subnet Discovery | `karpenter.sh/discovery=petflow-eks` |
| Security Group Discovery | `karpenter.sh/discovery=petflow-eks` |

Pod Identity를 사용하므로 Karpenter ServiceAccount에 `eks.amazonaws.com/role-arn` annotation을 추가하지 않는다.

EC2NodeClass에는 다음 Discovery 조건을 사용한다.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: petflow-dev-karpenter-node
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: petflow-eks
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: petflow-eks
  # amiSelectorTerms 등 나머지 설정은 GitOps 정책에서 관리한다.
```

Discovery Tag는 Worker Node가 배치될 두 Private Subnet과 EKS Cluster Security Group 하나에만 적용한다.

## AWS Load Balancer Controller 전달 값

| 항목 | 값 |
|---|---|
| Cluster Name | `petflow-eks` |
| Namespace | `kube-system` |
| ServiceAccount | `aws-load-balancer-controller` |
| IAM 방식 | EKS Pod Identity |
| Public Subnet Tag | `kubernetes.io/role/elb=1` |
| Private Subnet Tag | `kubernetes.io/role/internal-elb=1` |

AWS Load Balancer Controller도 Pod Identity를 사용하므로 ServiceAccount IAM Role annotation은 추가하지 않는다.
Internet-facing ALB는 Public Subnet, internal ALB는 Private Subnet을 선택한다.

### Controller 설치/업그레이드

Terraform apply로 IAM Role, Policy, Pod Identity가 준비된 뒤 프로젝트 루트에서 실행한다.

```bash
AWS_PROFILE=ujibil2 ./scripts/install-alb-controller.sh
```

스크립트는 Terraform output에서 Cluster Name, Region, VPC ID를 읽으며 다음 작업을 수행한다.

1. `kube-system/aws-load-balancer-controller` Pod Identity Association 확인
2. 고정된 Helm Chart `3.5.0`의 CRD 적용
3. Helm Release 설치 또는 업그레이드
4. Deployment rollout 및 Pod 상태 확인

Helm values는 `kubernetes/alb-controller/values-dev.yaml`에서 관리한다. 기존
`ingress-nginx` LoadBalancer Service에 영향을 주지 않도록 Service mutator webhook은
비활성화하고, `ingressClassName: alb`인 Ingress만 ALB 대상으로 사용한다.

## Terraform Output

```bash
terraform -chdir=terraform/environments/dev output eks_cluster_name
terraform -chdir=terraform/environments/dev output eks_cluster_security_group_id
terraform -chdir=terraform/environments/dev output karpenter_node_role_name
terraform -chdir=terraform/environments/dev output karpenter_discovery_value
terraform -chdir=terraform/environments/dev output alb_controller_role_arn
terraform -chdir=terraform/environments/dev output alb_controller_service_account
```

## AWS 검증

```bash
aws ec2 describe-subnets \
  --region ap-northeast-2 \
  --filters Name=tag:karpenter.sh/discovery,Values=petflow-eks

aws ec2 describe-security-groups \
  --region ap-northeast-2 \
  --filters Name=tag:karpenter.sh/discovery,Values=petflow-eks

aws eks list-pod-identity-associations \
  --cluster-name petflow-eks \
  --region ap-northeast-2
```

Karpenter Discovery 결과는 Private Subnet 2개와 Security Group 1개여야 한다.

## 최종 통합 검증

GitOps가 Controller와 Ingress를 배포한 뒤 다음을 확인한다.

```bash
kubectl get ec2nodeclass,nodepool
kubectl get pods -n kube-system
kubectl get ingress -A
kubectl get deployment aws-load-balancer-controller -n kube-system
```

- Pending Pod 발생 시 Karpenter가 새 Worker Node를 생성하는지 확인한다.
- 생성된 Node가 EKS에 Join하고 Pod가 Running으로 전환되는지 확인한다.
- Ingress 생성 시 ALB, Listener, Target Group이 생성되는지 확인한다.
- Target Group의 Target이 Healthy인지 확인한다.
