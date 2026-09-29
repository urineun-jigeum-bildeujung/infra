# Argo CD·Jenkins 관리 도메인

DEV의 Argo CD와 Jenkins는 Tailscale Subnet Router를 통과한 요청만 받는 하나의
Internal ALB를 공유한다.

| 서비스 | 주소 | ALB → Kubernetes | 접근 조건 |
| --- | --- | --- | --- |
| Argo CD | `https://argocd.leechs.shop` | HTTPS, `argocd/argocd-server:443` | Tailscale 연결 |
| Jenkins | `https://jenkins.leechs.shop` | HTTP, `jenkins/jenkins:8080` | Tailscale 연결 |

Grafana는 기존 `petflow-dev-public` ALB를 계속 사용하고 Prometheus는 ClusterIP 전용이다.
Web/Gateway의 Public ALB와 ingress-nginx Classic ELB도 이 구성의 대상이 아니다.

## 관리 경계

| 리소스 | 소유 주체 |
| --- | --- |
| `petflow-dev-management-alb` frontend Security Group | DEV Terraform State |
| `petflow-dev-management` Internal ALB, Listener, Target Group, backend SG 규칙 | AWS Load Balancer Controller |
| Argo CD Ingress와 외부 URL | GitOps `helm-values/argocd.yaml`, `bootstrap:argocd` |
| Jenkins Ingress와 외부 URL | GitOps `platform/40-jenkins/application.yaml` |
| Argo CD·Jenkins Route53 A Alias | `dev-management-dns` Terraform State |

Terraform은 ALB 자체를 만들지 않는다. Controller가 만든 ALB를 이름·VPC·scheme·태그로
검증한 뒤 DNS Alias만 연결한다.

## Tailscale 접근 제어

Tailscale Router는 VPC `10.0.0.0/20`을 광고하며 기본 subnet-router SNAT를 사용한다.
따라서 ALB가 보는 요청 소스는 Router ENI이고, frontend SG의 443 인바운드는 현재 IP가
아닌 Router SG를 참조한다. Router EC2 또는 private IP가 바뀌어도 Terraform 참조가 새 SG
ID를 해결한다.

Ingress는 고유한 SG 이름 `petflow-dev-management-alb`를 사용한다. VPC 안에서 Security
Group name은 유일하며 AWS Load Balancer Controller가 이를 ID로 해석한다. custom frontend
SG 사용 시 필요한 Pod/Node backend 규칙은
`alb.ingress.kubernetes.io/manage-backend-security-group-rules: "true"`로 Controller가
관리한다. `0.0.0.0/0`, VPC 전체 CIDR, Tailscale `100.x` CIDR은 frontend 인바운드에 넣지 않는다.

## 자동 복구 순서

`./tapply.sh`는 다음 순서로 처리한다.

1. DEV Terraform이 Router와 Management frontend SG를 준비한다.
2. GitOps bootstrap이 Argo CD Ingress를 만들고 Root Application이 Jenkins Ingress를 동기화한다.
3. ALB Controller와 Web ALB 준비를 확인한다.
4. `configure-management-access.sh`가 두 Ingress 계약, Internal ALB, 443 Listener, ACM,
   두 Target Group protocol/health 및 ready Endpoint 일치를 검증한다.
5. 같은 스크립트가 `dev-management-dns` Plan에서 허용된 Alias 변경만 적용한다.
6. Route53 Alias, 로컬 `tailscale0` 경로, 인증서 검증을 포함한 두 로그인 화면 HTTP 200을 확인한다.
7. 기존 Grafana/Public Web 검증을 계속 수행하고 결과를 서비스별로 출력한다.

ALB 생성 전에는 `dev-management-dns`를 실행하지 않는다. 이 스택은 Controller가 ALB를 만든
뒤에만 data lookup을 수행한다. 같은 State를 쓰므로 `APPLY_MANAGEMENT_DNS`와
`APPLY_OBSERVABILITY_DNS`를 다르게 설정할 수 없다.

## Guard와 실패 처리

Management 자동화는 다음 중 하나라도 다르면 DNS를 적용하지 않는다.

- 두 Ingress가 동일한 `petflow-dev-management` group·ALB DNS를 사용하지 않음
- ALB가 `internal`, `application`, 현재 EKS VPC, `active`가 아님
- Controller stack/cluster 태그 또는 Terraform frontend SG가 다름
- Listener가 HTTPS 443 하나가 아니거나 wildcard ACM이 두 hostname을 포함하지 않음
- Argo Target Group이 HTTPS `/healthz`, Jenkins가 HTTP `/login`이 아님
- Target이 healthy가 아니거나 현재 ready Endpoint와 일치하지 않음
- DNS Plan에 Grafana/Argo CD/Jenkins Alias create/update와 기존 Prometheus delete 외 변경이 있음

timeout 시 Ingress/Event, Controller log, ALB/TG 상태를 출력하고 중단한다. 다른 Public ALB를
대체 대상으로 선택하거나 CLI로 Route53을 강제 UPSERT하지 않는다.

## Destroy 호환성

`cleanup-k8s.sh`는 Argo Application Controller를 멈춘 뒤 모든 Ingress를 삭제하고, VPC의
ALB/Target Group/Controller SG/ENI가 사라질 때까지 기다린다. 따라서 Controller가 frontend
SG를 사용 중인 상태에서 Terraform이 먼저 SG를 삭제하지 않는다. Route53 Alias와 ACM은
보존되고 다음 `tapply.sh`가 재생성된 ALB DNS로 갱신한다.

이번 구현에서는 실제 destroy → apply 시험을 수행하지 않는다. 코드의 정적 검증과 현재 DEV의
최소 적용 결과를 구분해 기록한다.

## 운영 확인

Tailscale이 켜진 VMware/Windows에서 다음 주소를 사용한다.

- `https://argocd.leechs.shop`
- `https://jenkins.leechs.shop`

브라우저에서는 로그인 화면, Argo Application 목록, Jenkins 기존 Job 목록까지만 확인한다.
검증 목적으로 Sync/Delete/Build Now/설정 저장을 실행하지 않는다. Tailscale OFF 차단 시험은
현재 관리 연결을 잃지 않는 별도 클라이언트가 있을 때만 수행한다.
