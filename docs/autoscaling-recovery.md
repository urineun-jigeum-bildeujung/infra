# DEV autoscaling 자동 복구 구성

기준일: 2026-09-30 KST
대상: EKS `petflow-eks` (`ap-northeast-2`)

## 관리 책임과 복구 순서

| 구성 | 선언 소유자 | `tapply.sh` 확인 |
|---|---|---|
| Metrics Server | Terraform `module.eks.aws_eks_addon.metrics_server` | Add-on ACTIVE, Deployment/APIService, 실제 node/pod metrics |
| KEDA | GitOps `platform/40-keda` | Application, 3 Deployments, CRD, external metrics API |
| 서비스 HPA/PDB/KEDA | `generic-service` chart + `gitops-value` | 4 HPA/PDB와 payment ScaledObject/생성 HPA |
| Karpenter | Terraform IAM/Pod Identity + GitOps CRD/controller/config | 3 Applications, CRD, controller, NodeClass/NodePool Ready |

실제 실행 경로 밖에 있던 루트 `addons.tf`와
`kubernetes/autoscaling/{pdb-hpa,keda-scaledobject,karpenter-nodepool}.yaml`은 제거했다.
해당 파일을 수동 `kubectl apply`하여 GitOps 객체를 중복 생성하지 않는다.

구현 전 확인한 저장소 HEAD는 다음과 같다.

- infra/dev: `bda9b295b86ccd693c1f3ff158e48f5d977df22a`
- gitops/main: `8b8c2e9b94b9bdc4518438a7b28e0ace227d01bb`
- gitops-value/main: `5e6d534bc6223a84a535bef839e422156881fa10`
- sever 작업 checkout: `00573270d66bb0614fb368ec4dd5e5c1c40b2eb3`

## HPA/PDB 인수

기존 수동 리소스와 같은 이름·target·정책을 선언한다.

| Namespace | mode | target | 범위 | 리소스 |
|---|---|---|---|---|
| auth-service | hpa | Rollout/generic-service | CPU 60%, 2–3 | auth-service-hpa, auth-service-pdb |
| member-service | hpa | Deployment/generic-service | CPU 60%, 2–3 | member-service-hpa, member-service-pdb |
| product-service | hpa | Deployment/generic-service | CPU 60%, 2–3 | product-service-hpa, product-service-pdb |
| review-service | hpa | Deployment/generic-service | CPU 60%, 2–3 | review-service-hpa, review-service-pdb |

scale-up은 60초마다 최대 1 Pod와 30초 안정화, scale-down은 60초마다 최대 1
Pod와 300초 안정화를 유지한다. PDB는 기존 selector와 `maxUnavailable: 1`을
유지한다. `hpa`/`keda` 모드에서는 workload의 `spec.replicas`를 렌더링하지 않는다.

ApplicationSet의 전역 replicas `ignoreDifferences`는 그대로 유지한다. 따라서
`disabled` 서비스도 values의 `replicaCount` 변경이 기존 live replicas를 즉시
덮어쓰지 않을 수 있다. 후속으로 서비스 메타데이터를 분리하기 전까지 고정 replica
변경은 sync 결과를 확인해야 하며, autoscaling을 끌 때는 `mode: disabled`, 원하는
replica 복원, ignore 정책 변경을 한 전환으로 검토한다.

## KEDA와 Kafka 계약

라이브 브로커에서 실제 연결이 확인된 대상만 활성화했다.

- 서비스: `payment-service`
- ScaledObject: `payment-service-scaler`
- target: `Rollout/generic-service`
- consumer group: `payment-service.refund-consumer`
- topic: `order.item-cancelled` (현재 1 partition)
- broker: `pet-subscription-kafka-kafka-bootstrap.kafka.svc:9093`
- 인증: TLS + SASL/SCRAM-SHA-512, `payment-service/kafka-credentials`
- 범위: min 1 / max 3, CPU 60% + Kafka lag, 초기 `lagThreshold: 10`

ExternalSecret은 Strimzi가 관리하는 KafkaUser Secret에서 `password`와 CA를 복사하고,
비밀값이 아닌 username을 template으로 합친다. TriggerAuthentication은
`username`, `password`, `ca.crt`만 참조한다. KEDA operator는 Kafka의 9093 listener에만
정확한 Namespace/Pod selector로 허용된다.

1 partition이므로 같은 consumer group의 Kafka 병렬 처리는 consumer 1개를 넘겨
증가하지 않는다. 추가 replica는 CPU/HTTP 용량에는 유효할 수 있다. lag 10은 보수적
초기값이며 처리시간과 허용 지연을 실측한 값은 아니다. Order/Product의 선언된 consumer
topic은 라이브 브로커에서 확인되지 않아 KEDA를 활성화하지 않았다.

## DB 연결 예산

PostgreSQL `max_connections=100`, 점검 시 활성 연결 22개였다. 서비스별 Hikari
`maximumPoolSize=3`, `minimumIdle=1`을 유지한다.

- HPA 4개: `4 × 3 pods × 3 = 36`
- payment KEDA: `3 × 3 = 9`
- order/notification 고정 1개씩: `2 × 1 × 3 = 6`
- 애플리케이션 정상 최대: 51 connections

Rollout/rolling update의 임시 추가 Pod와 운영/마이그레이션 연결을 별도로 남겨야 한다.
이 계산은 상한 검토이며 실제 동시 부하 시험 결과가 아니다. DB 상한 증가는 이번 범위에 없다.

## Karpenter

- chart/CRD: `1.13.0`
- controller ServiceAccount: `kube-system/karpenter` (EKS Pod Identity)
- controller 배치: MNG 라벨 `eks.amazonaws.com/nodegroup=petflow-node-group`
- EC2NodeClass: `default`, role `petflow-dev-karpenter-node`
- AMI: EKS 1.35 MNG에서 확인한 `ami-0aadb3cf154aff503` 고정
- NodePool: `on-demand`, `m7i-flex|m7i`, `large|xlarge`, amd64/Linux
- 한도: CPU 16, memory 64Gi
- disruption: 10분 뒤 보수적 consolidation, 동시 budget 1, 만료 720h
- 노드 라벨: `node-role=workload`, `capacity=on-demand`; taint 없음
- overprovisioning Deployment: GitOps가 `replicas: 0`으로 인수

Spot, interruption queue, EventBridge/SQS는 구성하지 않았다. 수요가 없을 때 NodeClaim과
추가 EC2가 0인 것이 정상이다. 공통 차트는 nodeSelector/affinity/tolerations/
topologySpreadConstraints를 Deployment와 Rollout 양쪽에 지원하지만, 기존 서비스를
Karpenter 노드로 일괄 이동하지 않았다.

중요: 현재 `tdestroy.sh`/`cleanup-k8s.sh`에는 Karpenter NodeClaim과 그 EC2를 명시적으로
정리하고 종료를 확인하는 단계가 없다. 실제 노드 생성 시험 또는 destroy 재구축 전에
Controller가 살아 있는 동안 NodePool/NodeClaim을 정상 삭제하고 EC2 종료를 확인하는
승인된 절차를 먼저 추가해야 한다. 이번 작업에서는 destroy를 실행하지 않았다.

## Guard와 운영 판정

`AUTOSCALING_READY_TIMEOUT_SECONDS`(기본 900)와
`AUTOSCALING_READY_POLL_INTERVAL_SECONDS`(기본 10)는 양의 정수만 허용한다. 실패 시
Application/Deployment/APIService/HPA/ScaledObject/Karpenter conditions, Pending Pod
events와 controller 로그의 짧은 tail을 출력하되 Secret 본문은 출력하지 않는다.

MNG 대기는 `eks.amazonaws.com/nodegroup` 라벨로 해당 그룹만 세고 `ready >= desired`를
사용한다. Karpenter 노드는 별도로 요약하므로 이미 추가 노드가 있는 재실행도 통과한다.
KEDA `Active=False`, HPA `ScalingLimited=True`, Karpenter 추가 노드 0개는 그 자체로
실패가 아니다.

## 롤백

- KEDA 문제: payment 값을 `mode: disabled`로 되돌리고 원하는 replicas를 복원한다.
  생성 HPA 제거와 workload replica 상태를 함께 확인한다.
- HPA 문제: 해당 서비스를 `disabled`로 전환하고 이전 replica를 명시한다. HPA와
  ScaledObject를 동시에 두지 않는다.
- Karpenter 문제: workload를 MNG에 안정적으로 배치한 뒤 NodeClaim이 없는 것을
  확인한다. NodeClaim이 남아 있으면 controller/CRD부터 삭제하지 않는다.
- Metrics Server/KEDA operator 복구를 위해 정상 Add-on/operator를 수동 삭제하지 않는다.

Helm/YAML/Terraform/Bash 정적 검증과 라이브 계약 조사는 수행했다. GitOps 배포,
KEDA 부하 확장, Karpenter EC2 생성, destroy → tapply 재구축은 별도 승인·후속 검증이다.
