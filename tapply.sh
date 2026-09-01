#!/usr/bin/env bash
# Dev 환경 Terraform 적용 (프로젝트 루트에서 실행, --auto-approve)
# fmt → validate → apply --auto-approve 순으로 수행한다.
#
# ⚠️ 확인 프롬프트 없이 즉시 apply 되므로 실행 전에 tplan.sh 로 계획을 검토하는 것을 권장한다.
#
# 사용:
#   ./tplan.sh   # 먼저 계획 확인
#   ./tapply.sh  # 이후 적용

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"

cd "${TERRAFORM_DIR}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[tapply] AWS 인증 정보를 확인해주세요."
  exit 1
fi

terraform fmt -recursive
terraform validate
terraform apply --auto-approve
