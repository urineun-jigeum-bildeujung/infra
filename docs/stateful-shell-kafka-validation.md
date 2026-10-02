# Kafka 셸 복원 검증

> 전체 셸 실험본의 과거 기록이다. 현재 `infra`는 혼합 구조를 사용하며 실행 경로는 `stateful-backup-restore.md`와 `stateful-shell-transfer-guide.md`를 따른다.

검증일: 2026-10-02 KST. 브랜치: `refactor/stateful-shell`.

기존 EKS의 `shelltest-mig1001a-kafka` namespace에서 기존 백업을 새 EBS 디스크로 복원했다. 운영 Kafka namespace와 디스크는 변경하지 않았다.

## 결과

- Kafka 3.9.0 / Strimzi 0.45.2: Ready, broker Running.
- 기존 백업과 클러스터 ID 일치: `SugAZQBRT-mK0CDTF0A6GQ`.
- 기존 백업과 노드 ID 일치: `[0]`.
- 전체 partition end offset과 consumer group committed offset 일치.
- 같은 복원 journal로 재실행하여 기존 restore job과 디스크를 재사용하고 검증 완료.
- offset 파싱 중 발견한 jq 구문 오류 수정. 빈 group 및 실제 committed offset을 확인하는 회귀 테스트 통과. 관련 셸 정적 검사에서 경고·오류 없음.

사용자가 정상 기동·ID·offset 일치를 이번 Kafka 복원 검증의 통과 기준으로 지정했다. 이 기준으로 **통과** 처리한다.

이미 실행 중이던 별도 확인도 완료됐다: 복원된 SCRAM 계정으로 TLS hostname 검증을 사용하는 접속, 시험 메시지 3개 송수신, 기존 `payment.failed` 메시지 12개 읽기. 이 확인은 새 백업에서 재복원한 데이터 비교를 의미하지 않는다.

추가 Kafka 백업 생성 및 새 백업 → 재복원 시험, 전체 destroy/apply 시험은 실행하지 않았다. 이번 결과를 해당 절차 전체의 통과로 해석하지 않는다.

증거는 Git 외부의 `/tmp/stateful-shell-live-mig1001a`에 보관한다: `kafka-seed-verified.json`, `kafka-seed-progress.json`, `kafka-before-check.json`. 백업 원본과 계정 비밀정보는 문서에 포함하지 않는다. 이후 사용자 요청으로 테스트 리소스를 정리했다. 삭제 항목과 보존 잠금으로 남은 백업은 [정리 문서](stateful-shell-test-cleanup.md)에 기록했다.
