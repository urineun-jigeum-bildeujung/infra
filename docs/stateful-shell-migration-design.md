# Stateful 운영 스크립트의 Bash 전환 설계

> 전체 셸 실험본의 과거 기록이다. 현재 `infra`는 혼합 구조를 사용하며 실행 경로는 `stateful-backup-restore.md`와 `stateful-shell-transfer-guide.md`를 따른다.

작성일: 2026-10-01. 상태: **설계만 작성, 구현·테스트·AWS 적용 미실행**.

- 작업 브랜치: `refactor/stateful-shell`
- 작업 디렉터리: `/home/user1/tonghap/infra-stateful-shell`
- 기준 커밋: `da29958c540ec671093d54e7616f92d3aa49bf80`
- 원래 `/home/user1/tonghap/infra` 작업 디렉터리의 `dev` 브랜치와 기존 변경은 그대로 둔다.
- Astra는 이 문서까지 작성한다. 구현 및 시험은 후속 Sol 작업에서 수행한다. 이 문서는 시험 통과나 운영 적용 승인을 의미하지 않는다.

## 1. 결정한 범위

`scripts/` 최상위의 Python 2개와 `scripts/stateful/`의 Python 7개를 Bash로 전환한다. 기존 명령 진입점, 백업 데이터, 중단 순서, 실패 시 차단, 재실행 의미를 보존한다. `.sh`에서 Python을 호출하거나 Python 코드를 내장하는 방식은 전환으로 인정하지 않는다.

시험은 **기존 AWS/EKS 안에 별도의 DB·Redis·Kafka 복제본을 만드는 방식**으로 설계한다. 새 VPC와 새 EKS를 만들지 않는다. 복제본에서 직접 AWS 백업·복원 동작을 검증하므로, 로컬 환경 → 새 EKS → 운영 환경의 세 차례 실환경 시험을 요구하지 않는다. 문자열·해시·실패 분기 자동 검사는 같은 작업의 빠른 보조 검사다.

기존 운영 데이터와 워크로드를 변경하지 않는 것이 목표다. 다만 같은 EKS의 노드, API 서버, 일부 Operator, AWS 한도를 공유하므로 **성능 영향까지 포함한 절대적인 무영향은 보장할 수 없다.** 여유 자원 확인, 자원 제한, 순차 시험, 중단 기준으로 공유 자원 영향을 관리한다. 운영 워크로드를 멈춰 시험 용량을 확보하는 것은 금지한다.

이번 작업에서 `tdestroy.sh`, `tapply.sh`, `cleanup-k8s.sh` 전체를 실제 EKS에 실행하지 않는다. 이 진입점의 연결은 명령 대체 테스트로 확인하고, 실제 시험에서는 테스트 대상의 stateful 작업만 호출한다. EKS 자체의 destroy/apply까지 검증했다고 보고하지 않는다.

## 2. 지난 시험에서 확인한 사실

근거: 기존 `docs/backup-restore-measurement-20261001.md` 및 작업 공간의 `backup-measurements/measure_cnpg.py`, `measure_cnpg_ebs.py`, `measure_redis_kafka.py`.

| 지난 시험 | 실제 구성 | 이번 설계에서 재사용할 점 |
|---|---|---|
| CNPG S3/WAL 복원 | 같은 EKS, **기존 `database` namespace**, 새 `Cluster/petflow-db-restore`, 1 instance, 새 20Gi `gp3-cnpg` 저장소 | 같은 이미지·확장으로 별도 Cluster를 생성하고 지정 base backup/restore point로 복원 |
| CNPG EBS 복원 | `cnpg-ebs-final-restore-test` namespace, 새 EBS/PV/PVC, 단독 PostgreSQL Pod | 원래 디스크를 연결하지 않고 AWS Restore Job이 생성한 새 디스크만 사용 |
| Redis 복원 | `redis-restore-test` namespace, 별도 StatefulSet/PVC | cart 내용·절대 만료시각·AOF·재시작 보존 검증 |
| Kafka 복원 | `kafka-restore-test` namespace, 별도 Operator/PV/PVC/EBS | cluster ID, node ID, 메시지, offset, TLS/SCRAM 복원 검증 |

과거 시험 전체가 운영에 무영향했던 것은 아니다. CNPG 시험은 원본 DB에서 백업·내용 조회를 했고, Redis/Kafka 시험은 `maintenance.quiesce()`와 원본 Kafka 종료를 실행했다. **과거 측정 스크립트를 그대로 재실행하지 않는다.**

이번에는 이미 존재하는 백업만 읽어 초기 복제본을 만든다. 이후 새 백업, 쓰기 중지, 종료, 장애 주입, 삭제, 재복원은 전부 테스트 복제본에 수행한다. 기존 Recovery Point가 만료됐거나 필요한 WAL이 없다면 운영 백업을 새로 만들지 말고 그 사실을 보고한다. 테스트 데이터로 초기화한 별도 DB로 대체한 경우에는 실제 기존 백업 호환성 시험과 구분한다.

## 3. 파일 변경 지도

| 현재 파일 | 전환 파일 | 책임과 보존할 동작 |
|---|---|---|
| `scripts/reconcile-grafana-admin.py` | `scripts/reconcile-grafana-admin.sh` | Secret 읽기, port-forward, `/api/user` 확인, 401 + `admin`일 때만 stdin으로 비밀번호 동기화, 최대 15회 인증 재확인, 자식 프로세스 정리 |
| `scripts/release-kafka-topic-finalizers.py` | `scripts/release-kafka-topic-finalizers.sh` | manifest 및 maintenance journal 검증, Operator/브로커/볼륨 정지 확인, **전체 토픽 사전 검증 후** 해당 finalizer만 제거, 증거 저장 |
| `scripts/stateful/common.py` | `scripts/stateful/common.sh` | CLI 호출, JSON 파일, 대상 설정, 시간/체크섬, S3 버전 고정, polling, 원자적 저장, 오류 처리 |
| `scripts/stateful/cnpg.py` | `scripts/stateful/cnpg.sh` | primary 탐색, `psql` stdin SQL, 업무 테이블 fingerprint, 연결 차단 확인, 지정 base/WAL 확인 |
| `scripts/stateful/maintenance.py` | `scripts/stateful/maintenance.sh` | 원래 상태를 먼저 저장, 컨트롤러·HPA·KEDA·CronJob·서비스 중단, 순서에 맞춘 복구 |
| `scripts/stateful/kafka.py` | `scripts/stateful/kafka.sh` | 토폴로지/identity/offset 수집, 정상 종료 로그 수집, detach 대기, AWS Backup, 원래 브로커 재개 |
| `scripts/stateful/bootstrap.py` | `scripts/stateful/bootstrap.sh` | GitOps YAML 읽기, Helm 렌더링, Redis 준비, Kafka 디스크·identity·인증 복원, 진행 journal |
| `scripts/stateful/redis_cart.py` | `scripts/stateful/redis-cart.sh` | cart 전용 바이너리 백업·복원, 만료시각, 부분 재실행, 덮어쓰기 차단, 동일 연결의 AOF 확인 |
| `scripts/stateful/control.py` | `scripts/stateful/control.sh` | 기존 7개 서브명령과 통합 백업/복원 상태 관리 |

추가로 필요한 작은 지원 파일:

- `scripts/stateful/json.jq`: 구조 비교와 기존 JSON fingerprint 직렬화. 여러 파일에 긴 jq 식을 중복하지 않는다.
- `scripts/stateful/legacy-sources.json`: 검증된 Python 소스 해시와 대응 셸 구현의 호환성 기록. 구현·시험 후 실제 해시로 작성한다.
- `scripts/stateful/targets/dev.json`: 기존 운영 대상의 기본값. 테스트 대상은 이 파일을 수정하지 않고 별도 파일로 전달한다.
- Redis 서버에 보내는 Lua는 `redis-cart.sh` 내부의 정적 heredoc으로 관리한다. Redis에 이미 쓰는 EVAL을 이용하는 것으로, 별도 Lua 런타임을 설치하지 않는다.

운영 구현은 Bash, `jq`, AWS CLI, `kubectl`, Helm, Terraform, `curl`, GNU coreutils, OpenSSL을 사용한다. YAML 처리는 **Mike Farah yq v4**로 고정하고 Python 기반 동명 yq를 허용하지 않는다. Redis 연결에는 `redis-cli`와 아래 TLS 설계의 `stunnel`을 사용한다. 신규 의존성을 숨기지 말고 사전 검사와 문서에 명시한다. 시험용 Python은 `tests/`에 남길 수 있으며 운영 런타임 제거와 구분한다.

## 4. 공통 Bash 규칙과 함수 계약

진입점은 `set -Eeuo pipefail`, `umask 077`을 사용한다. 라이브러리를 source하는 것만으로 AWS/Kubernetes 명령, trap 등록, 임시 디렉터리 생성이 일어나지 않게 한다. 함수 이름은 `sf_`, `cnpg_`, `kafka_`, `redis_`, `maintenance_` 접두사로 구분한다.

JSON과 자격증명은 파일 또는 stdin으로 전달한다. 셸 변수는 경로, 이름, 숫자 등 작은 값에 사용한다. 전체 Secret/백업 JSON을 `--argjson` 등 프로세스 인자로 전달하지 않는다. `jq --slurpfile`, `--rawfile`과 stdin을 사용한다. JSON 값을 `eval`, 문자열로 만든 셸 명령에 삽입하지 않는다.

권장 계약:

| 함수 | 계약 |
|---|---|
| `sf_get KIND NAME NAMESPACE SELECTOR OUTPUT` | 정상 부재는 JSON `null`, 목록은 `items` 객체로 저장. 권한·통신·JSON 파싱 실패는 오류. namespace/CRD 부재와 조회 오류를 구분 |
| `sf_apply INPUT` | 대상 범위 검사 후 JSON/YAML 파일을 apply. 로그는 stderr, stdout에 업무 데이터 혼합 금지 |
| `sf_save_json DEST INPUT` | 같은 디렉터리의 0600 임시 파일에 검증된 JSON 기록 → 디스크 동기화 → atomic rename. journal 저장 실패 시 다음 변경 실행 금지 |
| `sf_upload KEY INPUT REF_OUTPUT` | 정확한 업로드 bytes로 MD5/SHA-256 계산, VersionId 필수, 해당 버전을 다시 읽어 검증 |
| `sf_download REF OUTPUT` | 허용 bucket/prefix/version 확인, **원본 bytes의 SHA-256을 먼저 확인**, 그 뒤 JSON 파싱 |
| `sf_poll TIMEOUT CALLBACK ...` | callback 결과를 ready/pending/fatal로 명시적으로 구분. pending만 재시도, fatal을 timeout까지 반복하지 않음 |
| `sf_cleanup` | 이번 프로세스가 만든 port-forward/TLS bridge/임시 파일만 정리. 오류 코드 보존. 업무 서비스를 자동 재개하지 않음 |

GNU `sync`의 파일/파일시스템 동기화 기능을 사용해 기존 journal의 fsync 의도를 유지하고, 필요한 옵션 지원 여부를 preflight에서 확인한다. 단순 `echo > journal`로 대체하지 않는다.

`set -e`에만 실패 전파를 맡기지 않는다. 특히 조건문에서 호출한 함수, `local x=$(...)`, process substitution 안의 실패, 파이프 뒤 while의 subshell 상태 손실을 주의한다. 중요한 CLI/파일 저장은 명시적으로 반환값을 확인한다. JSON 목록은 검증된 임시 파일에 먼저 생성한 뒤 순회한다.

`jq`의 `//`는 false도 대체한다. 0/false/null/누락을 구별하는 필드에는 `has()`와 타입 검사를 사용한다. 날짜는 UTC 기준으로 처리하며 AWS 숫자 timestamp와 ISO 8601 timezone offset을 모두 지원한다. timeout은 경과시간 기준으로 계산하고 모든 대기에 상한을 둔다.

## 5. 대상 설정: 기존 이름과 테스트 이름을 분리

공통 진입점에 `--target-file PATH`를 추가한다. 생략 시 운영 기본값은 기존과 동일하게 유지하되, **시험 실행기는 target-file을 반드시 지정**한다. sandbox 파일의 필드가 빠졌을 때 운영 기본값으로 보충하지 않는다.

설정에는 다음을 명시한다.

- mode(`dev`/`sandbox`), 고유 scope ID, AWS account/region, EKS 이름, kubeconfig/context.
- 각 CNPG/Redis/Kafka/Grafana의 namespace, 리소스 이름, Service, Secret, TLS 서버 이름.
- 중단 가능한 workload/controller의 namespace·kind·name 목록. 운영의 `SERVICES`/`CONTROLLERS` 상수를 sandbox에서 사용하지 않는다.
- S3 bucket, 통합 recovery prefix, CNPG 쓰기 prefix, latest key, 테스트 Backup Vault/Role, 증거 디렉터리.
- 기존 백업의 **원본 identity/serverName**와 **복원 목적지 identity**. 둘을 같은 변수로 취급하지 않는다.
- sandbox의 클러스터 공용 선행 리소스는 `use-existing`으로 고정. 새 설치/upgrade는 허용하지 않는다.

새 manifest에는 실행 scope 정보를 추가하고 검증한다. 기존 scope 없는 manifest는 기존 DEV 의미로만 해석한다. sandbox의 정상 `control restore`가 DEV manifest를 그대로 소비하는 것을 막는다. 처음 운영 백업을 테스트 환경에 가져오는 작업은 별도 시험 준비 단계로 수행하고, 원본 manifest/체크섬을 수정하지 않는다. 이후 왕복 시험은 테스트 scope에서 새로 만든 manifest를 사용한다.

S3 latest 경로는 scope에 귀속한다. sandbox에서 `recovery/latest-complete.json`이나 `cnpg/recovery/latest.json`을 갱신하는 경로가 남아 있으면 구현 완료로 보지 않는다.

## 6. 파일별 핵심 구현

### Grafana

`curl` config 파일(0600) 또는 보호된 입력을 사용하고 비밀번호를 `curl -u`의 argv에 넣지 않는다. curl 실행 실패와 HTTP 401을 구분한다. 200이면 reset을 실행하지 않고, 401 + 기본 admin일 때만 기존 비밀번호를 `grafana cli ... --password-from-stdin`에 전달한다. 다른 사용자나 5xx는 실패한다. 2초 간격 최대 15회 검증을 보존한다.

port-forward는 localhost 임시 포트를 사용하고 시작 실패·준비 timeout·정리 실패를 처리한다. 테스트는 별도 Grafana StatefulSet/PVC/Secret에서 정상 로그인, Secret/DB 불일치, 잘못된 사용자, API 실패를 검증한다.

이전 세션의 읽기 전용 조회에서는 실제 Pod가 `grafana-admin-credentials`를 참조했고, 기준 Python은 `kube-prometheus-stack-grafana`를 고정 사용했다. 이는 언어 전환 전부터 존재한 차이다. Secret 이름을 target-file로 지정할 수 있게 하되 실제 DEV 설정을 변경할 때는 별도 변경 이유를 기록한다. 시험을 위해 실제 Grafana 비밀번호를 reset하지 않는다.

### CNPG

기존 7개 업무 DB에 최신 `infra`의 `repurchase_db` 추가를 반영해 8개 DB를 비교 대상으로 사용한다. 행 수/내용 SQL을 보존한다. SQL identifier는 PostgreSQL 규칙으로 quote하고 SQL은 stdin으로 보낸다. 테이블 이름을 셸 word splitting으로 순회하지 않는다. 표준 행 fingerprint와 기존 연결 차단 조건을 바꾸지 않는다.

기존 `cnpg-s3-backup.sh`, `backup-cnpg-before-destroy.sh`, `restore-cnpg-before-gitops.sh`도 호출 대상 분리에 필요한 최소 변경 대상이다. namespace/Cluster/ObjectStore/bucket/prefix/marker를 공통 설정에서 받는다. 고정 Barman serverName은 원본 복원 명세에서 검증하며 목적지 이름으로 무조건 치환하지 않는다.

특히 `restore-cnpg-before-gitops.sh`는 현재 cert-manager/CNPG/plugin Helm upgrade와 공용 StorageClass apply를 수행한다. sandbox에서는 이 준비 단계를 **기존 리소스의 읽기 전용 준비 확인**으로 분리한다. 공용 Operator/CRD/StorageClass를 테스트 코드가 재설치하지 않게 한다.

### Maintenance

기존 순서: 상태 전체 저장 → Argo/KEDA/Jenkins 등 중단 → KEDA pause/HPA 제거/CronJob suspend → gateway부터 업무 replica 감소 → 업무 Pod 종료 확인 → Rollouts controller 중단. 원래 상태 저장 전 변경하지 않는다.

재개 시 Kafka Ready를 먼저 확인하고, HPA의 KEDA owner UID 재구성, pause annotation 제거, 컨트롤러 역순 복구를 보존한다. journal이 `deleting`/`deleted`면 resume를 거절한다.

sandbox에서는 테스트 workload와 테스트 제어기만 이 목록에 넣는다. 공유 Argo CD/KEDA/Jenkins/Rollouts를 멈추지 않는다. 공유 제어기 중단의 세부 명령 순서는 기존 테스트에 대응하는 명령 대체 검사로 확인하고 실제 중단까지 시험했다고 보고하지 않는다.

### Kafka 및 bootstrap

Kafka 3.9.0/Strimzi 0.45.2, 단일 dual-role KRaft, EBS 1개 제한을 유지한다. cluster ID/node ID/CA/사용자·토픽/offset 수집을 보존한다. 로그 stream 연결을 확인한 뒤 broker를 종료하고, 현재 코드의 LogManager/Broker/Raft/controller/socket 종료 문구가 모두 있어야 백업을 허용한다. EBS `available` + attachment 없음 확인을 유지한다.

AWS Backup의 idempotency token, 보존기간, run 태그, 실패 상태 검증을 그대로 옮긴다. 복원은 job ID를 먼저 journal에 기록하고, 새 volume의 크기·암호화·KMS·AZ를 검증한 뒤 PV/PVC를 bind한다. identity·Secret·볼륨 준비가 끝나기 전 broker를 시작하지 않는다. `starting` 재시도에서 디스크를 다시 복원하거나 교체하지 않는다.

`bootstrap.desired_matches()`는 원하는 dict key의 재귀 부분 비교를 허용하지만 list의 길이와 순서는 엄격하게 비교한다. 이를 단순 JSON 전체 equality나 배열 포함 검사로 바꾸지 않는다. Bitnami는 기존처럼 고정 OCI chart를 사용하고, Strimzi HTTP chart 및 GitOps values를 보존한다.

### Topic finalizer

전체 토픽에 대해 백업 포함 여부·deletionTimestamp·클러스터 label을 검증한 후 patch를 시작한다. 하나라도 실패하면 patch 0회여야 한다. 제거 대상은 `strimzi.io/topic-operator`뿐이다. 나머지 finalizer는 유지한다. broker 존재, Operator 동작, disk attachment, 다른 cluster ID는 모두 차단 사유다.

## 7. Redis: 바이너리와 연결을 보존하는 설계

이 파일은 단순 `redis-cli --scan | while read`로 바꾸지 않는다. key와 DUMP는 NUL/non-UTF8/CRLF를 포함할 수 있으며 Bash 변수에 원본 bytes를 저장하면 안 된다.

1. `redis-cli`를 한 작업 동안 유지하는 **지속 연결**로 실행한다. Bash coprocess 또는 전용 FIFO로 요청/응답을 순차 처리한다. 각 응답은 timeout과 JSON 타입을 확인한다. 실제 CLI 버전의 비대화형 출력/flush/에러 종료 동작은 Sol이 가장 먼저 확인할 구현 검증 항목이다.
2. 정적 Lua에서 SCAN 결과 key를 Base64로 인코딩한다. 한 key의 `DUMP`·`PEXPIRETIME`·`TYPE`은 기존처럼 같은 EVAL에서 읽고, key/dump를 Base64 문자열로 반환한다. SCAN은 페이지 단위, 중복 제거와 `(db, base64-key)` 정렬은 클라이언트에서 수행한다. 전체 DB를 한 Lua 호출로 오래 점유하지 않는다.
3. 복원 입력도 Base64/ASCII 형식으로 stdin 연결에 보내고 Lua에서 bytes로 복원한다. 허용 key prefix는 **디코딩한 `cart:`**로 검사한다. base64 문법/중복/db/count/fingerprint/만료 필드를 전체 검증한 뒤 첫 쓰기를 수행한다. payload를 프로세스 argv에 노출하지 않는다.
4. `RESTORE`는 REPLACE 없이 수행하고, 절대 만료시각은 ABSTTL로 유지한다. 정상 복원은 빈 DB만 허용한다. 부분 복원은 같은 run의 journal + 이미 존재하는 모든 cart의 내용/TTL 일치 + non-cart 0개를 확인한 뒤 없는 key만 추가한다.
5. 복원 쓰기와 `WAITAOF 1 0 30000`은 **같은 연결**에서 실행하고 첫 반환값 1을 확인한다. 명령마다 새 redis-cli를 실행하는 방식은 금지한다. Redis의 WAITAOF는 해당 연결의 앞선 쓰기를 기준으로 하므로 다른 연결에서 호출하면 검증 의미가 달라진다. [공식 WAITAOF 문서](https://redis.io/docs/latest/commands/waitaof/)
6. 연결 ID를 시작과 중요 단계에서 확인한다. CLI 자동 재연결로 쓰기 연결이 바뀌었다면 성공 처리하지 않는다. WAITAOF를 Lua/MULTI 안으로 옮기지 않는다. 재시도 정책은 상위 journal이 담당한다.
7. Redis TIME으로 만료된 key를 양쪽에서 제외한 뒤 내용 fingerprint와 DBSIZE를 확인한다. 원래 코드의 버전 일치 조건을 유지한다.

TLS 경로는 `redis-cli → localhost stunnel → localhost kubectl port-forward → Redis TLS`로 설계한다. stunnel은 `verifyChain=yes`, 테스트/운영에 맞는 CAfile, `checkHost=<대상 Redis DNS>`, `sni=<같은 DNS>`를 설정한다. CA 검증과 서버 이름 검증을 모두 수행한다. SNI만 설정하는 것을 hostname 검증으로 간주하지 않는다. [stunnel 인증 문서](https://www.stunnel.org/auth.html)

stunnel은 이번 작업 전용 프로세스로 띄우고 loopback에만 bind하며 충돌 시 중단한다. Redis 비밀번호는 보호된 stdin으로 AUTH하고 로그/argv에 출력하지 않는다. quoted input의 escaping과 NUL 처리도 시험한다. Redis history 저장을 비활성화하고 민감한 CLI stderr는 그대로 출력하지 않는다. 모든 연결 프로세스는 종료 시 함께 정리한다.

## 8. 기존 백업 호환성

### 데이터 bytes와 JSON fingerprint를 구분

S3 참조의 `sha256`은 저장된 **파일 bytes** 기준이다. 다운로드 후 jq로 재출력한 파일을 해싱하면 기존 백업을 오판하므로 먼저 원본 bytes를 검증한다. 새 업로드도 업로드한 정확한 bytes와 기록한 hash가 일치해야 한다.

Redis fingerprint와 복원 ConfigMap의 `manifestHash`는 기존 `json.dumps(..., sort_keys=True)` 직렬화 결과 기준이다. `jq -S -c`는 공백·문자 escaping 등이 달라 그대로 대체할 수 없다.

`json.jq`에 기존 형식 전용 serializer를 둔다. 객체 key 정렬, 배열 순서, `, ` 및 `: ` 구분자, ASCII escape/Unicode surrogate pair, 줄바꿈 없음, null/boolean/정수 표현을 정의한다. 지원 manifest/cart 스키마의 숫자는 손실 없이 처리하며 범위 밖 정수나 지원하지 않는 숫자 형식은 조용히 반올림하지 않고 거절한다. Python 기준 구현과 특수문자·Unicode·빈 배열·TTL 정수 fixture를 byte-for-byte 비교한 뒤 사용한다. 임의 JSON 전체에 대해 Python 직렬화와 같다고 주장하지 않는다.

### 실행 소스 hash

기존 manifest는 7개 `.py` 경로와 GitOps/기존 `.sh` 해시를 기록한다. 파일명만 `.sh`로 바꾸거나 hash 검사를 제거하면 안 된다.

- 새 백업은 셸 구현, jq/Lua 등 동작을 바꾸는 지원 파일, 대상 설정, 호환성 표 및 기존 GitOps 소스의 hash를 기록한다.
- 기존 백업은 `legacy-sources.json`의 **명시적으로 검증한 기존 코드 조합**만 허용한다. 현재 Python의 알려진 예외도 근거 있는 조합으로만 이어받는다. 임의 hash 또는 일부 파일만 맞는 조합은 거절한다.
- 호환성 기록은 기존 코드 hash뿐 아니라 시험한 새 구현의 파일 hash에도 묶는다. 호환성 파일 자신은 이 내부 새 구현 hash 집합에서 제외해 자기참조를 피하고, 새 백업의 전체 sourceHashes에는 포함한다.
- 변경하지 않은 GitOps/기존 셸 파일은 기존처럼 정확히 일치해야 한다. 이번에 target 분리를 위해 바뀐 셸 파일도 명시적 호환성 매핑 대상에 포함한다.
- 기존 selectedManifest/manifestHash/runId/journal을 이어서 복원하는 경우도 검증한다. 지원하지 않는 과거 revision은 이유를 밝히고 거절하며, 강제 우회 플래그로 통과시키지 않는다.

기존 백업 JSON을 수정하거나 해시를 새 값으로 덮어쓰는 마이그레이션은 하지 않는다. 실제 해시 목록과 지원 범위 확정은 Sol의 테스트 결과에 근거한다.

## 9. 동일 EKS 내 실제 테스트 구성

### 리소스 배치

예시 namespace는 `shelltest-<run>-db`, `shelltest-<run>-redis`, `shelltest-<run>-kafka`, `shelltest-<run>-grafana`, `shelltest-<run>-workloads`다. 이번에는 RBAC 경계를 명확히 하기 위해 CNPG도 별도 namespace에 배치한다. 이것은 새 EKS를 만드는 작업이 아니다.

| 구성요소 | 생성/사용할 것 | 변경하지 않을 것 |
|---|---|---|
| CNPG | 같은 이미지·pg_bigm, 1 instance, 새 PVC/EBS, 테스트 ObjectStore/ServiceAccount | 원래 `database/petflow-db`, 운영 Service/Secret/ObjectStore, 공용 Operator 배포 |
| Redis | 같은 버전, 별도 StatefulSet/PVC, 테스트 인증·해당 DNS의 TLS 인증서 | 운영 cart/session/lock, 운영 StatefulSet/인증 설정 |
| Kafka | 같은 버전, 테스트 namespace만 감시하는 별도 Strimzi, 새 EBS/PV/PVC, 복원된 identity | 운영 broker/Operator/토픽/consumer offset |
| Grafana | 같은 이미지, 독립 PVC/Secret, 외부 Ingress 없는 인스턴스 | 실제 관리자/security-audit 계정과 세션 |
| 업무 제어 | 테스트 writer/Deployment/StatefulSet/CronJob 및 필요한 시험용 제어 대상 | 운영 gateway·서비스·Argo CD·KEDA·Jenkins·Rollouts의 replica와 설정 |

기존 GitOps 소스의 이미지를 고정해 사용하되 root Application은 배포하지 않는다. 공유 CRD/StorageClass/CA issuer는 필요한 범위에서 재사용하며 수정하지 않는다. live 객체 전체를 무심코 복사하지 말고 UID/resourceVersion/status/ownerReference/할당 IP/운영 volumeName 등 서버 소유 필드를 제거한 명세로 생성한다.

운영 Kafka Operator의 실제 watch 범위를 사전 확인한다. 저장소 설정상 설치 namespace만 감시하도록 되어 있지만 live 상태가 다르면 확인 없이 진행하지 않는다. 테스트 Operator의 watch namespace 및 RBAC를 테스트 범위에 한정하고 CRD 재설치를 막는다.

### 백업 읽기와 쓰기 분리

- 복제 원본은 고정한 CNPG base/WAL, Redis JSON VersionId, Kafka Recovery Point다. 실행 중 latest 포인터를 다시 따라가지 않는다.
- 최초 복제는 원본 백업 읽기만 허용한다. 원래 디스크를 detach하거나 새 snapshot을 위해 원본 서비스를 정지하지 않는다.
- 테스트 CNPG의 WAL/백업은 `cnpg/shell-tests/<scope>/...`, 통합 백업은 `recovery/shell-tests/<scope>/...`처럼 별도 prefix에 기록한다.
- 테스트 Backup Job/Restore Job/새 EBS는 scope 태그와 생성 증거를 기록한다. 운영 볼륨 ARN을 테스트 backup/delete 대상으로 허용하지 않는다.
- 기존 CNPG Pod Identity Role은 `cnpg/*`에 넓은 쓰기 권한을 갖고 있으므로 그대로 복제하지 않는다. 테스트 ServiceAccount에는 원본 읽기 + 테스트 prefix 쓰기만 가능한 전용 Role/association을 사용한다. shared Role의 정책은 수정하지 않는다.
- AWS Backup의 서비스 Role, `iam:PassRole`, 복원 결과 볼륨 조작은 테스트 Role과 생성된 리소스 범위로 제한한다. API별 지원 condition을 확인해 정책을 작성하고, 지원하지 않는 tag 조건만 믿고 광범위한 권한을 부여하지 않는다.

### 변경 권한과 네트워크

시험 실행기는 운영 관리자 kubeconfig를 그대로 사용하지 않고 테스트 namespace에 한정한 자격증명을 쓴다. 운영 namespace에 patch/delete/scale/exec를 할 수 없어야 한다. 최초 namespace/RBAC/Pod Identity/PV 등 준비는 별도 준비 단계로 분리하고, 생성한 리소스 목록을 저장한다. cluster-scoped PV/RBAC 변경을 namespace 권한으로 격리했다고 주장하지 않는다.

PV는 새 Restore Job 결과의 volume ID를 확인한 뒤 준비 단계에서 생성한다. 기존 PV를 수정하거나 운영 PVC를 지정할 수 없게 한다. 정리는 기록한 이름·UID·volume ID·scope tag를 확인한 대상만 수행한다. 광범위한 selector나 namespace 이름 추정만으로 삭제하지 않는다.

테스트 namespace는 ingress/egress 기본 차단 후 DNS, 필요한 Operator/webhook, S3/인증 경로, 테스트 내부 통신만 허용한다. 실제 CNI의 NetworkPolicy 집행을 확인한다. S3/Pod Identity에 필요한 통신과 정책 방식은 준비 시 네트워크 구성에 맞춰 확정한다. 테스트 Pod에서 운영 DB/Kafka/Redis 및 외부 업무 API로 접속할 수 없는지 Sol이 확인한다. 복제 데이터에 포함된 DB subscription, 외부 연결 설정, 예약 작업도 기동 전에 점검하고 외부 실행을 차단한다.

노드 여유 CPU/메모리/디스크 attach 한도를 확인하고 requests/limits, ResourceQuota, 낮은 우선순위 및 preemption 금지를 사용한다. 운영 Pod를 밀어내거나 노드 설정을 바꾸지 않는다. 자원이 부족하면 시험 범위를 순차로 줄이거나 중단한다. 실제 사용량·운영 Ready 상태가 악화되면 테스트만 정지한다. 테스트용 EBS/백업 저장 비용은 발생하며, 새 EKS/VPC 비용은 발생시키지 않는다.

## 10. Sol에게 넘길 검증 범위

실환경의 기본 순서는 **기존 백업 → 테스트 복제본 A → A에서 새 백업 → 테스트 데이터 리소스만 삭제 → 테스트 복원본 B → 내용 비교**다. A/B는 동시에 두 벌을 계속 유지할 필요가 없다. 초기 복제본을 만들 때의 원본과, 왕복 시험에서 사용하는 원본 A를 혼동하지 않는다. 모든 중단·장애 주입은 A/B에서만 한다.

| 검증 항목 | 확인할 결과 |
|---|---|
| CNPG | 지정 base/restore point로 복원, DB/테이블 행 수·내용 hash 일치, 기존 정상 DB 재실행 시 재초기화 안 함 |
| Redis | NUL/non-UTF8/CRLF 포함 key/value, 빈 cart, 중복 SCAN, 만료 경계, non-cart 제외, 변경된 부분 복원 거절, 동일 연결 WAITAOF, AOF 재시작 보존 |
| Redis TLS | 올바른 CA/서버 이름 성공, 다른 CA와 같은 CA의 잘못된 서버 이름 모두 실패 |
| Kafka | 정상 종료 확인, 새 EBS 복원, identity·메시지·end/committed offset 일치, TLS/SCRAM, 기동 중 재시도에서 디스크 재복원 없음 |
| Grafana | 정상 인증 시 reset 0회, 401 admin만 reset, 오류/다른 사용자 차단, 재시도, 로그/argv 자격증명 비노출 |
| finalizer | 검증 실패 시 patch 0회, 다른 finalizer 보존, 실제 테스트 KafkaTopic으로 성공/거절 확인 |
| 통합 상태 | 같은 run만 복원, 실패 시 latest/ready 게시 금지, 빈 초기화 조건, Redis 시작 journal 선기록, 삭제 시작 후 resume 차단 |
| 호환성 | 기존 Python 생성 JSON/fingerprint/manifest/journal을 새 셸이 정확히 판독, 알 수 없는 코드 hash 거절 |
| 범위 이탈 | sandbox 대상 누락·운영 namespace·운영 marker·원본 volume 지정 시 첫 변경 전에 거절 |

`tests/test_stateful_backup_restore.py`, `test_grafana_admin_recovery.py`, `test_kafka_topic_cleanup.py`는 Python 모듈 직접 import 대신 새 셸의 입력/출력·명령 기록·journal을 검사하도록 전환한다. `test_cnpg_restore.py`는 기존 CLI 대체 방식에 sandbox 대상/공용 설치 차단 사례를 추가한다. 기준 Python은 기준 커밋에서 읽어 시험용 사본으로만 사용하고, CLI는 반드시 대체하거나 테스트 자격증명으로 제한한다. 일반 운영 자격증명으로 옛 Python을 비교 실행하지 않는다.

단위 검사, 실제 복제본에서 확인한 항목, 공유 제어기 때문에 대체 검사만 한 항목, EKS 전체 재생성처럼 미검증인 항목을 결과에 구분한다. 기존 시험 통과 기록을 새 셸 시험 결과로 재사용하지 않는다.

## 11. 호출부 변경 및 구현 순서

호출부 변경 목록:

- `stateful-backup.sh`, `stateful-restore.sh`: `exec bash .../stateful/control.sh`.
- `scripts/destroy-infra.sh`: 삭제 전/후 verify 호출을 새 control로 연결.
- `cleanup-k8s.sh`: finalizer, begin-cleanup, verify 호출을 셸로 연결.
- `tapply.sh`: Grafana 복구 호출을 셸로 연결.
- `tdestroy.sh`: 운영 Python 요구 제거, 실제 필요한 신규 CLI 검사 추가. 쓰기 중지 이후에 의존성 누락을 발견하지 않도록 한다.
- `docs/stateful-backup-restore.md`: 새 명령·의존성·호환성·검증 한계 갱신.
- 직접/간접 `.py` 참조, shebang 실행, CI 검사와 테스트 import를 다시 검색해 누락 제거.

구현 순서는 공통 함수·대상 설정·JSON 호환성 → Redis 지속 연결 검증 → CNPG/maintenance/Kafka/bootstrap → control/Grafana/finalizer → 호출부·문서·테스트 순서다. 이는 같은 브랜치에서의 작업 순서이며 운영에 파일별로 교체하는 배포 순서가 아니다.

9개 Python 파일은 대응 셸과 검증이 준비된 뒤 삭제한다. 최종 브랜치에 Python 운영 fallback을 남기지 않는다. 구현 중에는 원본 비교를 위해 기준 커밋을 사용한다. 변경과 테스트 결과를 한 묶음으로 검토할 수 있게 하며 자동 merge/운영 배포는 하지 않는다.

## 12. 구현 착수 전 확인과 완료 기준

Sol이 확인할 사항은 현재 테스트 namespace/PV 이름 충돌, 기존 백업의 존재·버전·유효기간, 노드 여유, Operator watch 범위, NetworkPolicy 집행, 테스트 IAM/RBAC의 실제 경계, 지원 CLI 버전이다. 이 설계 작성 중에는 live 상태를 새로 조회하거나 리소스를 생성하지 않았다.

완료 기준은 9개 파일의 운영 Python 의존성 제거, 호출부 연결, 기존 안전 조건 보존, 백업 호환성 검증, 테스트 복제본 왕복 복원 결과, 실패/재실행 결과, 생성 리소스 정리 증거다. 공유 환경에서 시험할 수 없는 동작은 명시적으로 미검증으로 남긴다. **스크립트가 작성됐다는 사실만으로 실제 AWS 동작 동일성을 확정하지 않는다.**
