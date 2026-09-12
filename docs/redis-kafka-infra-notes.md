# Redis / Kafka Infra 선행 작업

기준일: 2026-09-12

Redis와 Kafka는 EKS 내부 Kubernetes Workload이며 Manifest와 Helm 설정은 `gitops`
저장소에서 관리한다. Infra 저장소는 VPC/EKS/Node/EBS CSI/gp3/Tailscale 기반과 DEV
전체 삭제 시 동적 Storage 정리를 담당한다.

## Terraform에 추가하지 않는 항목

- Redis/Kafka Terraform Module
- Redis/Kafka IAM Role
- 6379/9092 외부 Security Group
- 전용 Subnet 또는 EC2
- ElastiCache 또는 Amazon MSK

Redis `6379`와 Kafka `9092`는 EKS Cluster 내부 Service Port다. Backend Pod는
Cluster DNS로 접근하며 외부에 개방하지 않는다.

## GitOps 계약

| 항목 | Redis | Kafka |
|---|---|---|
| Namespace | `redis` | `kafka` |
| Endpoint | `redis-master.redis.svc.cluster.local:6379` | `pet-subscription-kafka-kafka-bootstrap.kafka.svc:9092` |
| Architecture | standalone, AOF | Kafka 3.9.0, Strimzi 0.45.2, 단일 KRaft |
| Request | 100m / 256Mi | Broker 250m / 512Mi, Operator 250m / 512Mi |
| Limit | 500m / 512Mi | Broker 1CPU / 1Gi, Operator 1CPU / 1Gi |
| Storage | gp3 8Gi PVC | gp3 10Gi PVC, `deleteClaim: false` |

Topic 이름, Producer/Consumer, Event Payload, Consumer Group, Retry/DLQ와 Redis
Key/TTL/Lock/Queue 정책은 Backend/CloudNative 범위다.

## PV / EBS 생명주기

```text
GitOps Workload
  → PVC
  → gp3 StorageClass
  → EBS CSI Driver
  → PV
  → AWS EBS Volume
```

EBS CSI가 만든 Volume은 Terraform State에 들어가지 않는다. `alldestroy.sh`는 반드시
`cleanup-k8s.sh`를 먼저 실행하고, Cleanup 성공 후에만 Terraform Destroy를 실행한다.

`cleanup-k8s.sh`의 Storage 정리 순서:

1. Account `297165773875`, Cluster `petflow-eks`, Region `ap-northeast-2` 확인
2. Argo CD Application Controller 중지
3. Redis/Kafka PVC에서 PV 이름과 CSI `volumeHandle` 추적
4. KafkaTopic/Kafka/KafkaNodePool과 Redis/Kafka Workload 정리
5. Redis/Kafka PVC 삭제
6. 추적한 PV 삭제 확인
7. 추적한 EBS Volume이 `InvalidVolume.NotFound`인지 확인

Namespace/PVC가 없으면 성공 처리하므로 반복 실행할 수 있다. PV/EBS가 제한 시간 내
사라지지 않거나 조회가 실패하면 Cleanup이 실패하며 Terraform Destroy도 시작하지 않는다.

## 고아 EBS 판별 원칙

모든 `available` EBS를 삭제 대상으로 간주하지 않는다. 삭제 전 실제 PVC에서 이어지는
`PVC namespace/name → PV name → spec.csi.volumeHandle` 관계를 기본 근거로 사용한다.
보조 근거로 다음 AWS Tag를 확인한다.

- `kubernetes.io/created-for/pvc/namespace`
- `kubernetes.io/created-for/pvc/name`
- `kubernetes.io/created-for/pv/name`
- `CSIVolumeName`
- `ebs.csi.aws.com/cluster`

`Delete` reclaim policy에서는 PVC 삭제와 EBS CSI 정상 삭제를 기다린다. `Retain` 또는
Finalizer/Attachment 문제로 남은 EBS는 자동 강제 삭제하지 않는다. Volume ID, Tag,
Attachment와 PV/PVC 관계를 다시 확인한 후 별도 승인으로 수동 처리한다.

## GitOps 병합 후 확인

```bash
kubectl --context petflow-dev get pods,svc,pvc -n redis
kubectl --context petflow-dev get pods,svc,pvc -n kafka
kubectl --context petflow-dev get kafka,kafkanodepool,kafkatopic -n kafka
kubectl --context petflow-dev get storageclass,pv
```

Redis는 Pod `Running`, PVC `Bound`, ClusterIP 6379와 `PONG`을 확인한다. Kafka는
Operator/Broker `Running`, Kafka/KafkaNodePool/KafkaTopic `Ready`, PVC `Bound`,
Bootstrap Service 9092를 확인한다. 자세한 명령은 [Operations](operations.md)를 따른다.
