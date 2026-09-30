# PostgreSQL · 장바구니 · Kafka 통합 백업/복원

## 범위와 현재 검증 상태

`sever`와 `web` 변경 없이 인프라 저장소에서 관리한다. CNPG 전체 데이터,
Redis database 0의 `cart:*`, 단일 Kafka 3.9.0/Strimzi 0.45.2 KRaft 데이터와
consumer offset을 같은 유지보수 구간에 보존한다. 로그인 세션/임시 락은 보존하지 않는다.

이 구현의 오프라인 테스트와 실제 AWS 복원 검증은 별개다. **2026-10-01 KST에 각 구성요소의
실제 격리 복원을 검증했다.** CNPG S3/WAL 및 EBS 복원본의 49개 테이블 행 수·내용 해시,
Redis cart 8개의 AOF·재시작 보존, Kafka 메시지·offset·identity·TLS/SCRAM 인증을 확인했다.
증거는 작업 공간 `backup-measurements/REPORT-20261001.md`와 해당 실행별 JSON에 보관한다.
다만 CNPG와 Redis/Kafka의 백업은 별도 실행으로, 같은 중단 구간의 통합 manifest 및
전체 destroy/apply 재생성 qualification은 아직 완료하지 않았다.
`tdestroy.sh`는 승인된 격리 검증 보고서가 없으면 서비스 중지 전에
실패한다. 예시 JSON의 false를 근거 없이 true로 바꾸지 않는다. JSON은 검증 결과를
전달하는 운영 기록이지, 스스로 검증을 수행하거나 진위를 증명하는 인증서가 아니다.

## 사전 요구사항

- 관리 호스트: Python 3.6 이상 + PyYAML, aws CLI, kubectl, helm, jq, Terraform.
- Terraform 실행 인증 계약은 기존 `scripts/lib/terraform-auth.sh`를 그대로 사용한다.
- 기존 `petflow-dev-db-backups`의 Versioning과 기존 AWS Backup Vault/Role을 재사용한다.
  새로운 Pod Identity나 백업 Job은 필요하지 않다. S3 작업은 관리 호스트의 실행 Role로
  수행하고 Kafka Secret도 비공개 버킷에서 암호화·버전 관리한다. Secret과 비밀번호를
  로그/명령 인자/Git에 출력하지 않는다. 로컬 journal은 0600/디렉터리 0700으로 관리한다.
- Kafka에는 CNPG 일일 백업 선택 태그를 붙이지 않는다. Kafka 백업은 정상 종료 뒤
  온디맨드 작업만 실행한다. 기존 CNPG Vault를 교체하거나 이름을 바꾸지 않는다.
- 백업 중 사람이 직접 DB/Redis/Kafka에 쓰지 않는다. PostgreSQL 직접 접속이 남으면
  중단한다. CNPG 내부 이름 `cnpg`, `cnpg-instance-manager`만 예외다. 인프라 레벨의
  유지보수는 외부 결제 시스템과의 원자성/애플리케이션 exactly-once를 보장하지 않는다.

## 격리 검증 먼저 수행

운영과 분리된 Kubernetes 환경에 같은 Kafka/Redis 버전, 인증, 스토리지 구성을 만든다.
테스트 메시지를 쓰고 일부만 소비해 offset을 커밋한다. 다음을 검증하고 로그와 원래/복원
cluster ID, node ID, 실제 메시지, offset, 인증 성공 결과를 보고서에 남긴다.

1. Kafka Operator/PodSet 자동 재생성을 중지하고 TERM 종료 로그를 확인한 뒤 EBS 백업.
2. 새 PV/PVC에 복원하고 Operator 시작 전에 Kafka/NodePool status의 clusterId/nodeIds,
   원래 CA와 KafkaUser Secret을 복구. `meta.properties` 삭제/재포맷 금지.
3. 원본 메시지와 소비 위치, SASL/SCRAM 인증 확인, 새 메시지 생산/소비 확인.
4. Redis에는 cart와 session/lock 테스트 키를 함께 만든 뒤 cart만 추출. 새 Redis에서
   cart만 복원되는지, 만료된 cart가 부활하지 않는지, AOF 및 재시작 후 보존 확인.
5. Redis/Kafka 복원 도중 중단 후 동일 run으로 재실행. 기존 사용자 데이터가 달라졌을 때
   덮어쓰기 대신 실패하는지 확인.

이후 `gitops/operations/data-protection/stateful-qualification.example.json`을 로컬
`.stateful-qualification.json`로 복사한다. 실제 증거 경로/시각/검증 결과를 기록하고 다음
명령 출력으로 `sourceHashes`를 채운다. 코드/구성이 변경되면 검증 기록이 무효화된다.

```bash
python3 scripts/stateful/control.py source-hashes
```

현재 도구의 기본 대상은 DEV다. 측정에서는 별도 namespace를 지정하고 같은 데이터 복원
함수로 시험했으며, 운영 `tdestroy.sh`는 실행하지 않았다. Kafka 복원 시 namespace에 맞춰
PV/PVC와 리소스 식별을 분리하고 기존 운영 디스크를 교체하지 않는다.

## destroy

```bash
export PETFLOW_STATEFUL_QUALIFICATION="$PWD/.stateful-qualification.json"
./tdestroy.sh
```

각 실행의 `runId`와 원래 controller/replica/HPA/KEDA/CronJob 설정을 먼저 기록한다.
Argo CD, Rollouts, KEDA, Jenkins를 중지하고 업무 파드를 정상 종료한다. 실행 중인 업무
Job은 강제 삭제하지 않고 사전 단계에서 중단한다. 직접 DB 연결을 해제한 뒤 재시도한다.

cart의 DUMP/절대 만료 시각은 TLS 검증이 켜진 임시 localhost 포트포워딩으로 추출한다.
바이너리는 Base64로 저장하며 SCAN 중복을 제거한다. cart가 0건이어도 완전한 파일을
저장한다. CNPG는 Barman backup ID와 named restore point가 들어 있는 정확한 WAL 객체
존재를 확인한다. Kafka는 정상 종료 로그 및 EBS detach 후 AWS Backup COMPLETED를 확인한다.

업무 테이블의 행 수/내용 fingerprint와 cart 내용이 백업 중 바뀌지 않았는지 재확인한다.
테이블 fingerprint는 테이블 전체를 읽고 정렬하므로 유지보수 시간이 늘어날 수 있다.
TTL에 의한 자연 만료는 cart 비교에서 제외한다.

모두 성공한 경우에만 `recovery/runs/<runId>/manifest.json`과 versioned
`recovery/latest-complete.json`을 게시한다. Redis/Kafka JSON의 VersionId와 SHA-256,
CNPG 지정 복원 지점, Kafka Recovery Point의 실행 태그와 남은 보존시간을 삭제 직전/후
다시 확인한다. 불완전한 S3 객체는 다음 실행에 섞지 않는다.

## 백업 실패 후 서비스 재개

실패 시 자동으로 서비스를 재개하지 않는다. `.destroy-evidence/`의 상태를 확인한다.
Kafka 중지 단계에 진입했다면 먼저 원래 Operator를 재개한다.

```bash
python3 scripts/stateful/control.py resume-kafka --journal .destroy-evidence/<runId>-kafka-journal.json
python3 scripts/stateful/control.py resume-maintenance --journal .destroy-evidence/<runId>-maintenance.json
```

Kafka가 Ready가 아니면 업무 서비스 재개를 차단한다. storage cleanup이 시작된 journal은
서비스 재개에 사용할 수 없다. 업무 서비스를 재개한 뒤에는 새로운 runId로 다시 백업한다.
실패했던 run의 파일을 합쳐 완전한 manifest를 만들지 않는다.

## apply / 재실행

`./tapply.sh`는 root-app 전에 `stateful-restore.sh`를 호출한다. 기존 세 저장소가 모두
Ready이면 데이터를 유지한다. 새 클러스터에는 통합 manifest 하나를 선택한다.
선택한 manifest는 복원 상태 ConfigMap에도 기록하므로 부분 복원 재실행 중 최신 포인터가
바뀌어도 처음 선택한 실행을 유지한다.
복원 코드/구성 hash가 다르면 자동 복원을 중단하고 기록된 버전을 사용한다.

CNPG는 지정 base backup/named restore point까지 복원한 뒤 업무 테이블 fingerprint를
비교한다. Redis는 빈 인스턴스에만 cart를 복원하고 `WAITAOF`와 내용 검증을 수행한다.
부분 복원은 같은 run의 journal이 있으며 이미 복원된 key가 원본과 같은 경우에만
없는 key를 추가한다. 예상하지 않은 session/key 또는 변경된 cart가 있으면 실패한다.

Kafka는 새 EBS 복원 Job ID를 먼저 journal에 기록한다. 새 PV/PVC를 정확히 pre-bind한 뒤
정지된 Operator 아래에서 cluster/node identity와 인증정보를 복원한다. Ready, identity,
partition end offset, committed offset이 일치해야 성공한다. 실제 메시지/인증 재검증은
격리 qualification의 필수 항목이다. 메시지 보존기간 및 compaction 정책에 의해 기동 후
오래된 메시지가 정리될 수 있으므로 offset 숫자만으로 메시지 전량 보존을 주장하지 않는다.

`.restore-evidence/<runId>/`와 `database/stateful-recovery`에 완료 상태를 남긴 뒤
GitOps를 시작한다. `task bootstrap:root-app`도 ready 검사를 수행한다. 이 검사는 운영
실수 방지 장치이며 관리자 직접 `kubectl apply`를 권한 수준에서 차단하는 기능은 아니다.

통합 manifest가 없으면 자동 빈 초기화를 하지 않는다. 완전히 첫 설치이고 어떤 이전
백업 객체도 없을 때만 `PETFLOW_STATEFUL_INITIALIZE=true ./tapply.sh`를 사용한다.
기존 CNPG 단독 백업만 있는 환경은 자동으로 빈 Kafka/cart를 섞어 복원하지 않는다.

## 검증과 보고서

```bash
python3 -m unittest discover -s tests -p 'test_stateful_backup_restore.py' -v
python3 -m unittest discover -s tests -p 'test_cnpg_restore.py' -v
```

오프라인 테스트 결과, 실제 격리 복원 결과, 운영 백업 결과를 각각 기록한다. 이 코드만으로
RPO=0, 외부 결제 중복 없음, 실제 RTO 측정 완료라고 쓰지 않는다. `sever`, `web`,
`gitops-value`의 평상시 replica/HPA/이미지 설정은 이 구현 범위에 포함하지 않는다.
