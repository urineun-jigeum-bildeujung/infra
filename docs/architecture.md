# 인프라 아키텍처 개요

이 문서는 `골라주개냥` 서비스의 AWS 인프라 구조와 리포지토리 구성을 요약한다.
세부 리소스 정의는 각 기능 브랜치(`feat/network`, `feat/eks` 등)에서 Terraform 코드로 관리한다.

---

## 1. 현재 단계 범위

- 현재 프로젝트 목표는 **개발 및 인프라 반복 테스트** 이다.
- 따라서 이 리포지토리에서는 **DEV 환경만 구성**한다.
- `prod` 환경은 DEV 환경이 안정화되고 실제 운영이 필요해지는 시점에 별도로 추가한다.

---

## 2. 코드 구성 원칙

Terraform 코드는 두 계층으로 분리한다.

```text
modules/
  └─ 실제 AWS 리소스를 만드는 재사용 가능한 코드

environments/
  └─ 모듈들을 조립하고 환경별 값을 전달하는 실행 위치 (Root Module)
```

- `modules/` 는 특정 환경에 종속되지 않는다. DEV / PROD 모두에서 재사용된다.
- `environments/dev/` 는 Terraform 이 실제로 실행되는 Root Module 이다.
  이곳에서 `terraform init / plan / apply` 를 수행한다.
- PROD 환경이 추가되면 `environments/prod/` 를 만들고 동일한 모듈을 재사용한다.

---

## 3. Terraform State 관리

- 로컬 State 사용을 금지하고, **S3 Remote Backend** 를 표준으로 한다.
- State Bucket 은 `terraform/bootstrap/state-backend` 에서 최초 1회 생성 후 영속적으로 유지한다.
- 일반 인프라(VPC, EKS 등) Terraform 은 이 Bucket 을 참조만 하며 삭제 대상에서 제외한다.
- State Bucket 설정: Public Access Block, Versioning, SSE 암호화, State Locking(가능 시 S3 Lockfile) 활성화.

```text
개발자 PC
   │
   ├─ terraform apply / destroy
   ▼
S3 Remote Backend
   │
   └─ dev/terraform.tfstate
   │
   ▼
AWS DEV Resource (VPC, EKS, ECR ...)
```

### State Locking 방식

- **S3 native locking** (`use_lockfile = true`) 을 사용한다. 별도 DynamoDB 테이블을 두지 않는다.
- 이 옵션은 **Terraform 1.10 이상** 에서만 동작하므로 `required_version` 은 `>= 1.10.0` 으로 유지한다.
- Lock 파일은 State Key 뒤에 `.tflock` 접미어가 붙어 생성된다.
  예: `dev/terraform.tfstate` → `dev/terraform.tfstate.tflock`

### Terraform 실행 주체에게 필요한 IAM 권한

Terraform 을 실행하는 주체(로컬 개발자 Role, GitHub Actions OIDC Role 등) 는
State 파일과 Lock 파일 양쪽에 대한 권한을 모두 가져야 한다.
특히 Lock 파일의 `DeleteObject` 권한이 빠지면 lock 이 해제되지 않아 이후 apply 가 무한 대기한다.

| 대상 | 필요한 권한 |
|---|---|
| `arn:aws:s3:::<STATE_BUCKET>` | `s3:ListBucket` |
| `arn:aws:s3:::<STATE_BUCKET>/dev/terraform.tfstate` | `s3:GetObject`, `s3:PutObject` |
| `arn:aws:s3:::<STATE_BUCKET>/dev/terraform.tfstate.tflock` | `s3:GetObject`, `s3:PutObject`, **`s3:DeleteObject`** |
| KMS Key (SSE-KMS 사용 시) | `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey` |

실제 정책 구현은 **`terraform/bootstrap/terraform-access/`** 스택에서
GitHub Actions OIDC Role 및 개발자 Role 을 정의할 때 위 요구사항을 반드시 반영한다.
자세한 정책 스니펫은 해당 스택의 `main.tf` 상단 주석에 체크리스트로 남겨져 있다.

---

## 4. Bootstrap 과 DEV 인프라의 생명주기 분리

`terraform destroy` → `terraform apply` 를 반복해도 Terraform 실행 기반 자체가 함께 삭제되지 않도록
IAM 과 State Backend 를 **Bootstrap 영역** 으로 분리해서 관리한다.

```text
[Bootstrap 영역]  ← 최초 1회 생성 후 계속 유지 (DEV destroy 대상 아님)
  terraform/bootstrap/state-backend/     - State 저장용 S3 Bucket
  terraform/bootstrap/terraform-access/  - Terraform 실행 Role, GitHub Actions OIDC Role, State 접근 Policy

[DEV 인프라 영역]  ← apply / destroy 반복 가능
  terraform/environments/dev/  + terraform/modules/*
  ├─ VPC, Subnet, NAT
  ├─ EKS Cluster / Node / OIDC
  ├─ 애플리케이션용 IAM Role (EKS Cluster / Node / ALB / Karpenter / App)
  ├─ ECR
  └─ 애플리케이션용 S3
```

### IAM 관리 위치와 destroy 여부

| IAM 종류 | 관리 위치 | DEV destroy |
|---|---|---|
| Terraform 실행 개발자 Role | `bootstrap/terraform-access` | 유지 |
| GitHub Actions Terraform OIDC Role | `bootstrap/terraform-access` | 유지 |
| State S3 / `.tflock` 접근 Policy | `bootstrap/terraform-access` | 유지 |
| EKS Cluster Role | `modules/iam` | 삭제 가능 |
| EKS Worker Node Role | `modules/iam` | 삭제 가능 |
| AWS Load Balancer Controller Role | `modules/iam` | 삭제 가능 |
| Karpenter Role | `modules/iam` | 삭제 가능 |
| 애플리케이션 IAM Role | `modules/iam` | 삭제 가능 |

### 잘못된 구조와 권장 구조

```text
[잘못된 구조]                            [권장 구조]
                                          
GitHub Actions                            GitHub Actions
      │                                        │
DEV 안의 Terraform Role                   Bootstrap Terraform Role
      │                                        │
 terraform destroy                        S3 Remote State
      │                                        │
 Terraform Role 까지 삭제                 DEV Terraform
      │                                        │
 다음 apply 시 AWS 인증 불가              VPC / EKS / IAM / ECR / S3
```

### Bootstrap 스택 생성 순서

```text
1. terraform/bootstrap/state-backend/     → State 저장용 S3 Bucket 생성 (최초 1회, 로컬 state)
2. terraform/bootstrap/terraform-access/  → Terraform 실행 IAM 생성 (state-backend 의 S3 Bucket 사용)
3. terraform/environments/dev/            → 위 두 스택이 만든 기반 위에서 DEV 인프라 반복 apply / destroy
```

State Key 는 서로 겹치지 않도록 분리한다.

```text
<STATE_BUCKET>/
├─ bootstrap/terraform-access/terraform.tfstate
└─ dev/terraform.tfstate
```

---

## 5. 모듈 구성

`terraform/modules/` 하위의 각 모듈은 공통적으로 다음 파일 구조를 사용한다.

```text
main.tf       - AWS Resource 정의
variables.tf  - 외부에서 전달받을 값 정의
outputs.tf    - 다른 모듈 / Environment 에서 사용할 값 반환
```

| 모듈 | 관리 대상 |
|---|---|
| `network` | VPC, Public / Private Subnet, IGW, NAT Gateway, EIP, Route Table |
| `eks` | EKS Cluster, Managed Node Group, OIDC Provider, Cluster Access |
| `iam` | EKS Cluster Role, Node Role, ALB Controller Role, Karpenter Role, 애플리케이션 Role (DEV 삭제 가능 IAM 만) |
| `ecr` | Docker Image 저장용 ECR Repository (MSA 서비스 단위) |
| `s3` | 애플리케이션용 S3 Bucket (State 용 Bucket 과 반드시 분리) |

> Terraform 실행용 개발자 Role / GitHub Actions OIDC Role / State 접근 Policy 는
> `modules/iam` 이 아니라 `bootstrap/terraform-access` 스택에서 관리한다.
> (자세한 내용은 위 "4. Bootstrap 과 DEV 인프라의 생명주기 분리" 섹션 참고)

`network` 는 초기에는 라우팅과 서브넷 등을 포함한 큰 단위로 시작하고,
필요 시 이후 세분화한다.

---

## 6. DEV Environment Root Module

`terraform/environments/dev/` 는 실제 Terraform 실행 위치이다.

구성:

```text
backend.tf                  - S3 Remote Backend 선언
providers.tf                - Terraform / AWS Provider 설정
main.tf                     - 모듈 호출 및 조립
variables.tf                - 환경 입력 변수 정의
outputs.tf                  - 환경 최종 출력 값
terraform.tfvars.example    - tfvars 예시
backend.hcl.example         - backend.hcl 예시
```

실행 예:

```bash
cd terraform/environments/dev

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

`main.tf` 내부에서는 아래와 같이 모듈을 조립한다.

```hcl
module "network" {
  source       = "../../modules/network"
  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
}

module "eks" {
  source             = "../../modules/eks"
  project_name       = var.project_name
  private_subnet_ids = module.network.private_subnet_ids
}
```

---

## 7. DEV 반복 테스트 흐름

DEV 환경은 아래 사이클을 안전하게 반복할 수 있어야 한다.

```text
apply
 │
 ▼
테스트
 │
 ▼
destroy
 │
 ▼
apply (재생성)
```

`terraform destroy` 가 실행되어도 State 저장용 S3 Bucket 은 삭제되지 않는다.
Bucket 은 `terraform/bootstrap/state-backend` 스택에서만 생성/관리한다.

---

## 8. Prod 환경 추가 시 검토 항목

`prod` 환경을 추가할 때에는 아래 항목을 별도로 설계한다.

- DEV / PROD State 완전 분리 (Key 또는 Bucket 단위)
- Namespace 또는 NodeGroup 분리 전략
- 운영용 리소스 사이즈 및 가용성 요구사항
- 운영 배포 승인 절차 (GitHub Actions 등)
- 삭제 방지 정책 (`prevent_destroy`, IAM 제한)
- 보안 정책 (WAF, 로그, 감사 등)
- 도메인 및 인증서 구성

동일한 `terraform/modules/` 를 재사용하며, 환경별 값만 다르게 전달한다.
현재 리포지토리 초기 구조에서는 위 항목을 구현하지 않는다.
