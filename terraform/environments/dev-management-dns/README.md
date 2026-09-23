# DEV Observability DNS

기존 `dev-management-dns` State 주소를 유지하면서 접근 정책을 전환한다.

- `grafana.leechs.shop`: 기존 `petflow-dev-public` ALB의 Route53 A Alias
- `prometheus.leechs.shop`: 리소스를 제거해 외부 DNS를 제공하지 않음

디렉터리 이름과 Backend State는 이전 Internal ALB 구성에서 생성한 Alias를 안전하게
업데이트·삭제하기 위해 유지한다. ALB DNS와 Canonical Hosted Zone ID는 `data.aws_lb.public`으로
조회하며 하드코딩하지 않는다.

```bash
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

첫 전환 Plan의 허용 변경은 `aws_route53_record.grafana`의 in-place update와
`aws_route53_record.prometheus`의 delete뿐이다. 이후 Plan은 `No changes`여야 한다.
`tapply.sh`는 Grafana Ingress와 Target Health를 먼저 확인한 다음 이 State를 적용한다.

Prometheus UI가 필요하면 외부 DNS 대신 다음 포트포워딩을 사용한다.

```bash
kubectl --context petflow-dev -n observability port-forward \
  svc/kube-prometheus-stack-prometheus 9090:9090
```
