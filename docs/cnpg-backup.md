# CNPG S3 백업 기반

Terraform 관리 범위는 db-backups 버킷, PostgreSQL Pod 의 IAM Role과 EKS Pod Identity Association이다.
CNPG Operator, Barman Cloud Plugin, Cluster, ObjectStore, ScheduledBackup 은 GitOps 에서 관리한다.

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

## GitOps 연결 계약

잠정 기본값은 namespace=database, Cluster 이름 및 ServiceAccount=petflow-db 이다.
CNPG 는 일반적으로 Cluster 이름과 같은 ServiceAccount 를 생성한다. Operator 의 ServiceAccount 에 연결하지 않는다.
이름 변경 시 Terraform 입력과 GitOps Cluster 를 함께 변경한다.

적용 후 DEV root 의 다음 output 을 사용한다.

- cnpg_backup_role_arn: Pod Identity Association에 연결된 IAM Role 확인용
- cnpg_backup_pod_identity_association_id: 생성된 Pod Identity Association 확인용
- cnpg_backup_destination_path: ObjectStore.spec.configuration.destinationPath
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
