# Jenkins Kaniko ECR 연동 계약

이 문서는 Terraform이 제공하는 Jenkins Kaniko용 AWS 권한과 Jenkins/GitOps에서 맞춰야 할 Kubernetes 인터페이스를 정의한다.

## 역할 구분

| Infra(Terraform) | Jenkins / GitOps |
|---|---|
| ECR Repository 생성 | Jenkins Pipeline 구성 |
| Kaniko IAM Role/Policy 생성 | `jenkins` Namespace 및 ServiceAccount 생성 |
| EKS Pod Identity Association 생성 | Kaniko Pod에 ServiceAccount 지정 |
| ECR 권한 범위 관리 | 실제 이미지 Build/Push 검증 |

## 고정 인터페이스

| 항목 | 값 |
|---|---|
| Cluster | `petflow-eks` |
| Namespace | `jenkins` |
| ServiceAccount | `jenkins-kaniko` |
| IAM 방식 | EKS Pod Identity |
| IAM Role | `petflow-dev-jenkins-kaniko` |
| IAM Policy | `petflow-dev-jenkins-ecr` |
| ECR Scope | `petflow/*` |
| AWS Account | `297165773875` |
| Region | `ap-northeast-2` |

Pod Identity를 사용하므로 ServiceAccount에 `eks.amazonaws.com/role-arn` annotation을 추가하지 않는다.

## ECR Repository

기존 5개 Repository에 다음 2개를 추가한다.

- `petflow/notification-service`
- `petflow/review-service`

Registry 주소는 `297165773875.dkr.ecr.ap-northeast-2.amazonaws.com`이다.

## Kubernetes 설정

GitOps에서 ServiceAccount를 생성하고 Kaniko Pod가 반드시 이 계정을 사용하도록 한다.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-kaniko
  namespace: jenkins
---
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-build
  namespace: jenkins
spec:
  serviceAccountName: jenkins-kaniko
  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
      args:
        - --context=$(CONTEXT)
        - --dockerfile=$(DOCKERFILE)
        - --destination=297165773875.dkr.ecr.ap-northeast-2.amazonaws.com/petflow/notification-service:$(IMAGE_TAG)
```

Pipeline 변수와 Kaniko 이미지 버전, Workspace 연결 방식은 Jenkins 팀에서 관리한다.

## 권한 범위

`ecr:GetAuthorizationToken`은 Repository ARN 단위로 제한할 수 없어 `Resource="*"`를 사용한다.
나머지 Push/Pull 권한은 다음 ARN 범위로만 제한한다.

```text
arn:aws:ecr:ap-northeast-2:297165773875:repository/petflow/*
```

허용 작업:

- ECR 인증 토큰 발급
- Layer 존재 확인 및 다운로드
- Layer Upload 시작/분할 업로드/완료
- Image Manifest 조회 및 Push

Repository 생성·삭제와 Lifecycle Policy 수정 권한은 부여하지 않는다.

## Terraform Output

```bash
terraform -chdir=terraform/environments/dev output jenkins_kaniko_role_arn
terraform -chdir=terraform/environments/dev output jenkins_ecr_policy_arn
terraform -chdir=terraform/environments/dev output ecr_repository_urls
```

## 적용 후 AWS 검증

```bash
aws eks list-pod-identity-associations \
  --cluster-name petflow-eks \
  --region ap-northeast-2

aws ecr describe-repositories \
  --region ap-northeast-2 \
  --repository-names \
  petflow/notification-service \
  petflow/review-service
```

## 최종 통합 검증

1. Jenkins Pipeline이 Kaniko Pod를 생성한다.
2. Pod의 `serviceAccountName`이 `jenkins-kaniko`인지 확인한다.
3. 정적 AWS Access Key 없이 Pod Identity 자격증명을 사용하는지 확인한다.
4. 두 Repository 중 대상 Repository로 이미지를 Push한다.
5. ECR에서 해당 Image Tag와 Digest가 생성됐는지 확인한다.
