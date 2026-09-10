# CNPG S3 백업 기반

Terraform 관리 범위는 db-backups 버킷과 PostgreSQL Pod 의 IRSA Role 이다.
CNPG Operator, Barman Cloud Plugin, Cluster, ObjectStore, ScheduledBackup 은 GitOps 에서 관리한다.

Private subnet의 S3 트래픽은 Terraform network 모듈이 생성하는 S3 Gateway VPC Endpoint를
통해 전송한다. 이 Endpoint는 모든 private route table에 연결된다.

## 인증 방식 결정

CNPG 백업은 Barman Cloud Plugin 의 공식 EKS IRSA 설정 경로를 따라 IRSA 를 선택했다.
기존 EKS OIDC Provider 를 재사용하고, 플랫폼 컴포넌트의 Pod Identity 는 유지한다.
IRSA 가 Pod Identity 보다 본질적으로 더 안전하다는 의미는 아니다.
Pod Identity 의 미지원이 확인된 것도 아니며, 이 결정은 공식 구성 예시와 검증 범위를 기준으로 한다.

- [CNPG Barman S3 인증](https://cloudnative-pg.io/plugin-barman-cloud/docs/0.14.0/object_stores/)
- [AWS IRSA / Pod Identity 비교](https://docs.aws.amazon.com/eks/latest/userguide/service-accounts.html)
- [Barman AWS S3 권한](https://docs.pgbarman.org/release/3.20.0/user_guide/barman_cloud.html#aws-s3-permissions)

## 리소스와 권한

- DEV root 는 기존 s3_bucket_purposes 에 db-backups 를 중복 없이 추가한다.
- 기존 앱 버킷 주소와 보호 설정은 유지한다. db-backups 는 force_destroy=false,
  prevent_destroy=true 로 보호하고 백업 복구를 위해 Versioning=true 로 설정한다.
- Public Access Block, SSE-S3(AES256), TLS 강제는 기존 S3 모듈 설정을 상속한다.
- `tdestroy.sh`는 S3를 보존하고 CNPG IRSA Role을 포함한 나머지 DEV 인프라만 제거한다.
- Role 의 OIDC trust 는 정확한 namespace/ServiceAccount sub 와 aud=sts.amazonaws.com 을 요구한다.
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

- cnpg_backup_role_arn: Cluster.spec.serviceAccountTemplate.metadata.annotations 의 eks.amazonaws.com/role-arn
- cnpg_backup_destination_path: ObjectStore.spec.configuration.destinationPath
- cnpg_backup_service_account: PostgreSQL Pod 의 namespace 와 ServiceAccount 확인

Barman ObjectStore에는 ServiceAccount의 IRSA Role을 사용하도록 다음 설정을 명시해야 한다.

```yaml
spec:
  configuration:
    s3Credentials:
      inheritFromIAMRole: true
```

Cluster 의 관련 부분 예시 (전체 배포 manifest 가 아님):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: petflow-db
  namespace: database
spec:
  serviceAccountTemplate:
    metadata:
      annotations:
        eks.amazonaws.com/role-arn: <cnpg_backup_role_arn output>
```

복구용 새 Cluster 는 ServiceAccount 도 달라질 수 있다. 그 계정용 IRSA 를 정확히 추가해야 하며 wildcard trust 로 넓히지 않는다.
전체 cluster-admin 은 해당 ServiceAccount 로 Pod 를 만들 수 있다. IRSA 는 관리자 간 권한 격리 수단이 아니므로 GitOps/RBAC 와 IAM 변경 권한을 별도 관리한다.
IRSA 의 STS 통신 경로도 필요하다. 현재 NAT 경로를 사용하며 S3 Gateway Endpoint 만으로 STS 통신이 해결되지는 않는다.

## 후속 실환경 검증

Terraform validate/test 는 AWS 적용 및 CNPG 호환성 검증을 대신하지 않는다.
배포 시 계획에서 기존 앱 버킷 교체/삭제가 없는지 확인한 후 적용한다.
GitOps 연결 후 실제 Barman 컨테이너에서 자격 증명 획득, base backup, WAL archive,
새 Cluster 로 restore 및 데이터 검증을 수행한다. 다른 ServiceAccount 의 role assume 거부와
허용 prefix 밖 객체 접근 거부도 확인한다. 사용한 CNPG/Plugin 이미지 버전과 결과를 기록한다.
