# infra의 혼합 실행 구조

2026-10-02 전체 셸 변환본을 이관한 뒤, 추가 CLI 설치를 줄이기 위해 Python과 셸을 함께 사용하는 구조로 변경했다. 현재 `infra`에 전체 셸 파일 21개를 다시 덮어쓰지 않는다. 전체 셸 실험본은 `../infra-stateful-shell`에 그대로 보관한다.

| 역할 | 현재 구현 |
| --- | --- |
| 인프라 apply/destroy, 단계 연결 | 기존 셸 |
| CNPG S3/EBS 백업·복원 및 backup guard | 기존 셸 |
| Grafana 관리자 인증 확인·복구 | 독립 `scripts/reconcile-grafana-admin.sh` |
| Redis TLS/RESP 통신과 cart 백업·복원 | `scripts/stateful/redis_cart.py` |
| YAML/JSON 처리, fingerprint, 통합 백업·복원 및 journal | 기존 `scripts/stateful/*.py` |
| KafkaTopic finalizer 정리 | `scripts/release-kafka-topic-finalizers.py`, 같은 Python 백업 검증 재사용 |

Grafana 셸은 기존 curl·jq·kubectl·GNU coreutils만 사용하며 다른 stateful 셸 모듈을 읽지 않는다. 현재 GitOps에 맞춰 `grafana-admin-credentials`를 기본 Secret으로 사용한다.

`repurchase_db`를 Python DB 비교 목록에 유지했고 `repurchase` namespace도 백업 전 업무 중지 목록에 추가했다. `tapply.sh`와 `tdestroy.sh`는 Python/PyYAML을 시작 전에 확인한다. yq·redis-cli·stunnel을 자동 설치하거나 요구하지 않는다.

전체 셸 실행 경로와 의존 테스트는 `infra`에서 제거했고, Python 구현의 테스트를 복구했다. Grafana 셸 테스트와 그 로컬 실행 도우미는 유지한다.

2026-10-02 운영 복원에서 PostgreSQL·Redis cart 8개·Kafka identity/offset 검증,
Trivy 기존 디스크 재사용과 스캔을 확인했다. 초기 GitOps 실패는 수동 재동기화로
복구했고, 이를 제한적으로 자동 복구하는 코드를 추가했다. 2026-10-03 사용자가
다시 실행한 destroy는 오류 없이 완료됐다. 새 apply 방지 코드의 전체 재생성
실행은 아직 하지 않았으며, 셸 문법 및 제한된 오프라인 테스트로 확인한다.

기존 `docs/stateful-shell-migration-design.md`, Kafka 검증 및 정리 문서는 전체 셸 실험 당시 기록이다. 현재 운영 경로는 `docs/stateful-backup-restore.md`를 기준으로 한다.

로컬 복구 사본:

- 전체 셸 적용 전: `/tmp/infra-before-stateful-shell-20261002-211020/`
- 혼합 구조 적용 전: `/tmp/infra-before-hybrid-20261002-211851/`

이 사본은 임시 로컬 보관이며 Git에 포함하지 않는다.
