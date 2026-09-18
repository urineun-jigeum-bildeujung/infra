# DEV Management DNS

Kubernetes AWS Load Balancer Controller가 만든 `petflow-dev-management`
Internal ALB를 다음 Route53 A Alias에 연결한다.

- `grafana.leechs.shop`
- `prometheus.leechs.shop`

이 스택은 GitOps가 두 Ingress와 Internal ALB를 만든 이후에만 Plan/Apply할 수
있으므로 코어 DEV 및 Web DNS와 별도 State를 사용한다. ALB DNS, Canonical
Hosted Zone ID와 현재 EKS VPC는 AWS Data Source로 조회하며 하드코딩하지 않는다.

Public Hosted Zone의 이름은 외부에서도 조회될 수 있지만 Alias가 반환하는 주소는
Private IP다. ALB inbound CIDR도 `10.0.0.0/20`으로 제한하므로 Tailscale 또는
VPC 경로 없이 접속할 수 없다.

```bash
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Alias는 일반 DEV destroy 대상에 포함하지 않는다. ALB가 재생성되면
`tapply.sh`가 이 스택을 적용해 새 ALB DNS로 갱신한다. 수동 Route53 UPSERT는
하지 않는다.
