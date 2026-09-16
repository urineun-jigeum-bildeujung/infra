#!/usr/bin/env bash
# ECR/Route53/ACM/S3/Bootstrap/OAuth Secret/CNPG AWS Backup을 보존하고
# Terraform 관리 DEV 인프라를 삭제한다.
# Kubernetes 리소스는 cleanup-k8s.sh에서 별도로 정리한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"
EXPECTED_AWS_ACCOUNT_ID="297165773875"
EXPECTED_AWS_REGION="ap-northeast-2"

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "[tdestroy] ${command_name} 명령이 필요합니다." >&2
    exit 1
  fi
}

report_orphan_ebs() {
  local aws_region="$1"
  local orphan_count

  echo "[tdestroy] 고아 EBS 후보 조회(읽기 전용)"
  orphan_count="$(aws ec2 describe-volumes \
    --region "${aws_region}" \
    --filters \
      "Name=status,Values=available" \
      "Name=tag:KubernetesCluster,Values=petflow-eks" \
    --query 'length(Volumes[?length(Attachments)==`0`])' \
    --output text)"

  if [[ "${orphan_count}" == "0" ]]; then
    echo "[tdestroy] available/미연결 고아 EBS 후보가 없습니다."
    return
  fi

  aws ec2 describe-volumes \
    --region "${aws_region}" \
    --filters \
      "Name=status,Values=available" \
      "Name=tag:KubernetesCluster,Values=petflow-eks" \
    --query 'Volumes[?length(Attachments)==`0`].{VolumeId:VolumeId,Namespace:Tags[?Key==`kubernetes.io/created-for/pvc/namespace`].Value|[0],PVC:Tags[?Key==`kubernetes.io/created-for/pvc/name`].Value|[0],SizeGiB:Size,Created:CreateTime}' \
    --output table

  echo "[tdestroy] 고아 EBS 후보 ${orphan_count}개를 자동 삭제하지 않았습니다."
  echo "[tdestroy] 데이터 보존 여부와 현재 PV 미참조를 별도로 확인한 뒤 명시적으로 정리해주세요."
}

echo "======================================"
echo " Terraform Destroy"
echo "======================================"

require_command aws
require_command terraform

if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "[tdestroy] Terraform 디렉터리를 찾을 수 없습니다: ${TERRAFORM_DIR}" >&2
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[tdestroy] AWS 인증 정보를 확인해주세요." >&2
  exit 1
fi

caller_account="$(aws sts get-caller-identity --query Account --output text)"
if [[ "${caller_account}" != "${EXPECTED_AWS_ACCOUNT_ID}" ]]; then
  echo "[tdestroy] 잘못된 AWS Account입니다: ${caller_account}" >&2
  echo "[tdestroy] 예상 Account: ${EXPECTED_AWS_ACCOUNT_ID}" >&2
  exit 1
fi

echo "[tdestroy] 대상 AWS Account: ${caller_account}"
echo "[tdestroy] 대상 스택       : terraform/environments/dev"
echo "[tdestroy] 보존 대상        : Bootstrap, ECR, Route53/ACM, S3 4개, Tailscale OAuth Secret, CNPG AWS Backup"

cd "${TERRAFORM_DIR}"

if [[ ! -f backend.hcl ]]; then
  echo "[tdestroy] backend.hcl 파일이 없습니다." >&2
  exit 1
fi

echo "[1/2] Terraform 초기화"
terraform init -backend-config=backend.hcl -input=false

# tdestroy.sh를 단독 실행하더라도 Kubernetes Controller가 만든 외부 LB를
# 남긴 채 VPC 삭제를 시작하지 않도록 AWS API에서 한 번 더 확인한다.
vpc_id="$(terraform output -raw vpc_id 2>/dev/null || true)"
aws_region="$(terraform output -raw aws_region 2>/dev/null || true)"

if [[ -n "${vpc_id}" && -n "${aws_region}" ]]; then
  if [[ "${aws_region}" != "${EXPECTED_AWS_REGION}" ]]; then
    echo "[tdestroy] 잘못된 AWS Region입니다: ${aws_region}" >&2
    echo "[tdestroy] 예상 Region: ${EXPECTED_AWS_REGION}" >&2
    exit 1
  fi

  v2_load_balancer_count="$(aws elbv2 describe-load-balancers --region "${aws_region}" --query "length(LoadBalancers[?VpcId=='${vpc_id}'])" --output text)"
  classic_load_balancer_count="$(aws elb describe-load-balancers --region "${aws_region}" --query "length(LoadBalancerDescriptions[?VPCId=='${vpc_id}'])" --output text)"

  if ((v2_load_balancer_count > 0 || classic_load_balancer_count > 0)); then
    echo "[tdestroy] DEV VPC에 외부 Load Balancer가 남아 있어 Destroy를 중단합니다." >&2
    echo "[tdestroy] cleanup-k8s.sh를 먼저 실행해주세요." >&2
    echo "[tdestroy] ALB/NLB: ${v2_load_balancer_count}, Classic ELB: ${classic_load_balancer_count}" >&2
    exit 1
  fi
fi

destroy_targets=(
  # module.ebs_backup은 EKS/PVC 삭제 뒤에도 Recovery Point를 보존하기 위해 제외한다.
  -target=module.tailscale
  -target=module.workload_iam
  -target=module.platform_iam
  -target=module.eks
  -target=module.iam
  -target=module.network
)

echo "[2/2] Terraform Destroy 실행"
terraform destroy --auto-approve -input=false "${destroy_targets[@]}"

if [[ -n "${aws_region}" ]]; then
  report_orphan_ebs "${aws_region}"
else
  echo "[tdestroy] AWS Region을 확인하지 못해 고아 EBS 후보 보고를 건너뜁니다." >&2
fi

echo "======================================"
echo " Terraform Destroy Completed"
echo "======================================"
echo "[tdestroy] Bootstrap, ECR, Route53/ACM, S3 4개, Tailscale OAuth Secret과 CNPG AWS Backup은 보존했습니다."
