# 셸 전환 테스트 리소스 정리

> 전체 셸 실험본의 과거 기록이다. 현재 `infra`는 혼합 구조를 사용하며 실행 경로는 `stateful-backup-restore.md`와 `stateful-shell-transfer-guide.md`를 따른다.

정리일: 2026-10-02 KST. 이번 작업의 scope는 `mig1001a`이다.

운영 AWS 계정 `297165773875`, 리전 `ap-northeast-2`, 기존 EKS `petflow-eks`에서 **이번에 생성한 리소스만** 대상으로 삼았다. 생성 기록의 Kubernetes UID, 테스트 namespace, EBS ID, IAM RoleId·태그로 소유권을 확인했다. 운영 리소스와 이전 테스트 리소스는 삭제하지 않았다.

## 삭제 항목

- namespace 4개: `shelltest-mig1001a-db`, `shelltest-mig1001a-redis`, `shelltest-mig1001a-kafka`, `shelltest-mig1001a-grafana`. 내부 Pod·서비스·PVC·Secret·테스트 operator 등도 함께 정리.
- 테스트 전용 ClusterRole 2개, ClusterRoleBinding 2개, PriorityClass 1개.
- 테스트 EBS 디스크 4개와 해당 PV:

  | 대상 | 디스크 ID |
  | --- | --- |
  | PostgreSQL | `vol-0d72fee4290ca9c73` |
  | Redis | `vol-0da81a13c09fb3579` |
  | Kafka | `vol-000a9f5f26b940dfd` |
  | Grafana | `vol-0a8976397553f0d2b` |

- 테스트 CNPG Pod Identity 연결: `a-algizkzzueg9d9kox`.
- 테스트 IAM 역할 `petflow-shelltest-mig1001a-cnpg`, `petflow-shelltest-mig1001a-runtime` 및 inline policy.
- S3 `cnpg/shell-tests/mig1001a/`의 파일 버전 12개. `recovery/shell-tests/mig1001a/`는 파일이 없었음. 두 경로 모두 버전·삭제 marker가 남지 않은 것을 확인.

Kafka의 수동 복원 디스크는 CSI 정리 후에도 남아 있어, 테스트 태그와 restore job 및 분리 상태를 확인해 해당 디스크 하나를 직접 삭제했다. 디스크와 VolumeAttachment가 없음을 확인한 뒤 테스트 PV에 남은 external-provisioner finalizer를 제거했다. 운영 CSI 설정이나 IAM 권한은 변경하지 않았다.

## 보존 잠금으로 남은 항목

AWS Backup 삭제 요청이 다음 이유로 거부됐다: `RecoveryPoint cannot be deleted or updated (Backup vault configured with Lock)`.

| 항목 | 값 |
| --- | --- |
| Backup vault | `petflow-dev-cnpg-ebs` — 기존 공용 vault, 삭제 대상 아님 |
| 테스트 recovery point | `arn:aws:ec2:ap-northeast-2::snapshot/snap-06f2e6732660c286a` |
| Backup job | `c0f59350-41f5-4179-ac3a-5ec31071b116` |
| 원본 리소스 | 이번에 생성했던 테스트 PostgreSQL 디스크 `vol-0d72fee4290ca9c73` |
| 보존 설정 | 7일 |
| API의 예정 삭제 시각 | **2026-10-08 23:54:24 KST** |
| 남긴 IAM 역할 | `petflow-shelltest-mig1001a-backup` |

잠금은 해제하지 않았다. AWS Backup은 원래 선택한 IAM 역할로 백업 수명 주기를 관리하므로, 백업이 삭제되기 전에 역할까지 제거하면 삭제가 실패할 수 있다. [AWS 공식 설명](https://docs.aws.amazon.com/aws-backup/latest/devguide/backup-iam.html).

따라서 이 테스트 백업 역할은 유지하되 inline policy `test-ebs`를 **snapshot 조회와 이 테스트 snapshot 한 개의 삭제 권한**으로 축소했다. 새 백업 생성, 디스크 복원·생성, 운영 디스크 snapshot 생성 권한은 제거했다. 실제 자동 삭제 완료까지 확인한 것은 아니므로, 예정 시각 이후 recovery point가 사라졌는지 확인해야 한다.

## 잠금 만료 후 남은 정리

2026-10-08 23:54:24 KST 이후 다음 recovery point를 조회한다. AWS가 자동 삭제했다면 `ResourceNotFoundException`이어야 한다. 권한 오류를 삭제 완료로 해석하지 않는다.

```bash
AWS_PROFILE=petflow-terraform-ujibil1 aws backup describe-recovery-point \
  --region ap-northeast-2 \
  --backup-vault-name petflow-dev-cnpg-ebs \
  --recovery-point-arn arn:aws:ec2:ap-northeast-2::snapshot/snap-06f2e6732660c286a
```

백업이 남아 있다면 동일한 vault와 recovery point를 지정해 `delete-recovery-point`를 요청하고, recovery point와 snapshot이 실제로 삭제됐는지 확인한다. **그 확인이 끝난 뒤에만** 다음 테스트 역할의 policy와 역할을 삭제한다.

```bash
AWS_PROFILE=petflow-terraform-ujibil1 aws iam delete-role-policy \
  --role-name petflow-shelltest-mig1001a-backup --policy-name test-ebs
AWS_PROFILE=petflow-terraform-ujibil1 aws iam delete-role \
  --role-name petflow-shelltest-mig1001a-backup
```

이 후속 작업은 아직 실행하지 않았다. 새로운 예약 작업·Lambda·클러스터를 만들지는 않았다. AWS Backup job·restore job 완료 기록은 삭제 가능한 실행 리소스가 아니며 기록으로 남는다.

정리 로그와 AWS 조회 증거는 Git 외부 `/tmp/stateful-shell-live-mig1001a/cleanup-*`에 보관했다. 구현 파일과 검증 문서는 `infra-stateful-shell`에 유지한다.
