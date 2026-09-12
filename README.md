# Infra

`골라주개냥` 서비스의 클라우드 인프라를 관리하는 Repository입니다.

## Overview

서비스 운영에 필요한 AWS 인프라를 구성하고,
Terraform을 활용하여 Infrastructure as Code(IaC) 방식으로 관리합니다.

2026-09-12 기준 DEV 환경은 AWS Account `297165773875`, Region
`ap-northeast-2`에서 운영한다. VPC `10.0.0.0/20`, Private-only EKS 1.35,
`m7i-flex.large` Managed Node 3대와 Tailscale Subnet Router가 배포되어 있다.
상세 구성과 운영 기준은 [Architecture](docs/architecture.md),
[Capacity Plan](docs/capacity-plan.md), [Operations](docs/operations.md)를 따른다.

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
│  ├─ architecture.md
│  ├─ capacity-plan.md        # Worker Node Capacity / 확장 / DEV 비용 기준
│  ├─ dev-infra-validation.md # DEV 플랫폼 기반 검증 결과
│  ├─ jenkins-kaniko-ecr.md   # Jenkins Kaniko / ECR 연동 계약
│  ├─ operations.md           # Apply / Destroy / 장애 확인 절차
│  ├─ platform-integration.md  # Karpenter / ALB Controller GitOps 연동 계약
│  ├─ route53-acm.md           # leechs.shop DNS 이전 / ACM 단계별 절차
│  ├─ tailscale-access.md      # Tailscale Router 구성 / 인증 / Private EKS 검증
│  └─ terraform-outputs.md     # 팀별 Terraform Output 사용 안내
│
├─ terraform/
│  ├─ bootstrap/             # DEV destroy 대상 아님 — 최초 1회 생성 후 유지
│  │  ├─ state-backend/      # Terraform State 저장용 S3 Bucket
│  │  └─ terraform-access/   # Terraform Role/OIDC, State 접근, Route53 삭제 차단 Policy
│  │
│  ├─ modules/               # 재사용 가능한 Terraform 모듈 (DEV 삭제 대상)
│  │  ├─ network/            # VPC, Subnet, IGW, NAT, Route Table
│  │  ├─ eks/                # EKS Cluster, Node Group, OIDC Provider
│  │  ├─ iam/                # EKS / ALB / Karpenter / 애플리케이션 Role (DEV 삭제 가능만)
│  │  ├─ ecr/                # ECR Repository
│  │  ├─ s3/                 # 애플리케이션용 S3 Bucket
│  │  ├─ route53-acm/        # Route53 Hosted Zone, ACM 인증서, DNS 검증
│  │  └─ tailscale/          # 관리자 VPN용 Private Subnet Router EC2 / SSM
│  │
│  └─ environments/          # 실제 Terraform 실행 위치 (Root Module)
│     └─ dev/                # DEV 환경: 위 모듈들을 조립
│
├─ kubernetes/
│  ├─ alb-controller/        # AWS Load Balancer Controller Helm values
│  └─ tests/                 # 임시 HTTPS End-to-End 테스트 manifest
├─ scripts/
│  ├─ install-alb-controller.sh
│  └─ https-test.sh
│
├─ tinit.sh                  # 프로젝트 루트에서 실행하는 편의 스크립트 (dev 대상)
├─ tplan.sh
├─ tapply.sh                 # --auto-approve
├─ cleanup-k8s.sh            # Private EKS에서 Ingress/LoadBalancer 사전 정리
├─ tdestroy.sh               # 보존 리소스를 제외한 Terraform DEV 인프라 삭제
└─ alldestroy.sh             # cleanup-k8s.sh → tdestroy.sh 통합 실행
```

`bootstrap/` 과 `environments/dev/` 는 **생명주기가 다르다**. `./tdestroy.sh`는 Bootstrap, Route53/ACM, 모든 S3 Bucket과 Tailscale OAuth Secret을 보존하고 나머지 DEV 인프라만 삭제한다. 도메인 이전은 [docs/route53-acm.md](docs/route53-acm.md), 생명주기 원칙은 [docs/architecture.md](docs/architecture.md) 참고.

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
* Infra 팀은 AWS/Terraform/VPC/EKS/IAM/ECR/S3/Route53/ACM/Tailscale을 관리한다.
* CloudNative 팀은 Argo CD, Jenkins 플랫폼, CNPG, Redis, Kafka, Observability,
  KEDA와 애플리케이션 Helm 리소스를 관리한다.
* 플랫폼 배포 이후 AWS 권한, Storage, Load Balancer, DNS/HTTPS 및 Karpenter 연동은
  두 팀이 함께 검증한다.

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

`cleanup-k8s.sh`와 `alldestroy.sh`를 실행하는 환경에는 `kubectl`이 설치되어 있고 Tailscale을 통해 EKS Private API에 접근할 수 있어야 한다.


macOS 는 `brew install terraform awscli`, Windows 는 `choco install terraform awscli` 또는 WSL Ubuntu 사용 권장.

### Step 2. AWS 자격 증명 설정 (자기 IAM 사용자로)

```bash
aws configure --profile petflow
# AWS Access Key ID:     (배정받은 자기 Key)
# AWS Secret Access Key: (자기 Secret)
# Default region name:   ap-northeast-2
# Default output format: json

export AWS_PROFILE=petflow
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

# 테스트 종료 후 전체 정리 (Tailscale/EKS 접근 가능한 환경)
./alldestroy.sh

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
| `cleanup-k8s.sh` | 프로젝트 루트 | 대상 계정/EKS API 확인 → Argo CD 중지 → Ingress/LoadBalancer Service 삭제 → AWS LB 소멸 확인 |
| `tdestroy.sh` | 프로젝트 루트 | 대상 계정/AWS LB 부재 확인 → Route53/ACM/S3를 제외한 DEV Terraform 모듈 삭제 |
| `alldestroy.sh` | 프로젝트 루트 | `cleanup-k8s.sh` 성공 후에만 `tdestroy.sh` 실행 |

`alldestroy.sh`는 별도 확인 입력 없이 즉시 실행된다. Kubernetes 정리에 실패하면 `set -e`에 의해 Terraform Destroy는 실행되지 않는다. VMware 운영 기준은 Tailscale subnet route를 받지 않는 Terraform/Git 전용 환경이다. 통합 삭제는 Terraform/AWS CLI가 준비된 Windows WSL과 Tailscale ON 상태에서 실행한다. 역할을 나눠 실행할 때는 Windows에서 `./cleanup-k8s.sh`를 먼저 완료하고 VMware에서 `./tdestroy.sh`를 실행한다.

모두 `terraform/environments/dev` 를 대상으로 한다. Bootstrap 스택(`state-backend`, `terraform-access`)은 이 스크립트로 조작되지 않는다.
Bootstrap 스택은 담당자가 해당 디렉터리로 직접 이동해서 `terraform` 명령을 실행한다 ([docs/architecture.md](docs/architecture.md) §5 참고).

## 다음 참고 문서

- [docs/architecture.md](docs/architecture.md) — 아키텍처 원칙, Bootstrap ↔ DEV 생명주기 분리, Bootstrap 담당자 최초 실행 절차, AWS 계정 발급 전 작업 원칙
- [docs/route53-acm.md](docs/route53-acm.md) — leechs.shop Route53 이전, ACM 및 ALB 연결 단계
- [docs/alb-https-test.md](docs/alb-https-test.md) — AWS Load Balancer Controller 설치 및 test.leechs.shop HTTPS 통합 검증
- [docs/tailscale-access.md](docs/tailscale-access.md) — AWS 전용 Subnet Router 적용, Tailnet 인증, Private EKS 접근 검증
- [docs/terraform-outputs.md](docs/terraform-outputs.md) — Infra/CloudNative/Backend/Web 팀별 Output 사용법
- [docs/capacity-plan.md](docs/capacity-plan.md) — Worker Node 선정 근거, 확장 기준, DEV 비용 원칙
- [docs/operations.md](docs/operations.md) — Apply/Destroy, 재생성, 장애 확인과 팀 간 인계 절차
