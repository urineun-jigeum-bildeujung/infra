# 백업·복원 시간 및 데이터 검증 보고서

측정일: 2026-10-01 KST. AWS 프로필: `petflow-terraform-ujibil1`.
운영 인프라를 destroy/apply하지 않고 운영 백업 및 별도 테스트 리소스 복원으로 측정했다.
Redis·Kafka 백업 동안 업무 서비스를 중지했고, 백업 완료 후 운영 서비스·컨트롤러를 재개했다.

## 보고서 표에 사용할 소요 시간

| 측정 항목 | 시작 기준 | 완료 기준 | 결과 |
|---|---|---|---|
| destroy 전 S3 백업 | CNPG Backup 요청 | base backup·지정 WAL 확인 및 로컬 복원 명세 기록 | 약 25.5초 |
| destroy 전 EBS 백업 | 첫 AWS Backup Job 요청 | 모든 Recovery Point 검증 완료 | 약 2분 16.2초 |
| apply 시 CNPG 복원 | 테스트 복원 Cluster 생성 | DB Ready 및 접속·조회 성공 | 약 1분 51.9초 |
| apply의 DB 전체 준비 | 테스트 복원 단계 진입 | 새 세대 백업·WAL 검증 완료 | 약 2분 22.6초 |
| EBS 스냅샷 복원 시험 | AWS Restore Job 요청 | 복원 PostgreSQL Ready 및 조회 성공 | **약 1분 42.2초 (102.246초)** |

S3 시험에서 운영 최신 marker는 갱신하지 않고 로컬 고정 복원 명세를 기록했다.
앞의 네 행은 실제 destroy/apply 전체 실행 시간이 아닌 해당 단계의 분리 시험값이다.
EBS 마지막 행은 새 볼륨을 사용하는 격리된 단일 PostgreSQL 파드의 값이며,
CNPG HA 클러스터 재구성까지 포함한 복구 시간으로 해석하지 않는다.
데이터 양, 리소스 배치, 네트워크, 볼륨 초기화 상태에 따라 소요 시간은 달라질 수 있다.

## PostgreSQL 검증

- 원본 DB 크기 합계 약 344.12MiB. 운영 디스크는 20Gi × 2개.
- S3 base backup·WAL 복원: 9개 DB, 49개 public 테이블의 행 수 및 전체 행 내용 MD5가 원본과 일치.
- EBS 스냅샷 복원: `petflow-db-2` 볼륨의 기존 Recovery Point에서 새 20Gi 볼륨을 복원.
- EBS 복원본 역시 동일한 9개 DB, 49개 테이블의 행 수·내용 해시 일치. 불일치 0개.
- 첫 SQL 조회: `pg_is_in_recovery=false`, 주문 44,544건.
- EBS 테스트는 원래 PostgreSQL 17 이미지·확장으로 기동. initdb/pg_resetwal/디스크 재포맷을 하지 않음.
- 테스트 PostgreSQL은 별도 네임스페이스에서 외부 ingress/egress를 차단하고 파드 내부 SQL로 검증.
- 운영 볼륨을 교체하지 않았고 운영 DB Ready 인스턴스 2개를 확인.

EBS 최종 시험 요청: **2026-10-01 01:42:01.699 KST**
EBS 최종 첫 조회 완료: **2026-10-01 01:43:43.945 KST**
EBS 데이터 비교 완료: **2026-10-01 01:45:02.587 KST**
Restore Job: `a6a2ff4b-cb24-4394-8fcd-c46130c4f4e2`. Recovery Point: `arn:aws:ec2:ap-northeast-2::snapshot/snap-0a49bdd6cc4dc7b04`.

## Redis 장바구니

| 단계 | 소요 시간 |
|---|---|
| 장바구니 추출 | 4.170초 |
| 테스트 Redis 구성 | 67.817초 |
| 장바구니 복원·AOF fsync·내용 검증 | 6.831초 |

- Redis 7.4.3 database 0의 `cart:*` 8개를 S3에 백업하고 같은 버전의 새 인스턴스에 복원.
- DUMP 내용 및 절대 만료정보 일치, 복원 후 AOF fsync 확인.
- 같은 백업으로 부분 재실행 성공, 같은 PVC에서 파드를 재시작한 뒤에도 8개 장바구니 유지.
- 테스트 Redis에는 cart 키 8개만 존재. 로그인 세션·임시 락은 복원하지 않음.
- 추출 시간은 S3 업로드·객체 readback을 제외한다. 테스트 인스턴스 구성은 복원 시간과 별도.

## Kafka

| 단계 | 소요 시간 |
|---|---|
| 정상 종료·볼륨 detach·AWS Backup 완료 | 118.601초 |
| 격리 Operator 구성·EBS 복원·기동·identity/offset 검증 | 302.332초 |
| TLS·SCRAM 인증 및 새 메시지 생산·소비 검증 | 26.185초 |

- Strimzi 0.45.2 / Kafka 3.9.0 단일 dual-role KRaft 구성.
- 종료 로그에서 LogManager, BrokerServer, controller Raft driver 및 최종 server 종료를 확인한 뒤 detached 볼륨 백업.
- 새 네임스페이스·PV/PVC·EBS에서 cluster ID `SugAZQBRT-mK0CDTF0A6GQ`, node ID 0 유지.
- 일반 토픽 26개 파티션의 메시지 해시 일치: `payment.failed` 기존 메시지 12건 + 검증 메시지 9건.
- 전체 파티션 end offset 및 consumer group committed offset 일치.
- 검증용 group의 소비 위치 1도 유지. 같은 복원 실행 재시도 성공.
- 복원한 CA·SCRAM 계정으로 TLS hostname 검증 및 새 메시지 생산·소비 성공.
- 원래 Kafka를 먼저 재개한 뒤 테스트 복원을 진행. 운영 사이트 HTTP 200 및 업무 Deployment/Rollout Ready 확인.

CNPG 시험과 Redis·Kafka 시험은 서로 다른 실행이다. 세 데이터를 동일한 쓰기 중단 구간에서
묶는 전체 통합 manifest 및 destroy/apply 재생성 시험을 완료했다고 주장하지 않는다.
외부 결제 원자성, RPO=0, 전체 인프라 RTO도 이번 시험만으로 보장하지 않는다.

## 실패했던 시도와 보완

- Kafka 두 초기 시도는 현재 KRaft 버전이 출력하지 않는 legacy 종료 문구를 검사해 중단.
  운영 Kafka와 업무 서비스를 재개하고 새 실행 ID로 다시 백업. 최종 백업에 초기 시도 결과를 섞지 않음.
- Rollouts 종료 순서, KEDA HPA 소유 관계 복원, 로그 stream 준비 및 원래 PodSet/PVC를 쓰는 Kafka 재개 절차 보완.
- Kafka 복원 데이터·offset 검증 후 CA 마운트 이름 가정이 잘못된 인증 시험을 수정하고 같은 테스트 복원본에서 인증 검증 완료.
- PostgreSQL 첫 EBS 볼륨은 standby.signal 존재를 확인해 주 DB 기동을 중단.
  주 볼륨 시험에서는 fsGroup에 의한 데이터 디렉터리 권한 변경을 발견해 테스트 파드 설정을 수정.
  마지막 신규 Restore Job의 성공 시간을 표에 사용. 실패 시도 시간은 최종 값에 포함하지 않음.
- 인프라 코드 오프라인 테스트 33개 통과. 운영 백업 실패 차단 및 실제 전체 자동 복원은 별도 qualification 대상.

## 정리 및 증거

테스트 CNPG 클러스터·Redis·Kafka와 EBS 시험 네임스페이스를 모두 삭제했다. 테스트 EBS 볼륨 6개도 실제 삭제를 확인했다. 운영 DB 인스턴스 2개 및 Kafka Ready, 사이트 HTTP 200을 확인했다.
백업 S3 객체와 AWS Recovery Point, 로컬 증거는 보존한다.
삭제 완료 시각(UTC): 2026-09-30T17:01:42.752728+00:00. 최종 삭제·운영 상태 확인은 `cleanup-20261001.json`을 기준으로 한다.

- `20260930T153107Z/result.json`: CNPG S3/WAL 백업·복원 및 EBS 백업 측정.
- `measure-20260930T162516Z/result.json`: Redis·Kafka 검증 완료.
- `measure-20260930T162516Z/source-message-hashes.json`, `restored-message-hashes.json`: 실제 메시지 비교.
- `ebs-20260930T164157Z/result.json`, `aws-restore-job.json`, `restored-data.json`: EBS 최종 복원 검증.
- `cleanup-20261001.json`: 삭제한 테스트 볼륨 및 보호한 운영 볼륨 기록.

Secret 포함 JSON과 cart 백업은 소유자 전용 권한으로 보관하며 Git에 추가하지 않는다.
