# DEV 전체 복구 Runbook

EKS를 destroy한 뒤 Terraform, AWS Load Balancer Controller, GitOps, Web ALB와
Route53 Alias를 순서대로 복구하는 절차다. 일반 Terraform 변경은 기존
`tapply.sh`를 사용하고, 클러스터 전체 재구축에만 `trestore.sh`를 사용한다.

## 실행

먼저 Infra Plan을 검토한다.

```bash
./tplan.sh
```

ALB와 Target Health까지만 복구한다.

```bash
GITOPS_DIR=/home/user1/project/tong-p/gitops \
AWS_PROFILE=ujibil2 \
  ./trestore.sh
```

Route53 Alias와 공개 HTTPS까지 복구하려면 명시적으로 활성화한다.

```bash
GITOPS_DIR=/home/user1/project/tong-p/gitops \
AWS_PROFILE=ujibil2 \
APPLY_WEB_DNS=true \
  ./trestore.sh
```

## 실행 순서

1. `tapply.sh`로 Terraform과 CNPG PostgreSQL 이미지를 준비한다.
2. EKS `ACTIVE`, Private API `/readyz`, Worker Node `Ready`를 기다린다.
3. `scripts/install-alb-controller.sh`로 Controller를 설치한다.
4. GitOps 저장소에서 `task bootstrap`을 실행한다.
5. Web Ingress ADDRESS와 `petflow-dev-public` ALB `active`를 기다린다.
6. ALB에 연결된 모든 Target이 `healthy`인지 확인한다.
7. 선택적으로 `dev-web-dns` 저장 Plan을 검토·적용한다.
8. HTTP Redirect와 HTTPS 200을 검증한다.

## GitOps Checkout Guard

스크립트는 GitOps 저장소를 임의로 변경하거나 pull하지 않는다. 다음 조건이 모두
맞아야 실행한다.

- `GITOPS_DIR`이 저장소 루트다.
- Working Tree가 clean이다.
- 현재 브랜치가 `main`이다.
- `origin`이 `urineun-jigeum-bildeujung/gitops`다.
- Local HEAD와 `origin/main` HEAD가 일치한다.

Guard가 실패하면 사용자가 변경사항을 확인한 뒤 직접 branch 전환과 pull을 수행한다.

## DNS Guard

DNS 단계는 다음 조건을 모두 통과한 뒤에만 실행한다.

- Web Ingress에 ADDRESS가 있다.
- `petflow-dev-public` ALB가 `active`다.
- 연결된 Target Group에 Target이 하나 이상 있다.
- 모든 Target이 `healthy`다.
- 저장 Plan에 변경이 없거나 `aws_route53_record.web` 1건의 in-place update만 있다.

다른 리소스의 생성, 삭제 또는 교체가 포함되면 자동 Apply하지 않고 중단한다.

## 관리 경계

| 영역 | 관리 주체 |
|---|---|
| VPC, EKS, IAM, Pod Identity | Infra Terraform |
| AWS Load Balancer Controller Helm Release | Infra Bootstrap |
| Ingress, Service, Deployment | GitOps/Argo CD |
| `leechs.shop` Route53 Alias | `dev-web-dns` Terraform |

Controller Helm Release를 GitOps와 Infra가 동시에 관리하지 않는다. 현재 공식 설치
경로는 `scripts/install-alb-controller.sh`이며 `trestore.sh`가 이를 호출한다.

## 장애 확인

| 증상 | 확인 |
|---|---|
| GitOps Guard 실패 | Working Tree, branch, origin, origin/main HEAD |
| EKS `/readyz` 실패 | Tailscale Route, 현재 kubeconfig Endpoint |
| Worker Ready 실패 | Node Group Health, EC2 Status, CNI Event |
| Controller 설치 실패 | Pod Identity Association, Deployment log |
| ALB 미생성 | IngressClass/Annotation, Subnet Tag, Controller IAM |
| Target unhealthy | Web Pod/Service/Endpoint, Health Check Path |
| DNS Guard 실패 | 저장 Plan의 변경 주소와 action |

## 완료 기준

- Terraform Plan `No changes`
- EKS와 Node Group `ACTIVE`
- Worker Node가 desired 수만큼 `Ready`
- Controller Deployment/Pod `1/1`
- Web Ingress ADDRESS 생성
- ALB `active`
- 모든 Target `healthy`
- DNS 적용 시 `dev-web-dns` Plan `No changes`
- HTTP는 HTTPS Redirect, HTTPS는 200
