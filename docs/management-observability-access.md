# Grafana·Prometheus Private 관리 도메인

## 목적

Grafana와 Prometheus를 Public Internet에 노출하지 않고 Tailscale로 VPC에 연결한
관리자만 다음 HTTPS 주소로 접근하게 한다.

- Grafana: `https://grafana.leechs.shop`
- Prometheus: `https://prometheus.leechs.shop`

```text
Windows → Tailscale → VPC 10.0.0.0/20
        → petflow-dev-management Internal ALB
        ├─ grafana.leechs.shop → Grafana :80
        └─ prometheus.leechs.shop → Prometheus :9090
```

## 소유권

| 영역 | 소유 주체 |
|---|---|
| 두 Ingress와 Service 연결 | GitOps/Argo CD |
| Internal ALB, Listener, Target Group, Frontend SG | AWS Load Balancer Controller |
| Private Subnet Tag, ACM, Controller IAM/Pod Identity | 코어 Infra Terraform |
| Route53 Alias 2개 | `dev-management-dns` Terraform |
| 전체 생성·검증 | 루트 `tapply.sh` |
| Ingress/LB 및 orphan 정리 검증 | 루트 `tdestroy.sh` → `cleanup-k8s.sh` |

ALB ARN, DNS, Security Group ID와 Target Group ARN은 재생성될 수 있으므로
GitOps나 tfvars에 기록하지 않는다.

## 보안 기준

- ALB 이름: `petflow-dev-management`
- Scheme: `internal`
- IngressGroup: `petflow-dev-management`
- Target Type: `ip`
- Listener: HTTP 80, HTTPS 443
- HTTP 동작: HTTPS 443 Redirect
- Inbound CIDR: `10.0.0.0/20`
- TLS: `leechs.shop`, `*.leechs.shop` ACM 인증서 자동 탐색
- Public Hosted Zone에는 이름이 보이지만 Alias 응답은 Internal ALB Private IP다.

`internet-facing` 또는 `0.0.0.0/0` 설정은 허용하지 않는다. Prometheus는
자체 사용자 인증 기능이 없으므로 특히 Public ALB로 노출하면 안 된다.

## GitOps 리소스

GitOps 저장소의
`platform/30-kube-prometheus-stack/manifests/ingress-internal.yaml`이 두
Ingress를 관리한다.

| Ingress | Host | Service | Health Check |
|---|---|---|---|
| `grafana-internal` | `grafana.leechs.shop` | `kube-prometheus-stack-grafana:80` | `/api/health` |
| `prometheus-internal` | `prometheus.leechs.shop` | `kube-prometheus-stack-prometheus:9090` | `/-/healthy` |

Health Check가 다르므로 Ingress는 분리하지만 같은 `group.name`과
`load-balancer-name`을 사용해 ALB 하나를 공유한다.

## DNS State

`terraform/environments/dev-management-dns`는 코어 DEV 및 Web DNS와 분리된
S3 State `dev/management-dns.tfstate`를 사용한다.

처음 사용하는 로컬 Checkout에서만 다음 파일을 준비한다.

```bash
cd terraform/environments/dev-management-dns
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

일반 운영에서는 이 디렉터리에서 직접 Apply하지 않고 루트 `tapply.sh`를
사용한다. Terraform은 이름으로 현재 Internal ALB와 EKS를 조회하고 다음 조건을
검증한다.

- Application Load Balancer
- Scheme `internal`
- 현재 `petflow-eks`와 같은 VPC
- `ingress.k8s.aws/stack=petflow-dev-management`
- `elbv2.k8s.aws/cluster=petflow-eks`

Alias에는 `prevent_destroy`를 적용한다. 일반 DEV destroy에서는 State와
Route53 레코드를 보존하고, 다음 Apply 때 새 ALB DNS로 갱신한다.

## 전체 Apply

```bash
AWS_PROFILE=ujibil2 ./tapply.sh
```

Management 단계에서는 다음 순서와 Guard를 적용한다.

1. Grafana/Prometheus Ingress의 ADDRESS가 같을 때까지 기다린다.
2. ALB 이름, Internal Scheme, 현재 VPC와 Controller 태그를 확인한다.
3. 80/443 Listener와 두 Host Rule을 확인한다.
4. Target Group이 정확히 2개이고 모든 Target이 `healthy`인지 확인한다.
5. DNS 저장 Plan에서 두 Alias의 create/update만 허용한다.
6. 적용 후 Terraform Plan `No changes`를 확인한다.
7. 두 이름이 `10.0.0.0/8` Private 주소만 반환하는지 확인한다.
8. HTTP 301과 각 HTTPS Health Check 200을 확인한다.

장애 분석 중 Management DNS 변경과 HTTPS 검증만 제외하려면 다음 예외 옵션을
사용한다. ALB 및 Target Guard는 계속 실행된다.

```bash
APPLY_MANAGEMENT_DNS=false AWS_PROFILE=ujibil2 ./tapply.sh
```

## Destroy

```bash
AWS_PROFILE=ujibil2 ./tdestroy.sh
```

`cleanup-k8s.sh`는 Argo CD Application Controller를 중지한 후 모든 Ingress와
LoadBalancer Service를 삭제한다. 그 다음 아래 리소스가 VPC에 남지 않을 때까지
기다린다.

- ALB/NLB 및 Classic ELB
- Target Group
- `ingress.k8s.aws/resource` 태그가 있는 Controller 관리 Security Group
- 설명이 `ELB *`인 Network Interface

어느 하나라도 제한 시간 뒤 남으면 Terraform Destroy를 시작하지 않는다.
Route53 Hosted Zone, ACM 인증서와 Management Alias State는 삭제하지 않는다.

## 수동 검증

Tailscale이 연결되고 `10.0.0.0/20` Route를 승인받은 Windows에서 확인한다.

```powershell
Resolve-DnsName grafana.leechs.shop
Resolve-DnsName prometheus.leechs.shop

Test-NetConnection grafana.leechs.shop -Port 443
Test-NetConnection prometheus.leechs.shop -Port 443

curl.exe -I https://grafana.leechs.shop
curl.exe -I https://prometheus.leechs.shop
```

DNS는 Private IP, TCP 검사는 `TcpTestSucceeded : True`, HTTPS는 유효한
`*.leechs.shop` 인증서를 반환해야 한다. Tailscale을 끄면 두 주소 모두 접속에
실패해야 완료로 판단한다.

## 장애 확인

| 증상 | 확인 항목 |
|---|---|
| Ingress ADDRESS 없음 | Controller Pod/로그, Ingress Event, Private Subnet Tag |
| HTTPS Listener 없음 | ACM 상태/SAN, Certificate Discovery, `listen-ports` |
| Target unhealthy | Service/Endpoint, Grafana `/api/health`, Prometheus `/-/healthy` |
| DNS만 실패 | `dev-management-dns` Plan, Route53 Alias, ALB DNS/Zone ID |
| DNS는 되지만 접속 실패 | Tailscale Route, 반환 Private IP, ALB SG 443 |
| 한 Host만 실패 | HTTPS Listener Host Rule과 해당 Target Group |
