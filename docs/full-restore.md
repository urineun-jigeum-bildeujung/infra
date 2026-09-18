# DEV 전체 Apply Runbook

`tapply.sh` 한 번으로 Terraform, EKS, GitOps, Public Web ALB와 Grafana/Prometheus
Internal ALB, Route53 Alias와 HTTPS까지 생성·검증한다. 신규 생성과 재적용 모두 같은 명령을 사용한다.

## 사전 요구사항

`tapply.sh`는 리소스 변경 전에 필수 명령, AWS Profile/Account/Region과 GitOps Checkout을 검증한다.

```bash
task --version
aws sts get-caller-identity
```

GitOps 기본 경로는 Infra 저장소와 같은 상위 디렉터리의 `../gitops`다. 다른 위치를 쓸 때만
`GITOPS_DIR` 환경변수로 재정의한다. Controller/ALB 복구는 `task bootstrap:core`를 사용하므로
GitHub CLI 로그인에 의존하지 않는다. Jenkins Credential은 별도로 `task bootstrap:credentials`를 실행한다.

## 실행

먼저 Infra Plan을 검토한다.

```bash
./tplan.sh
```

DEV 전체를 공개 HTTPS 정상 상태까지 생성하는 기본 명령은 하나다.

```bash
AWS_PROFILE=ujibil2 ./tapply.sh
```

Route53 적용은 기본값이다. 장애 분석 중 DNS 변경만 의도적으로 제외할 때 해당 예외 옵션을 사용한다.

```bash
APPLY_WEB_DNS=false AWS_PROFILE=ujibil2 ./tapply.sh
APPLY_MANAGEMENT_DNS=false AWS_PROFILE=ujibil2 ./tapply.sh
```

## 실행 순서

1. 내부 `scripts/apply-infra.sh`로 Terraform과 CNPG PostgreSQL 이미지를 준비한다.
2. EKS `ACTIVE`, Private API `/readyz`, Worker Node `Ready`를 기다린다.
3. GitOps 저장소에서 `task bootstrap:core`를 실행한다.
4. Controller와 cert-manager Application, Deployment, Certificate, Webhook Endpoint를 기다린다.
5. Web Ingress와 `petflow-dev-public` Public ALB를 기다리고 Target Health를 검증한다.
6. Grafana/Prometheus Ingress가 공유하는 `petflow-dev-management` Internal ALB를 기다린다.
7. Management ALB의 Scheme/VPC/태그/Listener/Host Rule과 Target Group 2개를 검증한다.
8. `dev-management-dns` Alias 2개를 적용하고 Private DNS와 HTTPS Health를 검증한다.
9. `dev-web-dns` Alias를 적용하고 Public Web HTTP Redirect와 HTTPS 200을 검증한다.
10. EKS, Argo CD, ALB, Target, Route53 최종 상태를 출력한다.

## GitOps Checkout Guard

스크립트는 GitOps 저장소를 임의로 변경하거나 pull하지 않는다. 다음 조건이 모두
맞아야 실행한다.

- 기본값 `${SCRIPT_DIR}/../gitops` 또는 사용자가 지정한 `GITOPS_DIR`이 저장소 루트다.
- GitOps 저장소 루트에 `Taskfile.yml`이 있다.
- Working Tree가 clean이다.
- 현재 브랜치가 `main`이다.
- `origin`이 `urineun-jigeum-bildeujung/gitops`다.
- Local HEAD와 `origin/main` HEAD가 일치한다.

Guard가 실패하면 사용자가 변경사항을 확인한 뒤 직접 branch 전환과 pull을 수행한다.

## DNS Guard

DNS 단계는 다음 조건을 모두 통과한 뒤에만 실행한다.

Public Web:

- Web Ingress에 ADDRESS가 있다.
- `petflow-dev-public` ALB가 `active`다.
- 연결된 Target Group에 Target이 하나 이상 있다.
- 모든 Target이 `healthy`다.
- 저장 Plan에 변경이 없거나 `aws_route53_record.web` 1건의 in-place update만 있다.

Private Management:

- 두 Ingress ADDRESS가 같고 `petflow-dev-management` ALB DNS와 일치한다.
- ALB가 `internal`이고 현재 EKS VPC 및 Controller 태그와 일치한다.
- HTTP/HTTPS Listener와 Grafana/Prometheus Host Rule이 있다.
- Target Group이 정확히 2개이고 모든 Target이 `healthy`다.
- 저장 Plan 변경은 두 Route53 Alias의 create 또는 in-place update만 허용한다.

삭제·교체 또는 다른 리소스 변경이 포함되면 자동 Apply하지 않고 중단한다. 자세한
기준은 [management-observability-access.md](management-observability-access.md)를 참고한다.

## 관리 경계

| 영역 | 관리 주체 |
|---|---|
| VPC, EKS, IAM, Pod Identity | Infra Terraform |
| AWS Load Balancer Controller Helm Release/ServiceAccount/CRD/Webhook | GitOps/Argo CD |
| Ingress, Service, Deployment | GitOps/Argo CD |
| `leechs.shop` Route53 Alias | `dev-web-dns` Terraform |
| Grafana/Prometheus Route53 Alias | `dev-management-dns` Terraform |

Controller Helm Release를 GitOps와 Infra가 동시에 관리하지 않는다. 정상 Apply 경로는
GitOps의 `platform/10-aws-load-balancer-controller/application.yaml`이며, `tapply.sh`는
직접 Helm 설치를 실행하지 않고 Application, Ready Pod, CRD, Certificate, Webhook Endpoint 상태를 기다린다.
`scripts/install-alb-controller.sh`는 GitOps 장애를 진단한 뒤에만 사용하는 비상 도구이며,
GitOps Application이 존재하면 기본적으로 실행을 거부한다.

```bash
BREAK_GLASS_ALB_CONTROLLER=true \
AWS_PROFILE=ujibil2 \
  ./scripts/install-alb-controller.sh
```

`helm uninstall aws-load-balancer-controller -n kube-system`은 실제 Controller 리소스를 삭제하므로 인계 과정에서 실행하지 않는다.

## 장애 확인

| 증상 | 확인 |
|---|---|
| GitOps Guard 실패 | Working Tree, branch, origin, origin/main HEAD |
| EKS `/readyz` 실패 | Tailscale Route, 현재 kubeconfig Endpoint |
| Worker Ready 실패 | Node Group Health, EC2 Status, CNI Event |
| Controller GitOps Sync 실패 | Argo CD Application, Pod Identity Association, Deployment log |
| ALB 미생성 | IngressClass/Annotation, Subnet Tag, Controller IAM |
| Target unhealthy | Web Pod/Service/Endpoint, Health Check Path |
| DNS Guard 실패 | 저장 Plan의 변경 주소와 action |
| Management ALB Guard 실패 | Internal Scheme, EKS VPC, IngressGroup 태그, 80/443 Listener와 Host Rule |
| Management HTTPS 실패 | Tailscale Route, Private DNS 응답, ALB SG 443, 서비스 Health Check |

## 완료 기준

- Terraform Plan `No changes`
- EKS와 Node Group `ACTIVE`
- Worker Node가 desired 수만큼 `Ready`
- Controller Deployment/Pod `1/1`
- Controller Certificate가 모두 `Ready=True`
- Webhook Service Endpoint가 1개 이상 존재
- Web Ingress ADDRESS 생성
- Public Web ALB와 Management Internal ALB `active`
- Grafana/Prometheus Ingress ADDRESS가 동일
- Management ALB Scheme `internal`, 현재 EKS VPC와 일치
- 두 Management Host Rule 존재
- Public/Management 모든 Target `healthy`
- DNS 적용 시 `dev-web-dns` Plan `No changes`
- DNS 적용 시 `dev-management-dns` Plan `No changes`
- `leechs.shop` HTTP Redirect와 HTTPS 200
- Grafana/Prometheus HTTP Redirect와 HTTPS Health 200
- 두 관리 도메인은 Private IP만 반환하며 Tailscale 미연결 시 접속 실패
