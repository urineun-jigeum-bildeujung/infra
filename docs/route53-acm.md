# leechs.shop Route53 / ACM 구성

## 목표

`leechs.shop`의 권한 DNS를 Cloudflare에서 Route53으로 이전하고, 이후
`leechs.shop`과 `*.leechs.shop`에 사용할 ACM 인증서를 발급한다.

```text
카페24(도메인 등록기관)
  → Route53 Public Hosted Zone
  → Route53 Alias
  → ALB / Ingress
  → EKS Service
  → Pod
```

Route53과 ACM, 검증 레코드 및 서비스 DNS 레코드는 Terraform으로 관리한다.
카페24의 네임서버 변경만 도메인 소유자가 한 번 수동으로 수행한다.

## 초기 공개 DNS 확인 이력

2026-09-10 확인 기준:

- 권한 NS: `daphne.ns.cloudflare.com`, `harlan.ns.cloudflare.com`
- 루트 A/AAAA: Cloudflare 프록시 주소가 응답함
- 루트 HTTPS: Cloudflare `530` 응답
- 루트 MX/TXT/CAA: 공개 조회 결과 없음
- `www`, `api`, `grafana`, `argocd`, `jenkins`: 공개 A/CNAME 조회 결과 없음
- 부모 영역의 DS 레코드: 공개 조회 결과 없음

공개 DNS 조회만으로 Cloudflare Zone의 모든 레코드를 열거할 수는 없다.
네임서버를 바꾸기 전에 Cloudflare 대시보드에서 A, AAAA, CNAME, MX, TXT,
CAA, SRV 레코드와 DNSSEC 설정을 반드시 다시 확인한다. 필요한 레코드는
Route53에 먼저 동일하게 생성해야 한다. Cloudflare 프록시 IP는 원본 서버
주소가 아니므로 Route53 A 레코드로 그대로 복사하지 않는다.

## 현재 DNS 상태와 복구 필요 사항

2026-09-10 14:48(KST)에 기존 Hosted Zone `Z0266642X83210S9XPSO`이
Terraform 작업으로 삭제됐고, 14:54에 새 Hosted Zone
`Z10307303I03OBEI24QKC`이 생성됐다. Hosted Zone을 다시 만들면 NS가
달라지므로 카페24의 위임 정보도 반드시 새 NS로 갱신해야 한다.

새 Route53 NS:

```text
ns-22.awsdns-02.com
ns-1454.awsdns-53.org
ns-589.awsdns-09.net
ns-2020.awsdns-60.co.uk
```

현재 카페24는 삭제된 Zone의 NS를 가리키며 공개 DNS 조회는 `SERVFAIL`이다.
ACM 적용 전에 카페24 NS를 위 4개로 교체하고 다음 세 조회가 모두 새 NS를
반환하는지 확인한다.

```bash
dig +short NS leechs.shop
dig @1.1.1.1 +short NS leechs.shop
dig @8.8.8.8 +short NS leechs.shop
```

Hosted Zone은 재생성할 때마다 NS가 바뀌므로 Terraform의 일반
`destroy` 대상에 포함하지 않는다. DEV 정리는 반드시 프로젝트 루트의
`tdestroy.sh`를 사용한다.

## Hosted Zone 삭제 보호

삭제 방지는 두 계층으로 적용한다.

- DEV Route53 리소스: Terraform `prevent_destroy = true`
- Bootstrap IAM: 보호 Zone ARN의 `route53:DeleteHostedZone` 명시적 Deny

Bootstrap 정책은 DEV와 별도 state에서 관리하며 GitHub Actions Terraform
Role과 지정한 팀 IAM 사용자에게 연결한다. 다른 정책에
`AdministratorAccess`가 있어도 명시적 Deny가 우선한다. 보호 정책 자체를
의도적으로 분리하지 않는 한 콘솔, CLI, Terraform 모두 Zone 삭제가 거부된다.

레코드 생성·변경은 차단하지 않으므로 ACM 검증 CNAME과 ALB Alias는 계속
Terraform으로 관리할 수 있다.

## Phase 1 - Route53 Hosted Zone

Public Hosted Zone 생성 코드는 완료됐다. 도메인은 DEV
클러스터보다 생명주기가 길기 때문에 `prevent_destroy`로 보호하며,
`tdestroy.sh`의 삭제 대상에서도 제외한다.

### 로컬 설정

`terraform/environments/dev/terraform.tfvars`에 다음 값을 추가한다.

```hcl
domain_name = "leechs.shop"
```

### 검증 및 적용

DEV의 다른 리소스가 내려간 상태에서는 일반 `terraform apply`가 EKS/VPC까지
함께 생성할 수 있다. 이번 1회 단계에서는 계획을 확인하고 Route53 모듈만
제한하여 적용한다.

```bash
cd terraform/environments/dev
terraform init -backend-config=backend.hcl
terraform fmt -check -recursive
terraform validate
terraform plan -target=module.route53_acm
terraform apply -target=module.route53_acm
terraform output route53_name_servers
```

`-target`은 이번처럼 생명주기가 분리된 리소스를 최초 도입하는 예외 상황에만
사용한다. 적용 후 출력된 Hosted Zone ID와 NS 4개를 팀 내부 문서에 기록한다.

## Phase 2 - 카페24 네임서버 전환

1. Cloudflare의 기존 레코드와 DNSSEC/DS 설정을 최종 확인한다.
2. Route53에 서비스에 필요한 기존 레코드를 먼저 준비한다.
3. 카페24에서 Cloudflare NS 2개를 Route53 NS 4개로 교체한다.
4. 기존 NS를 먼저 지우고 빈 상태로 두지 않는다.
5. 아래 명령에서 Route53 NS 4개가 보일 때까지 전파를 확인한다.

```bash
dig +short NS leechs.shop
dig @1.1.1.1 +short NS leechs.shop
dig @8.8.8.8 +short NS leechs.shop
```

ALB와 루트/API Alias가 아직 없다면 네임서버 전환 후 웹 접속은 서비스되지
않는다. 허용 가능한 점검 기간인지 팀과 확인하고 전환한다.

## Phase 3 - ACM

ACM 코드 구현은 완료됐으며 Route53 위임 전파를 확인한 뒤 적용한다.

- `aws_acm_certificate`: `leechs.shop`, `*.leechs.shop`
- `aws_route53_record`: ACM DNS validation 레코드
- `aws_acm_certificate_validation`: 발급 완료 대기
- `acm_certificate_arn` output

인증서는 ALB와 같은 `ap-northeast-2` 리전에 생성한다. 상태가 `ISSUED`가
될 때까지 확인한다. 와일드카드는 `api.leechs.shop` 같은 한 단계
서브도메인을 포함하지만 `a.b.leechs.shop`은 포함하지 않는다. 루트와
와일드카드는 동일한 ACM 검증 CNAME을 사용하므로 Route53에서는 하나의
검증 레코드만 관리한다.

## Phase 4 - ALB / Ingress / Alias

AWS Load Balancer Controller로 ALB를 생성한 뒤 필요한 호스트만 연결한다.

| 용도 | 도메인 |
|---|---|
| Frontend | `leechs.shop` |
| Backend API | `api.leechs.shop` |
| Grafana | `grafana.leechs.shop` |
| Argo CD | `argocd.leechs.shop` |
| Jenkins | `jenkins.leechs.shop` |

Ingress에는 HTTPS 443 리스너와 ACM ARN을 지정하고, Route53에는 ALB DNS
이름/Hosted Zone ID를 대상으로 하는 A/AAAA Alias를 만든다. 마지막으로
DNS, 인증서 체인, HTTPS 응답과 각 호스트의 라우팅을 확인한다.

## 완료 기준

- Route53 Hosted Zone과 NS 4개가 Terraform output으로 확인됨
- 카페24의 권한 NS가 Route53으로 전파됨
- ACM 인증서가 `ISSUED` 상태임
- 필요한 Route53 Alias만 생성됨
- 각 HTTPS URL이 의도한 ALB → Ingress → Service → Pod로 연결됨
