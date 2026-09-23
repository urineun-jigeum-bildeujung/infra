# Tailscale Router SSM Persistent State 운영 Runbook

## 목적과 고정 계약

DEV Tailscale Subnet Router EC2는 삭제·재생성할 수 있지만 Tailnet Machine Identity는 동일하게 유지한다.

| 항목 | 값 |
|---|---|
| AWS 계정 | `297165773875` |
| Region | `ap-northeast-2` |
| Parameter | `/petflow/dev/tailscale/router-state` |
| Type | `SecureString` |
| 생성 요청 Tier | `Intelligent-Tiering` (현재 저장 결과: `Standard`) |
| Router 이름 | `petflow-dev-tailscale-router` |
| 광고 Route | `10.0.0.0/20` |

Terraform은 Parameter의 이름과 ARN 및 Router IAM 최소 권한만 관리한다. 실제 Parameter 생성과 값 갱신은 `tailscaled --state=arn:aws:ssm:...`가 담당한다. State 값은 Terraform State, Git, User Data, 로그에 저장하지 않는다.

한 Parameter를 두 Router가 동시에 사용하면 안 된다.

## 실제 적용 결과 (2026-09-14)

| 항목 | 결과 |
|---|---|
| Migration Status | `Completed` |
| Old EC2 | `i-077982c88cd65833c` (`terminated`) |
| New EC2 | `i-03f9ad3b80b018373` (`running`) |
| New Private IP | `10.0.7.140` |
| Tailscale Device | `petflow-dev-tailscale-router-3` |
| Tailscale IP | `100.69.91.62` |
| SSM Parameter | `/petflow/dev/tailscale/router-state` |
| Parameter metadata | `SecureString`, Version `1`, Tier `Standard` |
| EKS Private API | `/readyz` = `ok` |
| Final Terraform Plan | `No changes` |

Router replacement 결과는 `1 added, 0 changed, 1 destroyed`였다. 새 EC2의
AWS System/Instance Status, SSM Agent, cloud-init, `tailscaled`가 모두 정상이며,
실행 인자에서 정확한 SSM State ARN 사용을 확인했다. 기존 Device와 Tailscale
IP가 유지됐고 새로운 `router-N` Device나 OAuth 재등록은 발생하지 않았다.
State와 인증정보 값은 조회하거나 기록하지 않았다.

`Intelligent-Tiering`으로 생성 요청했지만 현재 State 크기에 따라 실제 Parameter
Tier는 `Standard`로 선택됐다. Version `1`이 유지된 것은 replacement 과정에서
기존 State를 읽어 Identity를 복원했고 추가 State 변경이 없었기 때문이다.

## 안전 원칙

- 현재 Tailnet에서 Online인 Router가 마이그레이션 대상인지 먼저 확인한다.
- `/var/lib/tailscale/tailscaled.state` 내용은 출력하거나 복사해 공유하지 않는다.
- 전체 Terraform apply 전에 기존 로컬 State를 SSM에 업로드한다.
- 기존 Router와 새 Router가 같은 State로 동시에 실행되지 않게 `create_before_destroy`를 사용하지 않는다.
- State Parameter가 존재하지만 복구에 실패하면 OAuth 재등록 없이 로그와 IAM을 확인한다.
- Parameter는 DEV VPC/EKS보다 긴 Lifecycle을 가지므로 프로젝트 종료 전에는 삭제하지 않는다.

## 1. 사전 확인

~~~bash
export AWS_PROFILE=ujibil2

aws sts get-caller-identity \
  --query '{Account:Account,Arn:Arn}' \
  --output table

terraform -chdir=terraform/environments/dev output tailscale_router_instance_id
tailscale status
kubectl --context petflow-dev get --raw=/readyz
~~~

계정이 `297165773875`인지, 현재 Online 장치와 Terraform Router EC2가 같은 장치인지 확인한다.

## 2. State IAM 정책만 먼저 적용

현재 Router가 SSM에 State를 쓸 수 있도록 신규 inline policy만 먼저 적용한다. 이 단계에서 EC2를 교체하면 안 된다.

~~~bash
terraform -chdir=terraform/environments/dev plan \
  -target='module.tailscale[0].aws_iam_role_policy.tailscale_state'

terraform -chdir=terraform/environments/dev apply \
  -target='module.tailscale[0].aws_iam_role_policy.tailscale_state'
~~~

Plan 대상은 `petflow-dev-tailscale-router-state` inline policy 하나여야 한다. 정책은 다음 권한만 정확한 Parameter ARN에 허용한다.

~~~text
ssm:GetParameter
ssm:PutParameter
arn:aws:ssm:ap-northeast-2:297165773875:parameter/petflow/dev/tailscale/router-state
~~~

## 3. 기존 Router State를 SSM으로 최초 1회 마이그레이션

SSM Session Manager로 현재 Router에 접속한다.

~~~bash
ROUTER_INSTANCE_ID="$(terraform -chdir=terraform/environments/dev output -raw tailscale_router_instance_id)"

aws ssm start-session \
  --target "${ROUTER_INSTANCE_ID}" \
  --region ap-northeast-2
~~~

Router 안에서 연결 상태와 State 파일 존재 여부만 확인한다. State 내용은 출력하지 않는다.

~~~bash
sudo tailscale status
sudo test -s /var/lib/tailscale/tailscaled.state
~~~

팀원 접근 단절이 가능한 시점에 daemon을 중지하고 State를 업로드한다.

~~~bash
sudo systemctl stop tailscaled

sudo aws ssm put-parameter \
  --region ap-northeast-2 \
  --name /petflow/dev/tailscale/router-state \
  --type SecureString \
  --tier Intelligent-Tiering \
  --overwrite \
  --value file:///var/lib/tailscale/tailscaled.state
~~~

값이나 복호화 결과를 조회하지 않고 metadata만 확인한다.

~~~bash
aws ssm get-parameter \
  --region ap-northeast-2 \
  --name /petflow/dev/tailscale/router-state \
  --query 'Parameter.{Name:Name,Type:Type,Version:Version}' \
  --output table
~~~

정상 Type은 `SecureString`이다.

## 4. 현재 Router를 SSM Backend로 전환

같은 SSM Session에서 systemd override를 작성한다.

~~~bash
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
STATE_ARN="arn:aws:ssm:ap-northeast-2:${AWS_ACCOUNT_ID}:parameter/petflow/dev/tailscale/router-state"

sudo mkdir -p /etc/systemd/system/tailscaled.service.d

sudo tee /etc/systemd/system/tailscaled.service.d/10-persistent-state.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/tailscaled --state=${STATE_ARN} --socket=/run/tailscale/tailscaled.sock --port=\${PORT} \$FLAGS
EOF

sudo systemctl daemon-reload
sudo systemctl start tailscaled
~~~

State 값이 아닌 실행 인자와 연결 상태만 확인한다.

~~~bash
sudo systemctl status tailscaled --no-pager
sudo systemctl show tailscaled --property=ExecStart
sudo tailscale status
~~~

기존 Tailnet Device가 다시 Online이어야 한다. 새 `router-N`이 생기거나 기존 장치가 복구되지 않으면 전체 Terraform apply를 중단한다.

## 5. Terraform 검증과 전체 Plan

~~~bash
terraform -chdir=terraform/environments/dev fmt -recursive
terraform -chdir=terraform/environments/dev validate
terraform -chdir=terraform/environments/dev test -filter=tests/tailscale.tftest.hcl
AWS_PROFILE=ujibil2 ./tplan.sh
~~~

정상 예상 범위:

- State IAM inline policy는 이미 반영되어 변경 없음
- Tailscale Router User Data 변경으로 EC2 `-/+` 교체
- SSM State Parameter 생성/수정/삭제 없음

EKS Cluster/Node Group, VPC/Subnet/NAT, Route53/ACM/S3, ECR 또는 다른 IAM Role이 교체·삭제되면 apply하지 않는다. Router가 `+/-` 순서로 교체되거나 `create_before_destroy`가 보이면 중단한다.

## 6. 전체 Apply와 Runtime 검증

팀원 사용이 적은 시간에 실행한다.

~~~bash
AWS_PROFILE=ujibil2 ./tapply.sh
~~~

새 EC2가 SSM State를 읽어 기존 Identity로 Online 되는지 확인한다.

~~~bash
aws ssm get-parameter \
  --region ap-northeast-2 \
  --name /petflow/dev/tailscale/router-state \
  --query 'Parameter.{Name:Name,Type:Type,Version:Version}' \
  --output table

tailscale status
tailscale ping petflow-dev-tailscale-router
kubectl --context petflow-dev get nodes
kubectl --context petflow-dev get pods -A
~~~

새 Router에 SSM으로 접속해 `cloud-init status --long`, `systemctl show tailscaled --property=ExecStart`, `tailscale status`를 확인한다.

완료 조건:

- 기존 Tailnet Device가 Online
- 새 `router-N` Device가 생성되지 않음
- 실행 인자에 정확한 SSM State ARN 포함
- Parameter Type이 `SecureString`
- `10.0.0.0/20` Route 정상
- EKS Private API 접근 정상
- EKS Public Endpoint는 계속 비활성화

## 7. Destroy/Apply Lifecycle 검증

DEV destroy 후에도 다음 metadata 조회가 성공해야 한다.

~~~bash
aws ssm get-parameter \
  --region ap-northeast-2 \
  --name /petflow/dev/tailscale/router-state \
  --query 'Parameter.{Name:Name,Type:Type,Version:Version}' \
  --output table
~~~

다시 apply한 후 기존 Device가 Online 되고 팀원 설정 변경 없이 EKS 접근이 복구되어야 한다.

## 장애 복구

State가 존재하지만 Router가 Online이 아니면 OAuth 재등록이나 Parameter 삭제부터 하지 않는다.

~~~bash
sudo journalctl -u tailscaled -n 200 --no-pager
sudo systemctl show tailscaled --property=ExecStart
aws sts get-caller-identity
aws ssm get-parameter \
  --region ap-northeast-2 \
  --name /petflow/dev/tailscale/router-state \
  --query 'Parameter.{Name:Name,Type:Type,Version:Version}'
~~~

Router Role의 `ssm:GetParameter`, `ssm:PutParameter` Resource ARN을 확인한다. Tailnet에서 해당 Device 자체를 삭제했다면 기존 State만으로 복구할 수 없을 수 있다. State 삭제와 신규 OAuth 등록은 기존 Identity 복구가 불가능하다고 확정한 뒤 별도 승인으로 수행한다.

프로젝트가 완전히 종료된 경우에만 State Parameter를 수동 삭제한다.

~~~bash
aws ssm delete-parameter \
  --region ap-northeast-2 \
  --name /petflow/dev/tailscale/router-state
~~~
