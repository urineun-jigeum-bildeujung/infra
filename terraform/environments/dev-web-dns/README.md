# DEV Web DNS

Kubernetes AWS Load Balancer Controller가 만든 DEV Web Public ALB를
`leechs.shop` Route53 A Alias에 연결한다.

이 스택은 ALB가 존재해야 Plan/Apply할 수 있으므로 코어 DEV 인프라와 별도
State를 사용하며, GitOps에서 Web Ingress가 동기화된 뒤 실행한다. ALB DNS와
Canonical Hosted Zone ID는 `data.aws_lb.web`으로 조회하며 하드코딩하지 않는다.

```bash
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

기존 Alias를 처음 State에 편입할 때만 다음 import를 먼저 실행한다.

```bash
terraform import \
  aws_route53_record.web \
  Z10307303I03OBEI24QKC_leechs.shop_A
```

Hosted Zone ID는 환경마다 다를 수 있으므로 위 import ID를 그대로 재사용하지
말고 `aws route53 list-hosted-zones-by-name` 결과를 확인한다. 이 스택과 Alias는
일반 DEV destroy 대상에 포함하지 않는다.
