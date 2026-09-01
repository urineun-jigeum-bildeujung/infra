#!/usr/bin/env bash
# Dev 환경 Terraform 변경 계획 확인 (프로젝트 루트에서 실행)
# fmt → validate → plan 순으로 수행한다.
#
# 사용:
#   ./tplan.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"

cd "${TERRAFORM_DIR}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[tplan] AWS 인증 정보를 확인해주세요."
  exit 1
fi

terraform fmt -recursive
terraform validate
terraform plan
