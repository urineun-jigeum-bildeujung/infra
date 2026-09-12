# Terraform Output 사용 가이드

이 문서는 Petflow DEV 인프라의 비민감 전달 값을 팀별로 조회하는 방법을 정리한다.
기준 Root Module은 `terraform/environments/dev`이며, 실제 값의 Source of Truth는
S3 Remote State다.

## 조회 전 준비

프로젝트 루트에서 대상 계정을 확인하고 Backend를 초기화한다.

```bash
export AWS_PROFILE=ujibil2
aws sts get-caller-identity
./tinit.sh
```

예상 AWS Account는 `297165773875`, Region은 `ap-northeast-2`다.

## 기본 조회 명령

```bash
# 사람이 읽는 전체 목록
terraform -chdir=terraform/environments/dev output

# 자동화 도구가 처리할 JSON
terraform -chdir=terraform/environments/dev output -json

# 개별 값
terraform -chdir=terraform/environments/dev output -raw eks_cluster_name
terraform -chdir=terraform/environments/dev output -raw vpc_id
terraform -chdir=terraform/environments/dev output -json ecr_repository_urls
terraform -chdir=terraform/environments/dev output -json s3_bucket_names
```

`-raw`는 문자열 Output에만 사용한다. List, Map, Object는 `-json`으로 조회한다.

## Network / EKS

| Output | 형태 | 용도 |
|---|---|---|
| `aws_region` | string | AWS CLI, Helm, Controller Region |
| `vpc_id` | string | VPC 연동과 AWS 리소스 조회 |
| `vpc_cidr` | string | Tailscale 광고 Route와 Network 정책 |
| `public_subnet_ids` | list | Internet-facing Load Balancer Subnet |
| `private_subnet_ids` | list | EKS Node, Internal Load Balancer Subnet |
| `nat_gateway_public_ips` | list | 외부 서비스 outbound allowlist |
| `s3_gateway_endpoint_id` | string | Private S3 경로 확인 |
| `eks_cluster_name` | string | kubeconfig 및 Controller 설정 |
| `eks_cluster_endpoint` | string | EKS API Endpoint 확인 |
| `eks_cluster_version` | string | Kubernetes 호환성 확인 |
| `eks_node_group_name` | string | Managed Node Group/ASG 운영 조회 |
| `eks_cluster_security_group_id` | string | Karpenter Security Group Discovery |

EKS 재생성 후 Endpoint가 바뀌므로 기존 kubeconfig를 항상 갱신한다.

```bash
cluster_name="$(terraform -chdir=terraform/environments/dev output -raw eks_cluster_name)"
region="$(terraform -chdir=terraform/environments/dev output -raw aws_region)"

aws eks update-kubeconfig \
  --name "${cluster_name}" \
  --region "${region}" \
  --alias petflow-dev
```

## ECR / S3 / DNS

| Output | 형태 | 주요 사용자 |
|---|---|---|
| `ecr_repository_urls` | map | Backend CI, Jenkins, GitOps values |
| `s3_bucket_names` | map | Backend, Web, CNPG |
| `s3_bucket_arns` | map | IAM 정책 검토 |
| `route53_zone_id` | string | DNS Record 연결 |
| `route53_name_servers` | list | 도메인 등록기관 위임 확인 |
| `acm_certificate_arn` | string | ALB HTTPS Listener/Ingress |

ECR Map key는 `auth-service`, `member-service`, `order-service`,
`payment-service`, `product-service`, `notification-service`, `review-service`다.
S3 Map key는 `static`, `product-images`, `uploads`, `db-backups`다.

## IAM / Platform 연동

| Output | 용도 |
|---|---|
| `eks_cluster_role_arn` | EKS Control Plane Role 확인 |
| `eks_node_role_arn` | Managed Node Role 확인 |
| `eks_ebs_csi_role_arn` | EBS CSI Pod Identity 확인 |
| `alb_controller_role_arn` | AWS Load Balancer Controller 권한 확인 |
| `alb_controller_service_account` | Controller Namespace/ServiceAccount 계약 |
| `karpenter_controller_role_arn` | Karpenter Pod Identity 확인 |
| `karpenter_node_role_name` | EC2NodeClass `spec.role` |
| `karpenter_discovery_value` | Subnet/SG Discovery Tag |
| `jenkins_kaniko_role_arn` | Jenkins Agent의 ECR 권한 확인 |
| `jenkins_ecr_policy_arn` | Jenkins ECR Policy 확인 |
| `cnpg_backup_role_arn` | CNPG S3 Backup 권한 확인 |
| `cnpg_backup_destination_path` | Barman ObjectStore 경로 |
| `cnpg_backup_service_account` | CNPG Pod Identity 계약 |

## Tailscale Router

| Output | 용도 |
|---|---|
| `tailscale_router_instance_id` | SSM Session Manager 접속 |
| `tailscale_router_private_ip` | VPC 내부 Router 주소 확인 |
| `tailscale_router_security_group_id` | EKS API 접근 규칙 확인 |

EC2 ID와 Private IP는 destroy/apply 재생성 시 변경된다. Tailscale IP도 Tailnet이
할당하므로 Terraform Output으로 관리하지 않는다. 항상 Terraform과 `tailscale status`로
현재 값을 조회한다.

## 팀별 최소 조회 항목

| 팀 | 필요한 Output |
|---|---|
| Infra | Network/EKS/IAM/Tailscale 전체 |
| CloudNative | `aws_region`, `eks_cluster_name`, Subnet, Storage, Platform IAM/CNPG 계약 |
| Backend | `ecr_repository_urls`, `s3_bucket_names`, Jenkins IAM 계약 |
| Web | `s3_bucket_names`, `route53_zone_id`, `acm_certificate_arn` |

## 출력 금지 정보

다음 값은 Terraform Output이나 Git 문서에 넣지 않는다.

- AWS Access Key/Secret Key
- Tailscale OAuth Secret
- GitHub Token
- DB Password
- 애플리케이션 API Key
- kubeconfig와 인증 Token

Secret은 AWS Secrets Manager 또는 승인된 Secret 관리 경로에서만 전달한다. 부득이하게
Output으로 다루는 값은 `sensitive = true`를 사용하더라도 State에는 저장될 수 있으므로,
가능하면 Output 자체를 만들지 않는다.
