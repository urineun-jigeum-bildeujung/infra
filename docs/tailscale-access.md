# Tailscale 기반 AWS VPC 관리자 접근

## 목적

일반 사용자 트래픽과 관리자 트래픽을 분리하고, EKS API와 내부 관리 서비스에 인터넷 공개 없이 접근하기 위해 AWS 전용 Tailscale Subnet Router를 사용한다.

```text
관리자 PC / VMware
        │
        ▼
기존 Tailscale Tailnet
        │
        ▼
petflow-dev-tailscale-router
        │ advertise 10.0.0.0/20
        ▼
AWS VPC / EKS Private API / 내부 관리 서비스
```

기존 Tailnet의 `mgmt` 장비는 변경하거나 재사용하지 않는다.

## Terraform 구성

`modules/tailscale`은 다음 리소스를 관리한다.

- Private Subnet의 Amazon Linux 2023 `t3.micro` EC2
- Public IP와 inbound 규칙이 없는 전용 Security Group
- EKS Private API TCP 443 접근용 Security Group 참조 규칙
- EC2 IAM Role과 Instance Profile
- `AmazonSSMManagedInstanceCore` 정책 연결
- 암호화된 8GiB gp3 root EBS
- IMDSv2 강제
- Tailscale 설치와 IPv4 forwarding 활성화 User Data

Tailscale Auth Key는 Terraform 변수, User Data, State에 저장하지 않는다. Tailnet 로그인과 Route 승인은 인스턴스 생성 후 수동으로 수행한다.

초기 구성은 Tailscale의 기본 SNAT을 사용하므로 EC2의 `source_dest_check`를 유지한다. SNAT을 비활성화하는 구조로 바꿀 때만 AWS Route Table과 source/destination check를 다시 설계한다.

## 1. Terraform 적용

프로젝트 루트에서 실행한다.

```bash
cd ~/project/tong-p/infra
export AWS_PROFILE=ujibil2

aws sts get-caller-identity
./tinit.sh
terraform -chdir=terraform/environments/dev test -filter=tests/tailscale.tftest.hcl
./tplan.sh
```

Plan에서 기존 리소스의 삭제 또는 교체가 없고 Tailscale Router 관련 리소스만 추가되는지 확인한 뒤 적용한다.

```bash
./tapply.sh
```

출력값을 확인한다.

```bash
terraform -chdir=terraform/environments/dev output tailscale_router_instance_id
terraform -chdir=terraform/environments/dev output tailscale_router_private_ip
```

## 2. SSM 등록 확인과 접속

```bash
ROUTER_ID="$(terraform -chdir=terraform/environments/dev output -raw tailscale_router_instance_id)"

aws ssm describe-instance-information \
  --region ap-northeast-2 \
  --filters "Key=InstanceIds,Values=${ROUTER_ID}" \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Platform:PlatformName}' \
  --output table
```

`PingStatus=Online`이 된 뒤 접속한다.

```bash
aws ssm start-session \
  --target "${ROUTER_ID}" \
  --region ap-northeast-2
```

로컬에서 Session Manager Plugin 오류가 나면 AWS 공식 Session Manager Plugin을 먼저 설치해야 한다.

## 3. Router 초기 상태 확인

SSM 세션 안에서 실행한다.

```bash
sudo cloud-init status --wait
sudo systemctl status tailscaled --no-pager
sudo sysctl net.ipv4.ip_forward
tailscale version
```

정상 기준:

- Cloud-init: `status: done`
- tailscaled: `active (running)`
- `net.ipv4.ip_forward = 1`

설치 실패 시 다음 로그를 확인한다.

```bash
sudo tail -n 200 /var/log/cloud-init-output.log
sudo journalctl -u tailscaled --no-pager -n 100
```

## 4. Tailnet 등록과 Route 광고

SSM 세션에서 제공된 헬퍼를 실행한다.

```bash
sudo petflow-tailscale-up
```

이는 다음 명령과 같다.

```bash
sudo tailscale up \
  --hostname=petflow-dev-tailscale-router \
  --advertise-routes=10.0.0.0/20
```

출력된 인증 URL을 브라우저에서 열어 기존 Tailnet에 로그인한다. Auth Key를 코드나 셸 기록에 넣지 않는다.

## 5. Tailscale Admin Console

기존 `mgmt` 장비는 건드리지 않고 신규 장비만 확인한다.

- Machine: `petflow-dev-tailscale-router`
- Advertised subnet: `10.0.0.0/20`
- Subnet Route 승인
- 필요한 관리자 사용자/그룹만 Route를 사용할 수 있도록 Tailnet ACL 검토

Router를 재생성하면 이전 Device Entry를 직접 제거하고 신규 Route를 다시 승인해야 한다.

## 6. 관리자 PC / VMware 검증

같은 Tailnet에 연결된 클라이언트에서 실행한다.

```bash
tailscale status
tailscale ping petflow-dev-tailscale-router
```

VPC DNS Resolver와 EKS Endpoint를 확인한다.

```bash
EKS_ENDPOINT="$(aws eks describe-cluster \
  --name petflow-eks \
  --region ap-northeast-2 \
  --query 'cluster.endpoint' \
  --output text)"
EKS_HOST="${EKS_ENDPOINT#https://}"

dig @10.0.0.2 "${EKS_HOST}"
```

응답이 VPC 내부 주소로 반환되고 Tailscale 연결을 끊었을 때 동일한 사설 경로를 사용할 수 없어야 한다.

## 7. kubectl / k9s 검증

```bash
export AWS_PROFILE=ujibil2

aws eks update-kubeconfig \
  --name petflow-eks \
  --region ap-northeast-2 \
  --alias petflow-dev

kubectl --context petflow-dev get nodes
kubectl --context petflow-dev get pods -A
k9s --context petflow-dev
```

목표는 Worker Node 2대가 `Ready`이고 전체 필수 Add-on Pod가 `Running`인 것이다.

EKS Endpoint 호스트가 클라이언트의 일반 DNS에서 Public IP로 해석된다면 Public Endpoint를 끄기 전에 VPC DNS를 사용할 수 있는 Route53 Resolver 또는 Split DNS 구성을 먼저 마련한다.

## 8. 관리 서비스 접근

Tailscale은 ClusterIP를 PC에 직접 라우팅하지 않는다. 1차 접근은 EKS Private API를 통한 `kubectl port-forward`를 사용한다.

```bash
# Argo CD
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Grafana: 실제 Service 이름 확인 후 사용
kubectl -n monitoring get svc
kubectl -n monitoring port-forward svc/<grafana-service> 3000:80

# Jenkins
kubectl -n jenkins get svc
kubectl -n jenkins port-forward svc/<jenkins-service> 8081:8080

# CNPG PostgreSQL
kubectl -n database port-forward svc/petflow-db-rw 5432:5432
```

CNPG 5432와 Jenkins, Argo CD, Grafana 관리 화면을 Public Internet에 직접 노출하지 않는다.

## 9. EKS Public Endpoint 제한

이번 1차 Terraform 변경에서는 Public Endpoint를 끄지 않는다. 다음 검증을 모두 통과한 뒤 별도 변경으로 진행한다.

- Subnet Route 승인 완료
- PC와 VMware에서 VPC 사설 경로 확인
- EKS Private Endpoint DNS 확인
- `kubectl get nodes`, `kubectl get pods -A`, `k9s` 성공
- 장애 시 사용할 SSM 접근 확인

중간 단계에서는 관리자 공인 IP CIDR로 제한하고, 최종적으로 다음 값을 적용한다.

```hcl
eks_endpoint_public_access  = false
eks_endpoint_private_access = true
```

변경 전에는 반드시 Plan을 확인하고, 현재 접속 세션과 별도로 두 번째 터미널에서 Private API 접근을 재검증한다.

## 10. Destroy와 수동 정리

Router는 DEV 인프라 생명주기를 따르므로 `./tdestroy.sh` 대상이다. State, Route53 Hosted Zone, 애플리케이션 S3 버킷은 기존 정책대로 보존된다.

Destroy 이후 Tailscale Admin Console의 `petflow-dev-tailscale-router` Device Entry는 Terraform이 관리하지 않으므로 직접 삭제한다.
