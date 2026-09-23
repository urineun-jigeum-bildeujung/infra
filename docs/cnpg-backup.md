# CNPG S3 백업 기반

Terraform 관리 범위는 db-backups 버킷, PostgreSQL Pod의 IAM Role과 EKS Pod Identity Association이다.
CNPG Operator, Barman Cloud Plugin, ScheduledBackup과 서비스별 Database는 GitOps에서 관리한다.
Cluster와 ObjectStore는 `tapply.sh`가 복원 지점에 따라 생성한다.

## EKS 전체 재생성

`tdestroy.sh`는 Kubernetes/EBS를 삭제하기 전에 CNPG on-demand base backup을 완료하고,
백업 시작 이후 생성된 WAL이 S3에 올라왔는지 확인한다. 성공한 복원 지점은
`s3://petflow-dev-db-backups/cnpg/recovery/latest.json`에 기록한다. 이후 기존 EBS
Recovery Point도 별도로 만든다. 어느 백업 단계든 실패하면 삭제를 중단한다.

`tapply.sh`는 GitOps 서비스 Application보다 먼저 CNPG를 준비한다. marker가 가리키는
base/WAL이 있으면 그 경로에서 `petflow-db`를 복원한다. marker도 복원 가능한
백업도 없으면 `initdb`를 수행한다. marker는 있으나 파일이 누락되거나 복원에
실패하면 빈 DB로 전환하지 않고 중단한다.

매번 `cnpg/generations/<UTC 시각>-<UUID>/`에 새 ObjectStore를 만들어 WAL과 다음
base backup을 보관한다. 이전 세대 ObjectStore는 복원 입력으로만 사용한다. 복원
또는 initdb 후 새 세대의 base/WAL 업로드를 검증하고 marker를 갱신한 다음에만
GitOps를 시작한다. S3 Versioning이 켜져 있으므로 marker 이전 버전도 남는다.
이전 세대의 백업은 자동 삭제하지 않으며 보관 비용을 확인해 정리해야 한다.

이 변경은 infra와 gitops 저장소가 함께 배포되어야 한다. 이전 GitOps main이
Cluster/ObjectStore를 계속 관리하면 실행 시 생성한 경로를 덮어쓸 수 있으므로,
변경된 GitOps main이 원격에 반영됐는지 `tapply.sh`가 먼저 확인한다.

Private subnet의 S3 트래픽은 Terraform network 모듈이 생성하는 S3 Gateway VPC Endpoint를
통해 전송한다. 이 Endpoint는 모든 private route table에 연결된다.

## 인증 방식 결정

팀의 EKS 인증 표준에 맞춰 CNPG 백업도 Pod Identity를 사용한다.
Barman ObjectStore의 `inheritFromIAMRole: true`는 IRSA 전용 설정이 아니라 AWS SDK 기본 자격 증명 체인을
사용하라는 뜻이다. EKS Pod Identity Agent가 이 체인에 컨테이너 자격 증명을 제공하므로
ServiceAccount annotation 없이도 Barman Cloud Plugin이 S3 Role을 사용할 수 있다.

- [CNPG Barman S3 인증](https://cloudnative-pg.io/plugin-barman-cloud/docs/0.14.0/object_stores/)
- [AWS Pod Identity SDK 지원](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html)
- [Barman AWS S3 권한](https://docs.pgbarman.org/release/3.20.0/user_guide/barman_cloud.html#aws-s3-permissions)

## 리소스와 권한

- DEV root 는 기존 s3_bucket_purposes 에 db-backups 를 중복 없이 추가한다.
- 기존 앱 버킷 주소와 보호 설정은 유지한다. db-backups 는 force_destroy=false,
  prevent_destroy=true 로 보호하고 백업 복구를 위해 Versioning=true 로 설정한다.
- Public Access Block, SSE-S3(AES256), TLS 강제는 기존 S3 모듈 설정을 상속한다.
- `tdestroy.sh`는 S3를 보존하고 CNPG Role/Pod Identity Association을 포함한 나머지 DEV 인프라만 제거한다.
- Role trust는 `pods.eks.amazonaws.com` 서비스에 `sts:AssumeRole`, `sts:TagSession`만 허용한다.
- Pod Identity Association은 정확한 EKS Cluster, namespace, ServiceAccount 조합에 연결한다.
- 전용 버킷에서 ListBucket 을 허용한다. Barman HeadBucket 검사에는 prefix 조건이 없어 목록 권한을 prefix 로 제한하지 않는다.
- 객체 GetObject/PutObject/AbortMultipartUpload/DeleteObject 는 cnpg_backup_prefix 아래로 제한한다.
- 버킷은 Terraform 이 생성하므로 CreateBucket 은 불필요하다. DeleteBucket, DeleteObjectVersion 및 앱 버킷 권한은 부여하지 않는다.
- DeleteObject 는 Barman retention 정리에 사용하며, Versioning 이 켜진 버킷에서는 이전 버전을 남긴다.
- 보관 기간 확정 전 자동 만료 lifecycle 은 설정하지 않는다. 이전 버전은 계속 누적되므로 GitOps retention 과 함께 noncurrent version 정리 정책을 후속 설정해야 한다.

## EBS Recovery Point 보호와 Destroy Guard

`petflow-dev-cnpg-ebs` Vault는 AWS Backup Plan의 7일 보존기간과 같은 최소
보존기간을 갖는 Governance Vault Lock을 사용한다. `changeable_for_days`는 설정하지
않으므로 Compliance Mode로 전환되지 않는다.

`tdestroy.sh`는 현재 CNPG PVC → PV → EBS를 식별한 뒤 각 EBS에 대해
온디맨드 AWS Backup Job을 자동 생성한다. 사용자가 별도 백업 명령을 먼저 실행할
필요는 없다. 기본 Poll 간격은 30초, 제한시간은 3600초이며 다음처럼 조정할 수 있다.

```bash
BACKUP_POLL_INTERVAL_SECONDS=15 BACKUP_TIMEOUT_SECONDS=3600 \
  AWS_PROFILE=ujibil2 ./tdestroy.sh
```

Recovery Point에는 `Project=petflow`, `Environment=dev`,
`BackupType=pre-destroy`, `SourceVolumeId`, `DestroyRunId`,
`CreatedBy=tdestroy.sh`, `ProtectedResource=cnpg` 태그를 기록한다.
Vault Lock은 Governance Mode와 최소 보존기간 7일을 유지하며 조건이 다르면 삭제를
시작하지 않는다.

백업 Job은 모두 `COMPLETED`여야 하며 Job ID, 원본 EBS ARN, Recovery Point ARN,
완료 시각, 실행 ID와 태그가 이번 Destroy 실행과 정확히 일치해야 한다. 일부만
성공하거나 실패·시간 초과·알 수 없는 상태가 나오면 Kubernetes cleanup과 Terraform
destroy를 모두 실행하지 않는다.

검증 성공 시 권한 `0600`의
`.destroy-evidence/<run-id>-cnpg-backups.json` schema v2 Manifest를 생성한다.
Manifest에는 PVC/PV/EBS 매핑과 Job/Recovery Point 정보만 저장하며 자격 증명은
기록하지 않는다. `cleanup-k8s.sh`는 절대 경로 Manifest 없이는 단독 실행되지 않고,
현재 CNPG EBS 전체가 Manifest에 포함됐는지 다시 확인한다. 동일
`PETFLOW_DESTROY_RUN_ID`로 재실행하면 기존 Manifest와 Recovery Point를 AWS에서
재검증한 뒤 cleanup/destroy를 재개한다.

Recovery Point는 cleanup 전, PVC/EBS 정리 직후, Terraform destroy 직전과 직후에
`describe-backup-job`, `describe-recovery-point`, `list-tags`로 반복 검증한다.
Manifest 또는 AWS 상태가 하나라도 다르면 후속 삭제를 중단한다.


## GitOps 연결 계약

잠정 기본값은 namespace=database, Cluster 이름 및 ServiceAccount=petflow-db 이다.
CNPG 는 일반적으로 Cluster 이름과 같은 ServiceAccount 를 생성한다. Operator 의 ServiceAccount 에 연결하지 않는다.
이름 변경 시 Terraform 입력과 GitOps Cluster 를 함께 변경한다.

적용 후 DEV root 의 다음 output 을 사용한다.

- cnpg_backup_role_arn: Pod Identity Association에 연결된 IAM Role 확인용
- cnpg_backup_pod_identity_association_id: 생성된 Pod Identity Association 확인용
- cnpg_backup_destination_path: IAM 범위의 기본 prefix (`cnpg`). 실제 ObjectStore는 세대별 하위 경로를 사용
- cnpg_backup_service_account: PostgreSQL Pod 의 namespace 와 ServiceAccount 확인

Barman ObjectStore에는 AWS SDK 기본 자격 증명 체인을 사용하도록 다음 설정을 명시해야 한다.

```yaml
spec:
  configuration:
    s3Credentials:
      inheritFromIAMRole: true
```

GitOps Cluster에 `eks.amazonaws.com/role-arn` annotation을 추가하지 않는다. 권한 연결은 Terraform의
Pod Identity Association만 관리한다.

복구용 새 Cluster의 ServiceAccount가 달라지면 그 계정용 Pod Identity Association도 별도로 추가한다.
전체 cluster-admin은 연결된 ServiceAccount로 Pod를 만들 수 있으므로 GitOps/RBAC와 IAM 변경 권한을 별도 관리한다.
노드에는 EKS Pod Identity Agent가 실행 중이어야 하며, 사용 이미지의 AWS SDK가 컨테이너 자격 증명
공급자를 지원해야 한다.

## 후속 실환경 검증

Terraform validate/test 는 AWS 적용 및 CNPG 호환성 검증을 대신하지 않는다.
배포 시 계획에서 기존 앱 버킷 교체/삭제가 없는지 확인한 후 적용한다.
GitOps 연결 후 실제 Barman 컨테이너에서 자격 증명 획득, base backup, WAL archive,
새 Cluster 로 restore 및 데이터 검증을 수행한다. 다른 ServiceAccount 의 role assume 거부와
허용 prefix 밖 객체 접근 거부도 확인한다. 사용한 CNPG/Plugin 이미지 버전과 결과를 기록한다.

### Recovery Point 복원 점검

Recovery Point 복원은 원본 PVC에 자동 연결하지 않고 새 EBS를 생성한다.

1. Manifest의 정확한 Recovery Point ARN을 선택한다.
2. `get-recovery-point-restore-metadata`로 필수 Metadata를 확인한다.
3. `start-restore-job` 실행 후 `describe-restore-job`이 `COMPLETED`인지 확인한다.
4. 새 EBS의 Region/AZ, 크기, 암호화, `available`, `Attachments=[]`를 확인한다.
5. 복구용 PVC/PV에 명시적으로 연결한 뒤 PostgreSQL 일관성과 데이터를 검증한다.

복원 테스트용 임시 EBS는 정확한 Volume ID, `available`, 빈 Attachment를 재확인한
뒤에만 삭제한다. 검증 전에는 Recovery Point를 삭제하지 않는다. `tdestroy.sh`를
재실행할 때 EKS가 이미 없다면 자동 백업/Kubernetes cleanup은 건너뛰고 남은
Terraform 상태만 멱등하게 정리한다.
