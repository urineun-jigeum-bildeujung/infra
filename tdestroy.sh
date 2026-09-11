#!/usr/bin/env bash
# Route53/ACM/S3/Bootstrap/OAuth Secret을 보존하고 Terraform 관리 DEV 인프라를 삭제한다.
# Kubernetes 리소스는 cleanup-k8s.sh에서 별도로 정리한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"
EXPECTED_AWS_ACCOUNT_ID="297165773875"

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "[tdestroy] ${command_name} 명령이 필요합니다." >&2
    exit 1
  fi
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
echo "[tdestroy] 보존 대상        : Bootstrap, Route53/ACM, S3 4개, Tailscale OAuth Secret"

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
  -target=module.tailscale
  -target=module.workload_iam
  -target=module.platform_iam
  -target=module.eks
  -target=module.ecr
  -target=module.iam
  -target=module.network
)

echo "[2/2] Terraform Destroy 실행"
terraform destroy --auto-approve -input=false "${destroy_targets[@]}"

echo "======================================"
echo " Terraform Destroy Completed"
echo "======================================"
echo "[tdestroy] Bootstrap, Route53/ACM, S3 4개와 Tailscale OAuth Secret은 보존했습니다."
