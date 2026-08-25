#!/usr/bin/env bash
# Dev 환경 Terraform 변경 계획 확인 스크립트
# 포맷 정리, 문법 검증, 변경사항 미리보기를 순서대로 수행한다.
#
# 사용 예:
#   ./scripts/dev/plan.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../../terraform/environments/dev"

cd "${TERRAFORM_DIR}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS 인증 정보를 확인해주세요."
  exit 1
fi

terraform fmt -recursive
terraform validate
terraform plan
