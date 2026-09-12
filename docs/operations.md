# DEV 인프라 운영 절차

기준일: 2026-09-12

이 문서는 Petflow DEV 인프라의 Apply, 재생성 검증, Destroy, 장애 확인과
CloudNative 팀 인계 절차를 정의한다. 모든 명령은 `infra` 프로젝트 루트에서 실행한다.

## 운영 환경 역할

| 환경 | 역할 | Tailscale Route |
|---|---|---|
| VMware | Terraform, Git, PR, AWS CLI | 운영 기준 `accept-routes=false` |
| Windows/WSL | kubectl, k9s, Private 관리 UI, Kubernetes Cleanup | Tailscale ON |
| AWS Router | VPC `10.0.0.0/20` Subnet Router | 항상 실행 |

VMware LAN과 기존 Tailnet의 `172.16.8.0/24` Route가 겹치므로 VMware는 일반적으로
Subnet Route를 받지 않는다. 통합 작업을 VMware에서 수행하도록 임시 변경했다면 SSH
경로와 `ip route`를 먼저 확인하고 작업 후 원래 운영 기준으로 되돌린다.

## 공통 사전 확인

```bash
git switch dev
git pull --ff-only

export AWS_PROFILE=ujibil2
aws sts get-caller-identity
```

예상 Account는 `297165773875`, Region은 `ap-northeast-2`다. Account가 다르면 즉시
중단한다. `terraform.tfvars`, `backend.hcl`, Secret, kubeconfig는 커밋하지 않는다.

## Plan / Apply

```bash
./tinit.sh
./tplan.sh
./tapply.sh
```

`tapply.sh`는 `--auto-approve`로 실행되므로 Plan을 먼저 검토한다. 예상하지 않은
Route53/ACM/S3 교체, EKS/VPC 삭제, IAM 대량 변경이 있으면 Apply하지 않는다.

## Apply 후 기본 검증

Terraform Output을 확인하고 EKS가 재생성된 경우 kubeconfig를 반드시 갱신한다.

```bash
terraform -chdir=terraform/environments/dev output

AWS_PROFILE=ujibil2 aws eks update-kubeconfig \
  --region ap-northeast-2 \
  --name petflow-eks \
  --alias petflow-dev

kubectl --context petflow-dev get --raw=/readyz
kubectl --context petflow-dev get nodes -o wide
kubectl --context petflow-dev get pods -A
```

정상 기준:

- EKS `ACTIVE`, Public Endpoint OFF, Private Endpoint ON
- Managed Node Group `ACTIVE`, `m7i-flex.large`, min/desired/max `2/3/5`
- Worker Node 3대 `Ready`
- EKS 관리형 Add-on 모두 `ACTIVE`
- Pending/CrashLoopBackOff/OOMKilled Pod 없음
- Terraform Plan `No changes`

이전 Cluster의 API Endpoint가 kubeconfig에 남으면 k9s가 DNS 오류와 긴 재시도를 반복한다.
재생성 후에는 항상 `update-kubeconfig`를 다시 실행한다.

## Tailscale 확인

```bash
terraform -chdir=terraform/environments/dev output tailscale_router_instance_id
terraform -chdir=terraform/environments/dev output tailscale_router_private_ip
tailscale status
tailscale ping petflow-dev-tailscale-router
```

Router EC2 ID, Private IP와 Tailscale IP는 재생성 시 바뀔 수 있다. 문서에 적힌 과거 IP를
사용하지 말고 현재 Output과 Tailnet 상태를 조회한다. Router는 SSM `Online`, Route
`10.0.0.0/20`이 승인된 상태여야 한다.

AWS NAT Gateway 뒤의 Private Router는 Tailscale direct 연결 대신 DERP Relay를 사용할
수 있다. 이 경우 kubectl/k9s가 느릴 수 있으므로 장애 판단 전에 `tailscale ping` 결과와
EKS API 요청 시간을 구분해 확인한다.

## CloudNative 팀 인계

Infra 팀이 제공하는 값은 [Terraform Output 가이드](terraform-outputs.md)를 기준으로
전달한다. Secret 값은 문서나 PR에 넣지 않는다.

| CloudNative 대상 | Infra 제공/검증 |
|---|---|
| Argo CD | EKS API/RBAC/Network 기반 |
| Jenkins/Kaniko | Pod Identity와 ECR Push Policy |
| CNPG | EBS CSI, Pod Identity, S3 Backup 경로 |
| Karpenter | Controller/Node IAM, Access Entry, Subnet/SG Discovery Tag |
| Ingress | ALB Controller IAM, Subnet Tag, ACM/Route53 |
| Redis/Kafka/Monitoring | Node Capacity, Network, EBS 기반 |

CloudNative 팀은 Argo CD, Jenkins 플랫폼, CNPG, Redis, Kafka, Prometheus/Grafana,
Loki/Tempo, KEDA와 Application Helm Resource를 배포한다. Infra 팀은 배포 이후 다음
AWS/EKS 경계를 함께 검증한다.

1. Argo CD Application이 EKS에 정상 Sync된다.
2. Jenkins Agent가 생성되고 Kaniko가 ECR에 Image를 Push한다.
3. CNPG PVC가 EBS에 Bound되고 S3 Backup/Restore가 동작한다.
4. Redis/Kafka가 요청한 Network와 Storage에서 정상 기동한다.
5. Ingress가 ALB/Target Group을 만들고 Target이 Healthy다.
6. Route53 Record와 ACM 인증서로 HTTPS가 동작한다.
7. Pending 부하에서 Karpenter가 Node를 만들고 회수한다.
8. Monitoring에서 Node/Pod 사용률을 확인할 수 있다.

## Destroy

통합 삭제는 EKS Private API에 접근할 수 있고 Terraform/AWS CLI가 준비된 환경에서
실행한다.

```bash
AWS_PROFILE=ujibil2 ./alldestroy.sh
```

동작 순서:

```text
cleanup-k8s.sh
  → Argo CD 동기화 중지
  → Ingress / LoadBalancer Service 삭제
  → AWS Load Balancer 소멸 확인
tdestroy.sh
  → Terraform 관리 DEV 모듈 삭제
```

Kubernetes Cleanup이 실패하면 Terraform Destroy는 실행되지 않는다. 역할을 분리할 때는
Windows/WSL에서 Cleanup을 완료하고 VMware에서 Terraform Destroy를 실행한다.

```bash
# Windows/WSL + Tailscale ON
AWS_PROFILE=ujibil2 ./cleanup-k8s.sh

# VMware
AWS_PROFILE=ujibil2 ./tdestroy.sh
```

보존 대상:

- Terraform State Backend와 Bootstrap IAM
- Route53 Hosted Zone와 ACM 인증서
- `static`, `product-images`, `uploads`, `db-backups` S3 Bucket
- Tailscale OAuth Secret

## 장애 확인 순서

| 증상 | 우선 확인 |
|---|---|
| kubectl/k9s DNS 오류 | 현재 EKS Endpoint와 kubeconfig server 비교 후 갱신 |
| kubectl/k9s 지연 | `tailscale ping`, direct/DERP 여부, API 응답시간 |
| Node NotReady | Node Group Health, EC2 Status Check, CNI/Node 이벤트 |
| Pod Pending | Request/Limit, FailedScheduling 이벤트, Node Allocatable |
| ImagePullBackOff | ECR Image/Tag 존재, Node ECR 권한, values Tag |
| PVC Pending | StorageClass, EBS CSI, AZ/Topology 이벤트 |
| ALB 미생성 | Controller, Pod Identity, IngressClass, Subnet Tag |
| Terraform State 오류 | AWS Account/Profile, S3 권한, `.tflock` 상태 |

운영 명령은 현상을 확인하는 읽기 전용 조회부터 시작한다. 리소스 삭제, 강제 재시작,
State 조작은 원인과 대상 범위를 확인한 뒤 별도 승인 하에 수행한다.
