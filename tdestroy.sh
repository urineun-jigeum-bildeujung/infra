#!/usr/bin/env bash
# Dev 환경 Terraform 리소스 삭제 (프로젝트 루트에서 실행, --auto-approve)
#
# ⚠️ 확인 프롬프트 없이 즉시 destroy 되므로 매우 신중히 실행할 것.
#    실행 전 반드시 어느 계정 / 어느 리전인지 확인한다.
#
# 이 스크립트는 오직 terraform/environments/dev 만 대상으로 한다.
# Bootstrap 스택 (state-backend, terraform-access) 은 이 스크립트로 삭제되지 않는다.
# → State S3 Bucket 과 Terraform 실행 Role 은 그대로 유지된다.
#
# 사용:
#   ./tdestroy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"

cd "${TERRAFORM_DIR}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[tdestroy] AWS 인증 정보를 확인해주세요."
  exit 1
fi

CALLER_INFO="$(aws sts get-caller-identity --output text --query 'Account')"
echo "[tdestroy] 대상 AWS Account: ${CALLER_INFO}"
echo "[tdestroy] 대상 스택       : terraform/environments/dev"
echo "[tdestroy] 3초 후 destroy 를 시작합니다. 취소하려면 지금 Ctrl+C 를 누르세요."
sleep 3

terraform destroy --auto-approve
