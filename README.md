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
├─ tinit.sh                  # 프로젝트 루트에서 실행하는 편의 스크립트 (dev 대상)
├─ tplan.sh
├─ tapply.sh                 # --auto-approve
└─ tdestroy.sh               # --auto-approve, 3초 카운트다운 안전장치
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

## 사전 준비 (모든 팀원 공통)

- **Terraform 1.10 이상** — S3 Backend native locking (`use_lockfile = true`) 사용을 위해 필요
- **AWS CLI v2** — `aws sts get-caller-identity` 로 자격 증명 확인 가능해야 함
- **Bash** — Linux / macOS / WSL. 스크립트는 실행 비트가 이미 `git` 에 등록되어 있어 별도 `chmod +x` 불필요

AWS 자격 증명은 **절대 Repository 에 커밋하지 않고**, 로컬에서 AWS CLI Profile / IAM Role / SSO / 환경변수 중 편한 방법으로 구성한다.

---

## 팀원 온보딩 (각자 자기 로컬에서 최초 1회)

새로 합류한 팀원이 clone 하고 나서 실제 인프라 조회/배포까지 가는 흐름이다.

**전제:**
- Bootstrap 담당자가 `state-backend` / `terraform-access` 스택을 이미 apply 해둔 상태여야 한다. (아직 안 됐다면 [Bootstrap 담당자 최초 실행 절차](docs/architecture.md) 를 먼저 참고)
- 팀장/담당자로부터 아래 두 가지를 받는다.
  1. 배정받은 IAM 사용자의 **Access Key ID + Secret Access Key** (안전한 채널로. Slack DM/카톡/이메일 금지, 1Password/Bitwarden 등 secret manager 사용)
  2. 팀 공유 정보 (State Bucket 이름, region, project_name, VPC CIDR 등 — 팀 내부 문서/위키에 관리)

### Step 1. 필수 도구 설치 (Ubuntu 예시)

```bash
# Terraform 1.10 이상
sudo apt update && sudo apt install -y gnupg software-properties-common curl unzip git
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

terraform version   # 1.10.x 이상 확인
aws --version
```

macOS 는 `brew install terraform awscli`, Windows 는 `choco install terraform awscli` 또는 WSL Ubuntu 사용 권장.

### Step 2. AWS 자격 증명 설정 (자기 IAM 사용자로)

```bash
aws configure --profile goljugaenyang
# AWS Access Key ID:     (배정받은 자기 Key)
# AWS Secret Access Key: (자기 Secret)
# Default region name:   ap-northeast-2
# Default output format: json

export AWS_PROFILE=goljugaenyang
# 셸 재시작 시 유지되게 하려면 ~/.bashrc / ~/.zshrc 에 추가

aws sts get-caller-identity
# → Account, UserId 가 자기 것으로 출력되면 OK
```

**절대 금지:**
- Access Key 를 스크립트/tfvars/커밋에 넣기
- Slack/카톡 등 평문 채널에 붙여넣기
- 다른 팀원과 Key 공유 (각자 자기 것 사용)

### Step 3. 프로젝트 clone + 로컬 설정 파일 준비

```bash
git clone https://github.com/urineun-jigeum-bildeujung/infra.git
cd infra

# 팀 공유 정보로 값 채워야 하는 두 파일 준비
cp terraform/environments/dev/backend.hcl.example \
   terraform/environments/dev/backend.hcl
cp terraform/environments/dev/terraform.tfvars.example \
   terraform/environments/dev/terraform.tfvars

# 두 파일을 편집기로 열어서 팀 공유 정보 (Bucket 이름 등) 로 값 수정
# ⚠️ 이 두 파일은 .gitignore 로 커밋 차단되어 있음 — 절대 커밋 시도 금지
```

### Step 4. Terraform 초기화 + 연결 확인

**모든 명령은 프로젝트 루트(`infra/`)에서 실행한다.**

```bash
./tinit.sh
# → 필수 도구 / AWS 인증 / backend.hcl 존재 확인 후
#    terraform init -backend-config=backend.hcl 실행
#    성공 시 팀 공유 State S3 Bucket 에 연결됨

./tplan.sh
# → 실제로 변경될 리소스가 있으면 계획이 보임 (없으면 "No changes")
```

여기까지 성공하면 **팀원 온보딩 완료**. 이제 브랜치 파서 자기 작업 시작하면 된다.

---

## 일상 작업 흐름 (온보딩 완료 후, 누구나)

```bash
git checkout dev && git pull

git checkout -b feat/<작업이름>
# ... Terraform 코드 편집 ...

./tplan.sh      # 변경 계획 검토
./tapply.sh     # 실제 반영 (--auto-approve 포함)

# 테스트 종료 후 정리
./tdestroy.sh   # --auto-approve 포함, 3초 카운트다운 후 실행

git push -u origin feat/<작업이름>
gh pr create --base dev
```

State locking (`use_lockfile = true`) 덕분에 팀원 A 가 apply 중이면 B 는 자동 대기/거절되어 State 충돌이 방지된다.

## 각 스크립트가 하는 일

| Script | 위치 | 동작 |
|---|---|---|
| `tinit.sh` | 프로젝트 루트 | 필수 도구 / 인증 / `backend.hcl` 확인 후 `terraform init -backend-config=backend.hcl` |
| `tplan.sh` | 프로젝트 루트 | AWS 인증 확인 → `terraform fmt` + `validate` + `plan` |
| `tapply.sh` | 프로젝트 루트 | AWS 인증 확인 → `fmt` + `validate` + `apply --auto-approve` |
| `tdestroy.sh` | 프로젝트 루트 | AWS 인증 확인 → 대상 Account/스택 안내 → 3초 카운트다운 → `destroy --auto-approve` |

모두 `terraform/environments/dev` 를 대상으로 한다. Bootstrap 스택(`state-backend`, `terraform-access`)은 이 스크립트로 조작되지 않는다.
Bootstrap 스택은 담당자가 해당 디렉터리로 직접 이동해서 `terraform` 명령을 실행한다 ([docs/architecture.md](docs/architecture.md) §5 참고).

## 다음 참고 문서

- [docs/architecture.md](docs/architecture.md) — 아키텍처 원칙, Bootstrap ↔ DEV 생명주기 분리, Bootstrap 담당자 최초 실행 절차, AWS 계정 발급 전 작업 원칙
