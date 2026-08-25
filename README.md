# Infra

`골라주개냥` 서비스의 클라우드 인프라를 관리하는 Repository입니다.

## Overview

서비스 운영에 필요한 AWS 인프라를 구성하고,
Terraform을 활용하여 Infrastructure as Code(IaC) 방식으로 관리합니다.

## Tech Stack

* AWS
* Terraform
* Kubernetes / EKS
* Docker

## Repository Role

* 클라우드 네트워크 구성
* Kubernetes 클러스터 구성
* AWS 리소스 관리
* 인프라 코드 및 환경 설정 관리

> Kubernetes 배포 설정 및 GitOps 관련 구성은 별도의 `gitops` Repository에서 관리합니다.

---

## Repository 구조

현재 단계에서는 **DEV 환경만 구성**한다. `prod` 환경은 이후 운영이 필요한 시점에 별도로 추가한다.

Terraform 코드는 **재사용 가능한 Module** 과 이를 조립하는 **Environment Root Module** 로 나눈다.

```text
infra/
├─ README.md
├─ .gitignore
│
├─ docs/
│  └─ architecture.md
│
├─ terraform/
│  ├─ bootstrap/             # DEV destroy 대상 아님 — 최초 1회 생성 후 유지
│  │  ├─ state-backend/      # Terraform State 저장용 S3 Bucket
│  │  └─ terraform-access/   # Terraform 실행 Role, GitHub Actions OIDC Role, State 접근 Policy
│  │
│  ├─ modules/               # 재사용 가능한 Terraform 모듈 (DEV 삭제 대상)
│  │  ├─ network/            # VPC, Subnet, IGW, NAT, Route Table
│  │  ├─ eks/                # EKS Cluster, Node Group, OIDC Provider
│  │  ├─ iam/                # EKS / ALB / Karpenter / 애플리케이션 Role (DEV 삭제 가능만)
│  │  ├─ ecr/                # ECR Repository
│  │  └─ s3/                 # 애플리케이션용 S3 Bucket
│  │
│  └─ environments/          # 실제 Terraform 실행 위치 (Root Module)
│     └─ dev/                # DEV 환경: 위 모듈들을 조립
│
└─ scripts/
   └─ dev/                   # init.sh / plan.sh / apply.sh / destroy.sh
```

`bootstrap/` 과 `environments/dev/` 는 **생명주기가 다르다**. DEV 인프라를 `terraform destroy` 해도 `bootstrap/` 은 함께 삭제되지 않으므로 Terraform 실행 기반과 State 는 안전하게 유지된다. 자세한 원칙은 [docs/architecture.md](docs/architecture.md) 의 "Bootstrap 과 DEV 인프라의 생명주기 분리" 섹션 참고.

향후 확장 예정:

```text
terraform/environments/
├─ dev/
└─ prod/     # 추후 추가 (동일한 modules/ 재사용)
```

## 원칙

* Terraform State 는 로컬이 아닌 **S3 Remote Backend** 를 사용한다.
* State 저장용 S3 Bucket 은 일반 인프라와 분리해 관리하며, `terraform destroy` 로 삭제되지 않도록 보호한다.
* 실제 AWS 리소스는 `terraform/modules/` 에서 정의하고, `terraform/environments/dev/` 에서는 모듈 호출 및 값 전달만 담당한다.
* Dev 환경은 반복적인 `apply` / `destroy` 를 허용한다.
* 민감 정보(tfstate, tfvars, backend.hcl, AWS Key, kubeconfig 등)는 Git 에 커밋하지 않는다.
* 리포지토리 내 사람이 읽는 설명은 모두 한글로 작성한다.
* 현재 단계에서는 VPC, EKS 등 실제 리소스 코드를 작성하지 않으며, 이후 기능별 브랜치에서 추가한다.

## 사전 준비

- Terraform 1.10 이상 (S3 Backend native locking `use_lockfile = true` 사용을 위해 필요)
- AWS CLI (`aws sts get-caller-identity` 로 자격 증명 확인 가능해야 함)
- Bash (Linux / macOS / WSL)

AWS 자격 증명은 Repository 에 커밋하지 않고, 로컬에서 AWS CLI Profile / IAM Role / SSO / 환경변수 중 편한 방법으로 구성한다.

## 시작하기

```bash
# 1) State Backend (최초 1회, 별도 진행)
#    terraform/bootstrap/state-backend 에서 S3 Bucket 을 먼저 생성한다.

# 2) Dev 환경 설정 파일 준비
cp terraform/environments/dev/backend.hcl.example       terraform/environments/dev/backend.hcl
cp terraform/environments/dev/terraform.tfvars.example  terraform/environments/dev/terraform.tfvars
# backend.hcl / terraform.tfvars 안의 값을 실제 환경에 맞게 수정한다.

# 3) 스크립트 실행 권한 부여 (최초 1회)
chmod +x scripts/dev/*.sh

# 4) AWS 인증 확인
aws sts get-caller-identity

# 5) Terraform 실행
./scripts/dev/init.sh
./scripts/dev/plan.sh
./scripts/dev/apply.sh

# 반복 테스트를 위해 삭제할 때
./scripts/dev/destroy.sh
```

각 스크립트가 하는 일:

| Script | 동작 |
|---|---|
| `init.sh` | 필수 도구 / 인증 / `backend.hcl` 확인 후 `terraform init -backend-config=backend.hcl` |
| `plan.sh` | `terraform fmt` + `validate` + `plan` |
| `apply.sh` | `terraform fmt` + `validate` + `plan -out=tfplan` + `apply tfplan` |
| `destroy.sh` | `terraform plan -destroy` 후 `terraform destroy` |

자세한 아키텍처는 [docs/architecture.md](docs/architecture.md) 를 참고한다.
