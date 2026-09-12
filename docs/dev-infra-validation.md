# DEV 인프라 검증 결과

- 검증 일자: 2026-09-12
- AWS Account: `297165773875`
- Region: `ap-northeast-2`
- 기준 브랜치: `dev` (`819f8fa`)

## Terraform

문서 작업 직전 `terraform plan -detailed-exitcode` 결과는 `No changes`였다. 실제 AWS
리소스와 Terraform 설정 사이에 변경 계획이 없었다. 이번 문서화 작업은
`eks_node_group_name` Root Output만 추가하며 AWS 리소스는 변경하지 않는다.

## EKS / Worker Node

| 확인 항목 | 결과 |
|---|---|
| Cluster | `petflow-eks`, `ACTIVE`, Kubernetes 1.35 |
| Endpoint | Public OFF, Private ON |
| Managed Node Group | `petflow-node-group`, `ACTIVE` |
| Instance Type | `m7i-flex.large` |
| Scaling | min 2 / desired 3 / max 5 |
| Worker Node | 3대 모두 `Ready`, EC2 Status Check `ok/ok` |
| 배치 AZ | `ap-northeast-2b` 1대, `ap-northeast-2d` 2대 |
| Pod | EKS 시스템 Pod 16개, 모두 Ready |

관리형 Add-on `coredns`, `kube-proxy`, `vpc-cni`, `aws-ebs-csi-driver`,
`eks-pod-identity-agent`는 모두 `ACTIVE`이고 Health issue가 없다.

현재 Argo CD와 GitOps Platform은 아직 bootstrap되지 않았다. Application/Platform Pod가
없는 것은 EKS 기반 상태이며, CloudNative 배포 후 별도 통합 검증한다.

## Network / Tailscale

| 확인 항목 | 결과 |
|---|---|
| VPC | `10.0.0.0/20`, available |
| Subnet | Public 2개, Private 2개 |
| NAT Gateway | 1개, available |
| S3 Gateway Endpoint | available |
| Tailscale Router | Private EC2, running, SSM Online |
| Subnet Route | `10.0.0.0/20`, active |
| EKS Private API | Tailscale 경로로 `/readyz` 및 kubectl 성공 |

AWS NAT Gateway 뒤의 Router 특성상 Client 연결이 DERP Relay를 사용할 수 있다. 2026-09-12
VMware 측정에서는 direct 연결이 성립하지 않았고 API 요청이 평소보다 느릴 수 있음을 확인했다.

## AWS 연동 기반

| 영역 | Terraform 상태 | Kubernetes 통합 상태 |
|---|---|---|
| Karpenter | Controller/Node IAM, Access Entry, Discovery Tag 준비 | Helm/NodePool 미배포 |
| AWS Load Balancer Controller | IAM, Pod Identity, Subnet Tag 준비 | Controller/Ingress 미배포 |
| Jenkins/Kaniko | Pod Identity, ECR Push Policy 준비 | Jenkins/Agent 미배포 |
| CNPG Backup | Pod Identity, S3 경로, EBS CSI 준비 | Operator/Cluster 미배포 |
| ECR | 서비스 Repository 7개 준비 | Image 0개 |
| S3 | static/product-images/uploads/db-backups 보존 | Workload 연결 전 |
| Route53/ACM | Hosted Zone 및 인증서 준비 | ALB/HTTPS 연결 전 |

## CloudNative 배포 후 완료 조건

1. Argo CD Application Sync/Health 확인
2. Jenkins Agent의 ECR Image Push 확인
3. CNPG PVC와 S3 Backup/Restore 확인
4. Redis/Kafka Network와 Storage 확인
5. Ingress 기반 ALB/Target Health와 Route53/ACM HTTPS 확인
6. Karpenter Scale-out/Scale-in 확인
7. Prometheus/Grafana에서 Node/Pod Capacity 확인
