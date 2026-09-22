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

## 2차 점검에서 발견·수정한 문제

### 배포 실패로 이어지던 치명적 문제

**1. EKS 관리형 애드온 전체 누락**
vpc-cni, coredns, kube-proxy, EBS CSI Driver가 하나도 없었습니다. vpc-cni 없이는 파드가 IP를 받지 못하고, EBS CSI 없이는 PVC가 영원히 Pending에 머뭅니다. `eks-addons.tf`로 전부 추가했습니다.

**2. gp3 StorageClass 미정의**
`addons.tf`의 Prometheus PVC가 `storageClassName: gp3`를 참조하는데 정작 그 StorageClass를 만든 적이 없었습니다. 그대로 apply하면 Prometheus가 기동되지 않습니다. 생성 코드를 추가하고, 기존 gp2의 default 어노테이션도 해제했습니다(default가 2개면 충돌).

**3. Karpenter 노드가 클러스터에 조인할 권한 없음**
`aws_eks_access_entry`가 없어서, Karpenter가 EC2는 정상적으로 만들지만 그 노드가 클러스터에 들어오지 못하고 NotReady로 방치됩니다. 원인 파악이 어려운 대표적 함정이라 반드시 필요합니다.

**4. Karpenter v1 InstanceProfile 권한 누락**
v1부터 Karpenter는 EC2NodeClass의 `role` 값을 받아 InstanceProfile을 스스로 생성·관리합니다. `iam:CreateInstanceProfile` 계열 권한이 없으면 프로비저닝이 그 단계에서 멈춥니다.

**5. `required_providers` 블록 자체가 부재**
tls, helm, kubernetes 프로바이더를 쓰면서 선언하지 않아 `terraform init`이 실패합니다.

### 동작은 하지만 위험하던 문제

**6. SQS 큐 정책 없음**
EventBridge가 큐에 메시지를 넣을 권한이 없어, Spot 중단 경고가 Karpenter에 전달되지 않았습니다. 결과적으로 2분의 유예 시간을 못 쓰고 노드가 갑자기 사라집니다.

**7. 중단 이벤트 3종 누락**
Spot Interruption만 있었습니다. 특히 **Rebalance Recommendation**은 실제 중단보다 먼저 도착해 더 여유롭게 파드를 옮길 수 있게 해주는 신호입니다. 총 4종으로 확장했습니다.

**8. 보안그룹 셀렉터 불일치**
NodePool이 `kubernetes.io/cluster/...: owned` 태그를 찾고 있었으나 어디에서도 그 태그를 부착하지 않았습니다. 클러스터 보안그룹에 `karpenter.sh/discovery` 태그를 붙이고 셀렉터도 맞췄습니다.

**9. 컨트롤 플레인 로깅 비활성**
스케일링 문제를 디버깅할 때 scheduler/controllerManager 로그가 핵심 단서인데 꺼져 있었습니다. 활성화하고 로그 그룹 보존 기간을 30일로 지정했습니다(미지정 시 무기한 보관되어 비용이 계속 누적됩니다).

**10. 코어 노드 스펙(t3.medium) 부족**
t3.medium은 파드 IP 할당 한도가 낮아(최대 17개) ArgoCD·Prometheus·Karpenter·KEDA를 모두 올리면 IP가 고갈됩니다. m7i.large로 상향했습니다.

### 추가 보안 강화

- etcd Secret의 KMS 암호화 활성화
- EKS API 퍼블릭 접근 CIDR을 변수화 (기본값 0.0.0.0/0은 전 세계 개방 상태 — 운영 전환 시 Tailscale/사무실 대역으로 제한 필요)
- 노드에 SSM 권한 부여 (SSH 키 없이 Session Manager 접속 → 22번 포트 개방 불필요)
- 컨트롤 플레인 서브넷에서 public subnet 제외

---

## 3차 점검에서 발견·수정한 문제

**11. HPA와 KEDA가 같은 Deployment(`api-service`)를 동시에 타겟팅**
KEDA는 ScaledObject 생성 시 내부적으로 자체 HPA를 만듭니다. 사용자가 만든 HPA와 KEDA의 HPA가 같은 대상을 동시에 관리하면, 서로 다른 판단 기준(CPU vs RPS)으로 replica 수를 계속 되돌리며 충돌합니다. HPA는 `user-service`(단순 CPU 기준), KEDA는 `payment-service`(CPU+RPS 복합 트리거)로 대상을 분리했습니다. **하나의 Deployment는 HPA 또는 KEDA 중 하나만 사용하세요.**

**12. 존재하지 않는 `gp2` StorageClass를 패치 시도**
EKS 1.23+는 in-tree provisioner가 제거되어 `gp2`가 기본으로 존재하지 않을 수 있습니다. `kubernetes_annotations`로 없는 리소스를 패치하려 하면 apply가 그대로 실패합니다. 존재 여부와 무관하게 안전하게 넘어가도록 `kubectl patch ... || echo`로 대체했습니다.

**13. Overprovisioning 더미 파드의 nodeSelector 누락**
더미 파드가 nodeSelector 없이 코어(On-Demand) 노드에 앉을 수 있었습니다. 그러면 정작 확보하려던 Karpenter 워크로드 노드의 여유 자원은 그대로이고 코어 노드 자원만 낭비됩니다. `node-role: workload`로 명시했습니다.

**14. KMS 키 정책 보강**
기본 정책(계정 root 전체 허용)만으로도 동작하지만, EKS 클러스터 역할의 사용 권한을 명시적으로 추가해 최소 권한 원칙에 맞췄습니다.

---

## 4차 점검에서 발견·수정한 문제

**15. VPC CNI Prefix Delegation 미활성화 (비용 목표와 직결)**
`c7i-flex.large`/`m7i.large`처럼 vCPU가 적은 인스턴스는 기본 CNI 설정에서 ENI당 붙일 수 있는 IP 개수가 제한되어 노드당 파드를 10개 안팎밖에 못 올립니다. 이 상태면 파드가 조금만 늘어도 Karpenter가 필요 이상으로 많은 노드를 띄우게 되어, **Spot으로 단가를 낮춰도 대수가 늘어나 비용 절감 효과가 상쇄됩니다.** Prefix Delegation을 켜서 노드당 파드 밀도를 크게 높였습니다.

**16. KEDA가 참조하는 `kafka-credentials` Secret 부재**
`TriggerAuthentication`이 존재하지 않는 Secret을 참조하고 있어 ScaledObject가 계속 에러 상태로 대기하게 됩니다. 구조를 보여주는 플레이스홀더를 추가했고, 실제 값은 평문 커밋 대신 External Secrets Operator(아키텍처에 이미 포함된 Secrets Manager 연동)로 교체하도록 주석을 남겼습니다.

---

## 5차 점검에서 발견·수정한 문제

**17. `msa` 네임스페이스 미정의 (그대로 적용하면 전부 실패)**
PDB, HPA, KEDA ScaledObject가 전부 `namespace: msa`를 참조하는데, 이 네임스페이스를 만드는 매니페스트가 어디에도 없었습니다. `monitoring`, `keda`는 Helm이 `create_namespace=true`로 자동 생성했지만 `msa`는 빠져 있었습니다. 그대로 `kubectl apply`하면 "namespace not found"로 전부 실패합니다. `k8s-namespace.yaml`을 추가하고, ArgoCD sync-wave로 다른 리소스보다 먼저 생성되도록 했습니다.

같은 파일에 두 가지를 더 넣었습니다:
- **ResourceQuota**: HPA/KEDA의 `maxReplicaCount`를 개별적으로 걸어도, 서비스 개수가 늘면 네임스페이스 전체 합계가 노드 용량을 초과할 수 있어 상한을 추가했습니다.
- **LimitRange**: 개발자가 Deployment에 requests/limits를 깜빡 빠뜨리면 HPA가 사용률 자체를 계산 못 합니다. 기본값을 강제해 최소한의 안전장치를 뒀습니다. 백엔드팀 협의로 실측치가 나오면 이 기본값을 교체하세요.

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

---

## 아직 남은 작업

### 인프라
- [ ] Terraform backend를 S3 + DynamoDB로 전환 (팀 협업 시 state 충돌 방지)
- [ ] `cluster_public_access_cidrs`를 실제 접근 대역으로 제한
- [ ] ALB Controller IAM 정책을 AWS 공식 JSON으로 교체 (현재는 요약본)
- [ ] External Secrets Operator + Secrets Manager 연동
- [ ] Route53 + WAF 구성

### 백엔드 협의
- [ ] 서비스별 `resources.requests/limits` 실측 산정
- [ ] Kafka 토픽 파티션 개수 → `maxReplicaCount` 상한 확정
- [ ] `lagThreshold` 부하 테스트 기반 튜닝
- [ ] Graceful shutdown (SIGTERM) 구현 확인 — Spot 사용 시 특히 중요
- [ ] DB 커넥션 풀 최대치 × maxReplicas ≤ PostgreSQL max_connections 검증
- [ ] Readiness/Liveness Probe 엔드포인트 정의

### 검증
- [ ] k6/Locust 부하 테스트로 HPA → Karpenter 전체 체인 확인
- [ ] Spot 중단 시뮬레이션 (AWS FIS로 강제 회수 테스트)
