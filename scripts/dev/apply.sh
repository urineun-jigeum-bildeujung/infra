#!/usr/bin/env bash
# Dev 환경 Terraform 적용 스크립트
# plan 결과를 파일로 저장한 뒤 그대로 apply 하여 예상치 못한 변경이 적용되지 않도록 한다.
#
# 사용 예:
#   ./scripts/dev/apply.sh

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

terraform plan -out=tfplan
terraform apply tfplan

rm -f tfplan
