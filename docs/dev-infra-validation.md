# DEV 플랫폼 기반 검증 결과

- 검증 일자: 2026-09-09
- AWS Account: `297165773875`
- Region: `ap-northeast-2`
- 기준 브랜치: `feat/karpenter-network`

## Terraform Plan

```text
Plan: 1 to add, 2 to change, 0 to destroy.
```

계획된 변경은 다음 Discovery Tag뿐이다.

- EKS Cluster Security Group Tag 1개 생성
- Private Subnet 2개의 Tag 인플레이스 변경
- 리소스 교체 및 삭제 없음

공유 State에 등록된 `ujibil5` EKS Access Entry가 로컬 입력에서 빠져 삭제될 위험을 발견했고,
`terraform.tfvars.example` 및 담당자 로컬 `terraform.tfvars` 목록에 추가해 삭제 계획을 제거했다.

## EKS

| 확인 항목 | 결과 |
|---|---|
| Cluster | `petflow-eks`, `ACTIVE`, Kubernetes 1.35 |
| Managed Node Group | `ACTIVE`, `c7i-flex.large`, desired 2 |
| Worker Node | 2대 모두 `Ready` |
| 배치 AZ | `ap-northeast-2b`, `ap-northeast-2d` |
| kube-system Pod | 12개 모두 `Running` |
| 비정상 Pod | 없음 |

EKS Add-on은 `coredns`, `kube-proxy`, `vpc-cni`, `aws-ebs-csi-driver`,
`eks-pod-identity-agent` 모두 `ACTIVE` 상태를 확인했다.

## Network

| 확인 항목 | 결과 |
|---|---|
| VPC | `10.0.0.0/20`, available |
| Public Subnet | 2개, `kubernetes.io/role/elb=1` |
| Private Subnet | 2개, `kubernetes.io/role/internal-elb=1` |
| Private Default Route | `0.0.0.0/0` → NAT Gateway, active |
| NAT Gateway | available |
| Karpenter Subnet Discovery | PR 병합 및 apply 후 적용 예정 |
| Karpenter SG Discovery | PR 병합 및 apply 후 적용 예정 |

## Karpenter AWS 기반

| 확인 항목 | 결과 |
|---|---|
| Controller Role | `petflow-dev-karpenter-controller` 존재 |
| Node Role | `petflow-dev-karpenter-node` 존재 |
| Node Access Entry | `EC2_LINUX` 정상 |
| Controller 인증 | `kube-system/karpenter` Pod Identity 정상 |

Karpenter Helm, EC2NodeClass, NodePool 및 실제 신규 Worker Node 생성 검증은 GitOps 범위다.

## AWS Load Balancer Controller AWS 기반

| 확인 항목 | 결과 |
|---|---|
| Controller Role | `petflow-dev-alb-controller` 존재 |
| Controller 인증 | `kube-system/aws-load-balancer-controller` Pod Identity 정상 |
| Public ALB Subnet Tag | Public Subnet 2개 모두 정상 |
| Internal ALB Subnet Tag | Private Subnet 2개 모두 정상 |

Controller Helm과 Ingress가 아직 배포되지 않았으므로 실제 ALB, Listener, Target Group 및
Target Health 검증은 GitOps 배포 후 수행한다.

## 남은 완료 조건

1. PR #16을 `dev`에 병합한다.
2. `dev`에서 plan이 Discovery Tag 3건만 포함하는지 재확인한다.
3. Terraform apply 후 Private Subnet 2개와 Cluster Security Group 1개의 Discovery Tag를 확인한다.
4. GitOps 팀이 Karpenter 및 ALB Controller를 배포한다.
5. Pending Pod 기반 노드 증설과 Ingress 기반 ALB/Target Health를 통합 검증한다.
