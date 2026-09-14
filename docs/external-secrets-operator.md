# External Secrets Operator Pod Identity

이 문서는 External Secrets Operator(ESO)가 AWS Secrets Manager를 읽기 위해 Infra와
GitOps가 공유해야 하는 EKS Pod Identity 계약을 정의한다.

## 고정 계약

| 항목 | 값 |
|---|---|
| EKS Cluster | `petflow-eks` |
| Namespace | `external-secrets` |
| ServiceAccount | `external-secrets` |
| IAM Role | `petflow-dev-external-secrets` |
| 인증 방식 | EKS Pod Identity |
| Secret 범위 | `petflow/*` |

Pod Identity를 사용하므로 ServiceAccount에
`eks.amazonaws.com/role-arn` annotation을 추가하거나 장기 AWS Access Key를
Kubernetes Secret에 저장하지 않는다.

## IAM 권한

ESO Role은 다음 권한만 가진다.

- `secretsmanager:GetSecretValue`
- `secretsmanager:DescribeSecret`
- Resource: `arn:aws:secretsmanager:ap-northeast-2:<account-id>:secret:petflow/*`

현재 `petflow/*` Secret은 AWS Secrets Manager 기본 관리형 암호화 키를 사용하므로
`kms:Decrypt`는 부여하지 않는다. Custom KMS Key를 도입할 때만 실제 Key ARN에 한정한
권한을 별도로 검토한다.

## 책임 분리

Infra 팀은 IAM Role/Policy와 Pod Identity Association을 Terraform으로 관리한다.
CloudNative 팀은 ESO Helm 배포 시 위 Namespace와 ServiceAccount를 유지하고,
후속 브랜치에서 SecretStore 또는 ClusterSecretStore와 ExternalSecret을 관리한다.

## 검증

Association 메타데이터만 확인한다.

```bash
AWS_PROFILE=ujibil2 aws eks list-pod-identity-associations \
  --cluster-name petflow-eks \
  --region ap-northeast-2

AWS_PROFILE=ujibil2 aws eks describe-pod-identity-association \
  --cluster-name petflow-eks \
  --association-id <association-id> \
  --region ap-northeast-2
```

Kubernetes에서는 Pod, ServiceAccount, ExternalSecret 상태와 대상 Secret의 존재 여부만
확인한다. Secret의 `data`, AWS SecretString 또는 인증정보 원문은 터미널·로그·PR에
출력하지 않는다.

```bash
kubectl --context petflow-dev get serviceaccount external-secrets -n external-secrets
kubectl --context petflow-dev get pods -n external-secrets
kubectl --context petflow-dev get externalsecret -A
```

실제 Secret 동기화와 Application Pod 주입 검증은 SecretStore/ExternalSecret 후속
작업에서 진행한다.
