# DEV 전체 Apply Runbook

`tapply.sh` 한 번으로 Terraform, EKS, Jenkins CI 준비, GitOps, Public Web ALB, 공개 Grafana·비공개 Prometheus 정책, Tailscale 전용 Argo CD·Jenkins Internal ALB, Route53 Alias와 HTTPS까지 생성·검증한다. 신규 생성과 재적용 모두 같은 명령을 사용한다.

## 사전 요구사항

`tapply.sh`는 리소스 변경 전에 필수 명령, AWS Profile/Account/Region과 GitOps Checkout을 검증한다.

```bash
task --version
aws sts get-caller-identity
```

GitOps 기본 경로는 Infra 저장소와 같은 상위 디렉터리의 `../gitops`다. 다른 위치를 쓸 때만
`GITOPS_DIR` 환경변수로 재정의한다. GitOps 저장소의 유효한 Jenkins Secret은 그대로 보존된다. 새
클러스터처럼 `jenkins-git-credentials`가 없으면 실행 전에 GitHub CLI 로그인이 준비돼 있어야 하며,
로그인 계정에는 `sever` 읽기와 `gitops-value` 쓰기 권한이 필요하다.

```bash
gh auth status
```

`tapply.sh`는 `gh auth login`을 자동 실행하지 않는다. 입력이나 권한이 부족하면 Jenkins Secret 단계에서
실패하며, 인증을 별도로 준비한 뒤 같은 명령을 재실행한다.

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
APPLY_OBSERVABILITY_DNS=false AWS_PROFILE=ujibil2 ./tapply.sh
# Management와 Observability는 같은 State이므로 둘 중 하나만 다르게 설정할 수 없다.
```

## 실행 순서

1. 내부 `scripts/apply-infra.sh`로 Terraform과 CNPG PostgreSQL 이미지를 준비한다.
2. EKS `ACTIVE`, Private API `/readyz`, Worker Node `Ready`를 기다린다.
3. CNPG를 복원하거나 최초 initdb를 수행한다.
4. GitOps 저장소의 `bootstrap:credentials`로 Jenkins 필수 Secret을 보존·복구하고 필수 키를 검증한다.
5. `task bootstrap:core`를 실행한다.
6. Jenkins Application, StatefulSet Ready와 준비된 Service Endpoint를 기다린다.
7. Controller와 cert-manager Application, Deployment, Certificate, Webhook Endpoint를 기다린다.
8. Web Ingress와 `petflow-dev-public` Public ALB를 기다리고 Target Health를 검증한다.
9. Web DNS Alias를 현재 Public ALB로 갱신하고 공개 HTTP/HTTPS를 검증한다.
10. Argo CD·Jenkins Ingress가 `petflow-dev-management` Internal ALB 하나를 공유할 때까지 기다린다.
11. Management ALB/SG/ACM/두 Host Rule, backend protocol과 Target Health를 검증하고 두 Alias를 적용한다.
12. `grafana-public`의 Public ALB/VPC/태그/ACM/Target Health와 Prometheus 비공개 정책을 검증한다.
13. Web·Grafana·Argo CD·Jenkins와 Jenkins CI 준비 상태를 구분해 최종 출력한다.

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

Web DNS는 Public ALB와 Target Health 검증 직후에 갱신한다. 따라서 이후 Management 또는
Grafana 단계가 실패하더라도 `leechs.shop`이 삭제된 이전 ALB를 계속 가리키는 시간을 줄인다.
`--finish`도 Web DNS/HTTPS를 먼저 복구한 뒤 Grafana 검증과 계정 준비를 수행한다.

Public Web:

- Web Ingress에 ADDRESS가 있다.
- `petflow-dev-public` ALB가 `active`다.
- 연결된 Target Group에 Target이 하나 이상 있다.
- 모든 Target이 `healthy`다.
- 저장 Plan에 변경이 없거나 `aws_route53_record.web` 1건의 in-place update만 있다.

Observability:

- Grafana Ingress ADDRESS가 `petflow-dev-public` ALB DNS와 일치한다.
- IngressGroup은 `petflow-public`, Scheme은 `internet-facing`이며 별도 ALB 이름을 지정하지 않는다.
- Grafana Host Rule과 ACM SAN이 존재하고 해당 Target이 모두 `healthy`다.
- Prometheus Ingress와 Route53 레코드는 없어야 한다.
- 저장 Plan은 Grafana create/update와 기존 Prometheus delete만 허용한다.

Management:

- 두 Ingress는 동일한 `petflow-dev-management` Internal ALB와 Terraform frontend SG를 사용한다.
- Argo CD Target은 HTTPS `/healthz`, Jenkins Target은 HTTP `/login`이며 모두 `healthy`다.
- 두 Alias는 같은 Internal ALB를 가리키고 VMware 경로는 `tailscale0`이며 TLS 검증을 통과한다.
- 저장 Plan은 Grafana·Argo CD·Jenkins Alias create/update와 기존 Prometheus delete만 허용한다.

위 허용 목록 밖의 삭제·교체 또는 다른 리소스 변경이 포함되면 자동 Apply하지 않고 중단한다. 자세한
기준은 [management-observability-access.md](management-observability-access.md)와 [management-domains.md](management-domains.md)를 참고한다.

## 관리 경계

| 영역 | 관리 주체 |
|---|---|
| VPC, EKS, IAM, Pod Identity | Infra Terraform |
| AWS Load Balancer Controller Helm Release/ServiceAccount/CRD/Webhook | GitOps/Argo CD |
| Ingress, Service, Deployment | GitOps/Argo CD |
| `leechs.shop` Route53 Alias | `dev-web-dns` Terraform |
| Grafana·Argo CD·Jenkins Alias 및 Prometheus 기존 Alias 제거 | `dev-management-dns` Terraform |

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

## Jenkins 기동 Guard와 진단

Jenkins 단계에서 중단된 실행은 `AWS_PROFILE=ujibil2 ./tapply.sh --from-jenkins`로 재개한다.
현재 실행이 종료되어 인프라 Lock이 해제된 뒤 실행한다. Terraform Apply·이미지 준비·데이터 복원·
GitOps Bootstrap을 생략하며, 복원 완료 marker와 현재 데이터 저장소 Ready 상태 및
KEDA·Karpenter·서비스 준비 조건을 다시 확인한 뒤 11단계부터 이어간다.
`--finish`는 Jenkins 재개용이 아니라 Web DNS/HTTPS와 Grafana 마무리용이다.

Application이 `Synced/Progressing`이어도 `sever-ci-gradle-cache` PVC만
`gp3/WaitForFirstConsumer`의 미사용 Pending 상태이면 통과할 수 있다. 다른 PVC는 Bound,
StatefulSet은 최신 세대·revision과 모든 replica가 준비되고 Ingress 주소가 있어야 한다.
Application 오류·진행 중인 sync·다른 비정상 health 또는 알 수 없는 workload는 허용하지 않는다.
Jenkins StatefulSet/Service Endpoint 검사도 계속 수행한다. 빌드 Pod 유무는 준비 조건이 아니다.

Jenkins Controller는 GitOps가 관리하는 플러그인 내장 ECR image digest를 사용한다. Infra는 `petflow/jenkins-controller` Repository를 보존 ECR 목록에 포함하므로 DEV `tdestroy.sh` 이후에도 이미지를 유지한다. 새 PVC 기동 시 Helm `controller.installPlugins=false`가 적용되어 init container가 외부 plugin mirror에서 플러그인을 다시 받지 않아야 한다.

`tapply.sh`는 기본 900초 동안 Jenkins Application `Synced/Healthy`, StatefulSet Ready와 준비된 Endpoint를 기다린다. `JENKINS_READY_TIMEOUT_SECONDS`, `JENKINS_READY_POLL_INTERVAL_SECONDS`, `JENKINS_DIAGNOSTIC_LOG_TAIL_LINES`는 양의 정수로만 재정의할 수 있다. 제한 시간을 넘기면 Pod/init 상태·종료 코드·재시작 횟수·PVC·Event와 필터링된 현재/이전 init 로그를 출력하고 실패 종료한다. 원인은 `PLUGIN_DOWNLOAD_NETWORK`, `PLUGIN_DOWNLOAD_HTTP`, `PLUGIN_DOWNLOAD`, `IMAGE_PULL`, `PVC_OR_VOLUME`, `SCHEDULING`, `JCASC`, `UNKNOWN`으로 구분한다. Secret 원문과 전체 환경 설정은 출력하지 않으며 Pod 자동 삭제나 무한 재시도도 하지 않는다. 원인을 처리한 뒤 동일한 `./tapply.sh`를 재실행하면 완료된 단계는 멱등하게 유지된다.

## 장애 확인

| 증상 | 확인 |
|---|---|
| GitOps Guard 실패 | Working Tree, branch, origin, origin/main HEAD |
| EKS `/readyz` 실패 | Tailscale Route, 현재 kubeconfig Endpoint |
| Worker Ready 실패 | Node Group Health, EC2 Status, CNI Event |
| Jenkins Secret 준비 실패 | `petflow-dev` context, 필수 키, `gh auth status`, `sever` 읽기·`gitops-value` 쓰기 권한 |
| Jenkins Ready 실패 | 출력된 원인 분류, init 종료 코드·현재/이전 로그, PVC, Scheduling/ImagePull/JCasC Event, Service EndpointSlice |
| Controller GitOps Sync 실패 | Argo CD Application, Pod Identity Association, Deployment log |
| ALB 미생성 | IngressClass/Annotation, Subnet Tag, Controller IAM |
| Target unhealthy | Web Pod/Service/Endpoint, Health Check Path |
| DNS Guard 실패 | 저장 Plan의 변경 주소와 action |
| Grafana ALB Guard 실패 | Public Scheme, EKS VPC, `petflow-public`, ACM, Host Rule |
| Grafana HTTPS 실패 | Alias 대상, ALB SG 443, 로그인 정책, Target Health |

## 완료 기준

- Terraform Plan `No changes`
- EKS와 Node Group `ACTIVE`
- Worker Node가 desired 수만큼 `Ready`
- Controller Deployment/Pod `1/1`
- Jenkins 두 필수 Secret의 필수 키가 비어 있지 않음
- Jenkins Application `Synced/Healthy`, StatefulSet `Ready`; 실행 imageID가 GitOps의 검증된 ECR digest와 일치
- Jenkins init `exitCode=0`; 빈 plugin 다운로드 목록이며 외부 mirror 장애 없이 기동
- Jenkins Service Endpoint가 1개 이상 준비됨 (`periodicFolderTrigger` 2분 설정 유지)
- Controller Certificate가 모두 `Ready=True`
- Webhook Service Endpoint가 1개 이상 존재
- Web Ingress ADDRESS 생성
- `petflow-dev-public` ALB `active` 및 Grafana Ingress ADDRESS 일치
- Grafana Host Rule과 유효한 ACM 인증서 존재
- Grafana Target `healthy`
- Prometheus Ingress와 외부 DNS 레코드 없음
- DNS 적용 시 `dev-web-dns` Plan `No changes`
- DNS 적용 시 `dev-management-dns` Plan `No changes`
- `leechs.shop` HTTP Redirect와 HTTPS 200
- Grafana HTTP Redirect 301, Health/Login 200, 비인증 API 401
- Tailscale 없이 Grafana 접속 가능, Prometheus는 ClusterIP/port-forward 전용
