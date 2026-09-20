# Grafana 공개 접근·Prometheus 비공개 운영

## 목적

DEV 기간에는 Tailscale 초대 여부와 관계없이 팀원이 Grafana에 접속할 수 있게 하되,
Prometheus는 외부에 노출하지 않는다.

| 서비스 | 접근 정책 | 주소 |
|---|---|---|
| Grafana | 인터넷 공개, HTTPS·로그인 필수 | `https://grafana.leechs.shop` |
| Prometheus | Ingress·외부 DNS 없음, ClusterIP 전용 | `kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090` |

```text
Internet → Route53 grafana.leechs.shop → petflow-dev-public ALB
         → Grafana :80 → Prometheus ClusterIP :9090
```

## 소유권

| 영역 | 소유 주체 |
|---|---|
| Grafana Ingress와 인증 설정 | GitOps/Argo CD |
| Public ALB, Listener Rule, Target Group | AWS Load Balancer Controller |
| ACM, Controller IAM/Pod Identity, Subnet Tag | 코어 Infra Terraform |
| Grafana Alias와 Prometheus 기존 Alias 제거 | `dev-management-dns` Terraform State |
| 생성·검증 | 루트 `tapply.sh` |
| Ingress/LB/TG/SG/ENI 정리 검증 | `tdestroy.sh` → `cleanup-k8s.sh` |

ALB ARN, DNS와 Target Group ARN은 재생성될 수 있으므로 GitOps나 tfvars에
기록하지 않고 실행 시 조회한다.

## GitOps 정책

`platform/30-kube-prometheus-stack/manifests/ingress-grafana-public.yaml`은
`grafana-public` Ingress 하나만 관리한다.

- IngressGroup: `petflow-public`
- Scheme: `internet-facing`
- Target Type: `ip`
- Listener: HTTP 80, HTTPS 443
- HTTP 동작: HTTPS 443 Redirect
- Host: `grafana.leechs.shop`
- Health Check: `/api/health`
- 별도 `load-balancer-name` annotation 없음

Web/Alloy와 같은 그룹을 사용해 `petflow-dev-public` ALB를 재사용한다. 별도
Grafana ALB를 생성하지 않는다. NetworkPolicy는 Public ALB가 위치한 Public Subnet
`10.0.0.0/24`, `10.0.1.0/24`에서 Grafana Pod 3000 포트로 들어오는 트래픽만 허용한다.

Grafana Helm values는 다음을 강제한다.

- `auth.anonymous.enabled=false`
- `users.allow_sign_up=false`
- 인증정보 값은 Git에 저장하지 않고 Chart가 관리하는 Kubernetes Secret 사용

## Prometheus 비공개 기준

Prometheus에는 Ingress, 외부 Route53 레코드와 LoadBalancer Service를 만들지 않는다.
NetworkPolicy는 Grafana와 Argo Rollouts Pod에서 9090 포트로 들어오는 트래픽만 허용한다.
직접 UI를 확인할 운영자는 Tailscale 연결 후 포트포워딩한다.

```bash
kubectl --context petflow-dev -n observability port-forward \
  svc/kube-prometheus-stack-prometheus 9090:9090
```

Grafana Data Source는 클러스터 내부 주소를 사용한다.

```text
http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090
```

## DNS State 전환

`terraform/environments/dev-management-dns`는 기존 S3 State
`dev/management-dns.tfstate`를 유지한다. 이름은 과거 구성과의 호환을 위해 남아 있다.

첫 전환 Plan에서 허용되는 변경은 다음뿐이다.

1. `aws_route53_record.grafana`: 기존 Internal ALB에서 Public ALB로 in-place update
2. `aws_route53_record.prometheus`: delete

그 외 리소스나 replace가 포함되면 자동화를 중단한다. 전환 후 재실행 Plan은
`No changes`여야 한다. Grafana Alias에는 계속 `prevent_destroy`를 적용한다.

## 전체 Apply

```bash
AWS_PROFILE=ujibil2 ./tapply.sh
```

Observability 단계는 다음 순서로 동작한다.

1. `grafana-public` ADDRESS가 기존 Public ALB DNS와 같은지 확인
2. IngressGroup, internet-facing Scheme, VPC와 Controller 태그 확인
3. Grafana Ingress에 임의 `load-balancer-name`이 없는지 확인
4. Prometheus Host를 가진 Ingress가 0개인지 확인
5. HTTPS Host Rule, ACM SAN과 Grafana Target Health 확인
6. 저장 DNS Plan Guard 통과 후 적용
7. Grafana Alias가 Public ALB를 가리키고 Prometheus DNS가 없는지 확인
8. HTTP 301, Grafana Health/Login 200, 비인증 `/api/user` 401 확인
9. 사후 Terraform Plan `No changes` 확인

DNS Apply와 외부 HTTPS 확인만 제외하려면 다음을 사용한다. Ingress/ALB/Target Guard는
계속 실행된다.

```bash
APPLY_OBSERVABILITY_DNS=false AWS_PROFILE=ujibil2 ./tapply.sh
```

이전 `APPLY_MANAGEMENT_DNS` 값은 호환용 fallback으로만 읽는다.

## Destroy

`cleanup-k8s.sh`는 전체 Ingress를 삭제하므로 Grafana Listener Rule과 Target Group도
정리된다. Web Ingress가 함께 삭제되는 전체 destroy에서는 Public ALB까지 제거된다.
Route53 Hosted Zone, ACM, Grafana Alias State는 일반 DEV destroy 대상이 아니며 다음
`tapply.sh`가 재생성된 Public ALB DNS로 Alias를 갱신한다. Prometheus Alias는 다시 만들지 않는다.

## 수동 검증

Tailscale을 끈 외부 환경에서도 다음을 확인할 수 있어야 한다.

```powershell
Resolve-DnsName grafana.leechs.shop
curl.exe -I http://grafana.leechs.shop
curl.exe -I https://grafana.leechs.shop/login
```

브라우저 시크릿 창에서는 로그인 화면이 나타나야 하고, 로그인 전 대시보드를 조회할 수
없어야 한다. `prometheus.leechs.shop`은 DNS 레코드가 없어야 한다.

## 롤백 대안: Internal ALB/Tailscale

보안 또는 운영 정책상 Grafana 공개를 중단해야 하면 다음 순서로 롤백한다.

1. `grafana.leechs.shop` Alias 제거 또는 Internal ALB 대상으로 복원
2. `grafana-public` Ingress 제거
3. Grafana 전용 Internal ALB Ingress를 복원하고 inbound CIDR을 `10.0.0.0/20`으로 제한
4. Tailscale + kubectl port-forward 방식으로 검증

과거의 `petflow-dev-management` Internal ALB 구성은 이 롤백을 위한 참조 설계다.
롤백하더라도 Grafana 익명 접근 차단과 Prometheus 비공개 정책은 유지한다.

## 장애 확인

| 증상 | 확인 항목 |
|---|---|
| Grafana ADDRESS 없음 | Controller Pod/로그, Ingress Event, Public Subnet Tag |
| 별도 ALB 생성 | `group.name=petflow-public`, 임의 `load-balancer-name` 유무 |
| HTTPS Listener 없음 | ACM 상태/SAN, Certificate Discovery, `listen-ports` |
| 503 또는 Target unhealthy | Service/Endpoint, NetworkPolicy Public Subnet CIDR, `/api/health` |
| 로그인 없이 조회됨 | `auth.anonymous.enabled`, Grafana ConfigMap/Pod 재배포 |
| Prometheus가 외부 조회됨 | Prometheus Ingress, Route53 레코드, LoadBalancer Service |
