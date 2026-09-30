# HPA·KEDA·Karpenter 검증 결과 — 2026-09-30

## 결과

제한된 DEV 검증은 애플리케이션 오류, 데이터베이스 압력, 재시작, 업무 Kafka
데이터 변경 없이 완료됐다. KEDA 소비자는 1 → 3 → 1 전체 확장·축소 주기를
완료했다. Karpenter는 On-Demand 노드 한 대를 추가했으며, 테스트 정리 후 Jenkins
작업이 해당 노드를 사용해 유지됐다. Product HPA는 관측 CPU가 목표 60%보다 낮아
확장되지 않았다.

Terraform apply/destroy, 실제 업무 트랜잭션, Spot 노드, 반복 작업, 운영 임계값
변경 및 강제 노드 삭제는 수행하지 않았다.

## 환경 및 기준선

- 실행 시간: 2026-09-30 14:25–15:14 KST(05:25–06:14 UTC)
- Kubernetes 컨텍스트: `petflow-dev`
- AWS 계정/리전: `297165773875`, `ap-northeast-2`
- 기준선 관측 시간: 5분
- 서비스 Pod: 30/30 Ready, 재시작 0, Pending 0
- Product HPA: replica 2/3, CPU 목표 60%, 초기 CPU 2–5%
- 데이터베이스: 연결 5/100, 연결 오류 없음
- Product p95: 약 12.5ms, 5xx 0
- Karpenter: 테스트 전 Ready 상태의 `m7i-flex.large` NodeClaim 1개
- 업무 Kafka 그룹 `payment-service.refund-consumer`: 토픽
  `order.item-cancelled`, 테스트 전후 log-end 0

## 외부 공개 읽기 전용 HTTP 테스트

클러스터 외부에서 다음 공개 GET 경로에만 트래픽을 전송했다.

- 30% `GET /api/v1/time-deals?status=ACTIVE`
- 70% `GET /api/v1/time-deals/items/{7..12}`

실행기는 동시성을 20으로 제한하고 요청 제한 시간을 5초로 설정했으며 재시도하지
않았다. 오류 3건, 반복된 인증 오류·NotFound, 반복 누락 또는 p95 1초 이상이면
중단하도록 구성했다. 전체 활성 부하 시간은 11분이었다.

| 요청률 | 실행 시간 | 요청 수 | 실패 | p95 | 최대 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 RPS | 2분 | 120 | 0 | 35.69ms | 114.16ms |
| 5 RPS | 3분 | 900 | 0 | 28.76ms | 84.34ms |
| 10 RPS | 3분 | 1,800 | 0 | 27.90ms | 83.07ms |
| 20 RPS | 3분 | 3,600 | 0 | 34.01ms | 258.64ms |

전체 6,420건이 HTTP 200으로 성공했다. timeout, 반복 누락, 401/403/404/429,
5xx 응답은 없었다. Product CPU 관측 최댓값은 52%, replica는 2개, 데이터베이스
연결은 5개, Pod 재시작은 0으로 유지됐다. 이 결과는 제한된 부하에서의 안정성을
확인하지만 CPU 60% 조건에 도달하지 않았으므로 Product HPA 확장을 검증한 것은
아니다.

`docs/evidence/autoscaling-validation-20260930/`의 k6 요약 JSON 파일 4개가
원본 증적이다.

## 전용 Kafka/KEDA 테스트

사용한 격리 리소스는 다음과 같다.

- Namespace: `autoscaling-validation`
- Topic: `autoscaling-validation-20260930`, partition 3개, RF 1
- Group: `autoscaling-validation-consumer-20260930`
- SCRAM 사용자: `autoscaling-validation-20260930`
- ScaledObject: Kafka 전용, min 1, max 3, lag 임계값 10
- Producer: 512바이트 레코드 정확히 300건, 초당 10건
- Consumer: Pod당 초당 약 1건 처리 후 commit

관측 순서는 다음과 같다.

1. Consumer 1개가 lag 0 상태로 연결됐다.
2. Producer가 초당 10.017건으로 300건 생성을 완료했다.
3. 전체 lag가 약 278까지 증가하고 ScaledObject가 Active 상태가 됐다.
4. KEDA/HPA가 Deployment를 1 → 2 → 3 replica로 확장했다.
5. Consumer 재시작 없이 lag가 137을 거쳐 0으로 감소했다.
6. ScaledObject가 비활성 상태로 돌아가고 replica가 3 → 2 → 1로 축소됐다.

첫 Producer 시도에서는 생성한 클라이언트 설정에 `bootstrap.servers`가 빠져
레코드를 한 건도 생성하지 못했다. Job은 실패 상태로 종료됐고 삭제한 뒤
매니페스트를 수정했다. 실제 데이터는 성공한 300건 실행에서만 생성됐다. 이전
Pod affinity 시도도 브로커 노드의 Pod 수 한도 때문에 Pending 상태에 머물렀으며
데이터를 만들지 않고 제거했다.

DEV Kafka는 broker authorization이 비활성 상태이며(`authorization` 없음,
user operator의 ACL 관리 지원 false), 이 테스트는 전용 SCRAM 인증 사용자를
사용했지만 공유 Kafka 설정을 변경하지 않고 broker ACL로 최소 권한을 강제할
수는 없었다. 임시 추가형 NetworkPolicy는 테스트 namespace만 TLS listener에
접근하도록 허용했으며 broker를 재기동하지 않았다.

## Karpenter 및 NAT 관측

- 테스트 전 NodeClaim: 1개
- 테스트 중 최대 및 종료 시점 NodeClaim: 2개
- 신규 NodeClaim: `on-demand-smzqj`, On-Demand `m7i-flex.large`
- 생성 시각: 06:00:39 UTC, Ready 시각: 06:01:06 UTC
- 테스트 신규 노드 한도: 준수(1개 추가)
- Spot 사용 및 강제 노드 삭제: 없음

테스트 리소스를 제거한 뒤 Jenkins 작업 2개가 신규 노드에서 실행되고 있었다.
따라서 Karpenter가 노드를 유지하는 것이 정상이며 강제로 축소하지 않았다. 노드
생성은 검증했지만 모든 작업이 빠진 뒤의 consolidation은 이번 실행에서 관측하지
못했다.

신규 노드에는 Strimzi 이미지가 캐시되어 있지 않았다. Kubernetes 이벤트에는
Consumer와 Producer가 각각 375,539,008바이트 이미지를 동시에 받은 것으로
기록됐다. 따라서 이 테스트로 발생할 수 있는 외부 이미지 전송량 상한은 약
751MB이며 실제 registry layer 중복 제거에 따라 더 작을 수 있다. 공개 HTTP
테스트 수신량은 약 11.69MB, 송신량은 약 0.43MB였다. 두 수치는 2TB와 큰 차이가
있지만 NAT Gateway 전송량을 검토할 때 이미지 다운로드는 고려해야 한다.

## 정리 및 재실행

정리 과정에서 테스트 namespace, topic, KafkaUser, 복제한 자격증명, ScaledObject와
HPA, Producer와 Consumer, 임시 Kafka NetworkPolicy를 제거했다. 이후 모든 서비스
Deployment와 StatefulSet이 Ready였고 데이터베이스 연결은 5/100, 업무 Kafka
offset과 log-end는 변경되지 않았다.

최종 Argo CD 점검에서 `platform-root`는 Healthy이지만 자식 `alloy` Application
객체 하나 때문에 OutOfSync였다. 자동 동기화 결과는 성공이었고 `alloy` 자체는
Synced/Healthy였으며 테스트 리소스는 남아 있지 않았다. 이 반복적인 Application
객체 drift는 별도 GitOps 후속 과제이며 이번 검증에서 자동 수정하지 않았다.

저장소 루트에서 HTTP 단계를 재실행한다.

```bash
scripts/autoscaling-validation/run-http.sh
```

전용 Kafka/KEDA 테스트를 실행하고 출력되는 관측 명령을 확인한다.

```bash
# 아래는 재실행 예시이며 PR 검토 수정 과정에서는 실행하지 않았다.
EXPECTED_CONTEXT=petflow-dev scripts/autoscaling-validation/run-kafka.sh
EXPECTED_CONTEXT=petflow-dev scripts/autoscaling-validation/cleanup.sh
```

Kafka 실행기는 격리 리소스를 생성한 뒤 관측 및 정리 명령을 출력한다. 확장,
backlog 소진 또는 축소 성공을 자동 판정하지 않으며 자동으로 정리하지도 않는다.
실행 중에는 데이터베이스 연결, 업무 Kafka lag, Pod 가용성·재시작, NodeClaim을
별도로 관측하고 원래 지시서의 중단 조건을 적용해야 한다.

정리 스크립트는 검증한 컨텍스트를 모든 작업에 고정하고 Namespace, Kafka
NetworkPolicy, KafkaTopic, KafkaUser의 소유권을 먼저 검사한다.
`app.kubernetes.io/part-of=autoscaling-validation` 라벨이 있는 리소스만 삭제한다.
NotFound는 안전한 no-op으로 처리하지만 컨텍스트, 권한, 연결, JSON, 소유권,
삭제 또는 timeout 오류는 0이 아닌 종료 코드로 중단한다.

HTTP 단계를 다시 실행하기 전에 기본 타임딜 상세 항목 ID `7..12`가 여전히
유효한지 확인한다. 필요하면 다음처럼 덮어쓴다.

```bash
DETAIL_IDS=21,22,23 scripts/autoscaling-validation/run-http.sh
```

재실행 중에는 항상 테스트 지시서의 중단 조건을 유지한다.
