# Tailscale 기반 AWS VPC 관리자 접근

## 목적

EKS API와 내부 관리 서비스를 인터넷에 공개하지 않고 Windows 관리자 PC에서 AWS VPC로 접근하기 위해 전용 Tailscale Subnet Router를 사용한다.

~~~text
Windows 관리자 PC
        │
        ▼
Tailscale Tailnet
        │
        ▼
petflow-dev-tailscale-router
        │ 10.0.0.0/20 광고
        ▼
AWS VPC / EKS Private API / 내부 관리 서비스
~~~

Router EC2는 Terraform으로 생성하며, 부팅할 때 AWS Secrets Manager의 OAuth Secret을 조회해 자동으로 Tailnet에 등록한다. Secret 값은 Terraform 코드, tfvars, User Data, State에 저장하지 않는다.

## 현재 운영 기준

- EKS Public Endpoint: 비활성화
- EKS Private Endpoint: 활성화
- Petflow Router 광고 대역: 10.0.0.0/20
- Router 식별 태그: tag:petflow-router
- Router EC2: Private Subnet, Public IP 없음, inbound Security Group 규칙 없음
- 관리자 접속: SSM Session Manager

VMware LAN과 기존 Tailnet mgmt Route가 모두 172.16.8.0/24이므로 VMware에서는 Route 수락을 끈다.

~~~bash
sudo tailscale set --accept-routes=false
~~~

VMware는 Terraform/Git/AWS CLI 작업에 사용하고, EKS Private API와 관리 서비스 접근은 Windows Tailscale 클라이언트에서 수행한다.

## 자동 인증 흐름

~~~text
terraform apply
  → Router EC2 생성
  → cloud-init에서 Tailscale 설치
  → Instance Role로 Secrets Manager Secret 조회
  → OAuth client secret으로 자동 인증
  → tag:petflow-router 적용
  → 10.0.0.0/20 광고
  → Tailnet autoApprovers가 Route 승인
~~~

OAuth Secret은 root만 읽을 수 있는 /run 임시 파일에 저장하고 인증 직후 삭제한다. cloud-init은 set -x를 사용하지 않는다. OAuth 등록은 재생성되는 서버에 맞게 ephemeral=false, preauthorized=true로 요청한다.

## Tailnet 최초 1회 설정

Access Controls의 기존 정책을 통째로 덮어쓰지 말고 다음 항목을 병합한다.

~~~json
{
  "tagOwners": {
    "tag:petflow-router": [
      "autogroup:admin"
    ]
  },
  "autoApprovers": {
    "routes": {
      "10.0.0.0/20": [
        "tag:petflow-router"
      ]
    }
  }
}
~~~

Trust credentials에서 다음 조건의 OAuth Client를 생성한다.

- 이름: petflow-dev-router
- Scope: auth_keys
- Tag: tag:petflow-router

OAuth Client가 허용받은 태그와 Router가 광고하는 태그가 일치해야 한다. 자세한 동작은 [Tailscale OAuth clients](https://tailscale.com/docs/features/oauth-clients)와 [Subnet routers](https://tailscale.com/docs/features/subnet-routers)를 참고한다.

## AWS Secrets Manager 최초 1회 설정

반드시 대상 계정이 297165773875인지 먼저 확인한다.

~~~bash
export AWS_PROFILE=ujibil2
aws sts get-caller-identity
~~~

Secret이 없을 때만 생성한다. 실제 값은 문서, Git, PR 본문, 셸 히스토리에 남기지 않는다.

~~~bash
aws secretsmanager create-secret \
  --name petflow/tailscale/oauth-secret \
  --region ap-northeast-2 \
  --secret-string '<TAILSCALE_OAUTH_SECRET>'
~~~

Terraform에는 Secret 값 대신 ARN만 설정한다.

~~~bash
aws secretsmanager describe-secret \
  --secret-id petflow/tailscale/oauth-secret \
  --region ap-northeast-2 \
  --query ARN \
  --output text
~~~

로컬 terraform/environments/dev/terraform.tfvars에 출력된 ARN을 tailscale_oauth_secret_arn 값으로 넣는다. 이 파일은 Git에서 제외된다.

Router IAM Role은 해당 ARN의 secretsmanager:GetSecretValue만 허용한다. OAuth Secret은 DEV destroy target에 포함되지 않아 Router/VPC/EKS를 삭제해도 유지된다.

## 적용

~~~bash
export AWS_PROFILE=ujibil2
terraform -chdir=terraform/environments/dev test -filter=tests/tailscale.tftest.hcl
./tplan.sh
~~~

정상 Plan 범위는 Router IAM inline policy 추가와 User Data 변경에 따른 Router EC2 교체다. EKS, Node Group, VPC, Route53, S3, ECR 또는 CNPG IAM의 교체/삭제가 나타나면 적용하지 않는다.

~~~bash
./tapply.sh
~~~

## 자동 등록 검증

Terraform output에서 새 Router ID를 확인하고 SSM으로 접속한다.

~~~bash
terraform -chdir=terraform/environments/dev output tailscale_router_instance_id

aws ssm start-session \
  --target <ROUTER_INSTANCE_ID> \
  --region ap-northeast-2
~~~

Router에서 확인한다.

~~~bash
sudo cloud-init status --long
sudo tailscale status
sudo tailscale ip -4
sudo grep -Ei 'tskey-|auth-key' /var/log/cloud-init-output.log
~~~

정상 기준:

- cloud-init status가 done
- petflow-dev-tailscale-router가 Connected
- tag:petflow-router 적용
- 10.0.0.0/20 Route 활성화
- 실제 OAuth Secret 문자열이 cloud-init 로그에 없음
- SSM에서 tailscale up 실행이나 브라우저 인증이 필요하지 않음

Windows에서 최종 검증한다.

~~~bash
tailscale ping petflow-dev-tailscale-router
kubectl --context petflow-dev get nodes
kubectl --context petflow-dev get pods -A
~~~

Tailscale을 끄면 EKS Private API 접근이 실패해야 한다.

## destroy → apply 재생성 검증

Kubernetes가 생성한 ALB Ingress와 LoadBalancer Service는 EKS API에 접근 가능한 Windows에서 먼저 정리한다. 그다음 VMware에서 DEV 인프라를 삭제하고 재생성한다.

~~~bash
AWS_PROFILE=ujibil2 ./tdestroy.sh
AWS_PROFILE=ujibil2 ./tapply.sh
~~~

재생성 후 별도 SSM 인증, 브라우저 로그인, Route 수동 승인 없이 Router와 Private 관리 경로가 복구되어야 한다.

기존 Router가 non-ephemeral 장비로 Tailnet에 남아 있다면 destroy 후 Admin Console에서 오래된 Device Entry를 정리한다.
