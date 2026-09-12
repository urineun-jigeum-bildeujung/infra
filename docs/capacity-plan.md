# DEV Capacity 및 비용 운영 기준

기준일: 2026-09-12

이 문서는 Petflow DEV EKS의 기본 Capacity 선정 근거, 확장 판단 기준과 비용 절감
원칙을 기록한다. Production 용량 산정 기준으로 사용하지 않는다.

## 현재 Managed Node Group

| 항목 | 값 |
|---|---|
| Instance Type | `m7i-flex.large` |
| vCPU / Node | 2 |
| Memory / Node | 8 GiB |
| Capacity Type | On-Demand |
| AMI | AL2023 x86_64 Standard |
| Root EBS / Node | 50 GiB |
| min / desired / max | 2 / 3 / 5 |

기본 3대의 이론상 Capacity는 6 vCPU, 24 GiB다. 최대 5대에서는 10 vCPU,
40 GiB다. Kubernetes가 실제 Pod에 제공하는 Allocatable은 OS, kubelet, DaemonSet
예약분 때문에 이론값보다 작으므로 운영 판단에는 `kubectl describe node`와 Metrics를
사용한다.

## Redis / Kafka 초기 Request

GitOps PR #23 기준 DEV 초기값은 다음과 같다.

| Workload | CPU Request / Limit | Memory Request / Limit | Storage |
|---|---|---|---|
| Redis standalone | 100m / 500m | 256Mi / 512Mi | gp3 8Gi |
| Kafka broker/controller | 250m / 1 | 512Mi / 1Gi | gp3 10Gi |
| Strimzi Operator | 250m / 1 | 512Mi / 1Gi | 없음 |
| Request 합계(Limit 제외) | 600m | 1280Mi(약 1.25Gi) | gp3 18Gi |

Redis/Kafka 기본 Request만 보면 Cluster 이론 Capacity 6 vCPU/24GiB에서 즉시 Node를
증설할 수준은 아니다. Limit 합계는 동시에 예약되는 Capacity가 아니며 실제 사용량과
스케줄링 가능 여부는 다른 Platform/Application Pod, Node Allocatable과 함께 판단한다.
배포 후 `kubectl top`, Pending Event, OOMKilled와 CPU Throttling을 다시 확인한다.

## 변경 배경

이전 구성은 `c7i-flex.large` 2대였다.

| 구분 | 이전 | 현재 |
|---|---:|---:|
| Node 수 | 2 | 3 |
| vCPU / Node | 2 | 2 |
| Memory / Node | 4 GiB | 8 GiB |
| 전체 vCPU | 4 | 6 |
| 전체 Memory | 8 GiB | 24 GiB |

CI 실행 시 측정된 이전 Node 사용률은 CPU 약 87%/95%, Memory 약 85%/85%였다.
Jenkins Agent Pod 하나는 Gradle, Kaniko, Trivy, Crane 컨테이너를 함께 실행하며
약 550m CPU Request와 1088Mi Memory Request가 필요했다. 두 Node에 여유가 없어
`FailedScheduling`, `Insufficient cpu`, `Insufficient memory`가 발생할 수 있었다.

CPU 기본 Capacity는 4 vCPU에서 6 vCPU로 약 50% 증가했고, Memory는 8 GiB에서
24 GiB로 약 200% 증가했다. Backend, Jenkins, Redis, Kafka, CNPG/PostgreSQL,
pgvector, Prometheus/Grafana, MLflow와 AI Service가 함께 올라갈 계획이므로 CPU
최적화 계열보다 Memory 여유가 있는 General Purpose 계열을 선택했다.

## 확장 판단 기준

순간 Peak 한 번이 아니라 같은 현상이 반복되거나 업무 시간 동안 지속될 때 조정한다.

- Node CPU 70~80% 이상 지속
- Node Memory 75~80% 이상 지속
- `FailedScheduling`, `Insufficient cpu`, `Insufficient memory` 반복
- Pending Pod가 정상 배포 시간을 초과해 지속
- OOMKilled 반복
- CPU Throttling 증가와 응답시간 악화가 함께 발생
- Node DiskPressure 또는 50GiB Root Volume 부족 징후

확인 명령:

```bash
kubectl --context petflow-dev top nodes
kubectl --context petflow-dev top pods -A --sort-by=memory
kubectl --context petflow-dev get pods -A --field-selector=status.phase=Pending
kubectl --context petflow-dev get events -A --sort-by=.lastTimestamp
kubectl --context petflow-dev describe nodes
```

Metrics Server 또는 Prometheus가 배포되기 전에는 `kubectl top`이 동작하지 않을 수 있다.

## 확장 순서

1. Pod Request/Limit이 실제 사용량과 맞는지 먼저 확인한다.
2. 일시적인 부족은 Karpenter Node Provisioning으로 흡수한다.
3. 상시 사용량 증가라면 Managed Node Group 실제 수량을 3에서 4, 이후 5로 조정한다.
4. 5대에서도 지속적으로 부족하면 더 큰 Instance 또는 전용 NodePool을 검토한다.
5. 변경 후 Pending, OOM, Throttling과 비용을 다시 측정한다.

`eks_node_min_size`와 `eks_node_max_size`는 Terraform으로 관리한다.
`eks_node_desired_size`는 Node Group을 새로 만들 때의 초기값이다. 현재 lifecycle은
오토스케일러나 운영 조정이 변경한 desired drift를 무시하므로 기존 Node Group의 수량은
이 변수만 수정해도 바뀌지 않는다. 상시 기본 수량을 바꾸는 작업에서는 실제 Node Group
조정 방식과 lifecycle 정책을 함께 검토하고, 변경 후 코드의 초기값도 일치시킨다.

Karpenter는 Managed Node Group의 desired를 변경하지 않고 별도의 NodePool에서 Node를
프로비저닝한다. Karpenter 배포 전에는 자동 Node Provisioning이 동작하지 않는다.

## Karpenter 이후 운영

```text
Pod Pending
  → Karpenter가 요구 조건 확인
  → 추가 EC2 Node 생성
  → Node Join
  → Pod Scheduling
  → 부하 종료 후 Node 정리
```

Karpenter는 기본 Capacity 부족을 숨기는 대체 수단이 아니다. `m7i-flex.large` 3대를
기본으로 유지하고 순간 부하를 처리한다. 다음과 같이 Scheduling 특성이 명확히 달라질
때만 NodePool 분리를 검토한다.

| NodePool 후보 | Workload |
|---|---|
| General | Backend/API/일반 서비스 |
| Data | CNPG/PostgreSQL/Kafka/Monitoring |
| CI | Jenkins Agent |
| GPU Spot | AI Training Job |

GPU Node는 상시 운영하지 않는다. 학습 Job이 있을 때만 Karpenter로 Spot Node를 만들고
Job 완료 후 제거하는 것을 목표로 한다.

## DEV 비용 원칙

DEV는 운영 수준의 고가용성보다 검증 목적과 비용 절감을 우선한다.

- NAT Gateway는 1개만 사용한다.
- Managed Node는 기본 3대, 최대 5대로 제한한다.
- 상시 GPU Node를 두지 않는다.
- 불필요한 ALB/NLB와 EBS/PVC를 정기적으로 확인한다.
- 작업하지 않는 기간에는 `alldestroy.sh`로 삭제한다.
- Terraform State, Route53/ACM, 보존 S3와 Bootstrap Resource는 유지한다.

주요 비용 항목은 EKS Control Plane, EC2 Worker/Karpenter Node, NAT Gateway,
EBS, Load Balancer, S3, Data Transfer와 GPU EC2다. 특히 플랫폼 배포 후에는 ALB,
추가 Node, CNPG/Kafka/Prometheus Storage가 새 비용원이 된다.

비용은 리전, 실행 시간과 사용량에 따라 변하므로 이 문서에 고정 금액을 적지 않는다.
월별 Cost Explorer와 AWS Budget으로 실제 비용을 확인하고, Capacity 변경 PR에는 변경
이유와 예상되는 상시 리소스 수를 기록한다.
