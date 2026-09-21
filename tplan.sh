#!/usr/bin/env bash
# Dev 환경 Terraform 변경 계획 확인 (프로젝트 루트에서 실행)
# fmt → validate → plan 순으로 수행한다.
# 사용: AWS_PROFILE=petflow-terraform-<사용자> ./tplan.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"

for command_name in aws terraform; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "[tplan] ${command_name} 명령이 필요합니다." >&2
    exit 1
  }
done

# shellcheck source=scripts/lib/terraform-auth.sh
source "${SCRIPT_DIR}/scripts/lib/terraform-auth.sh"
petflow_validate_terraform_identity "tplan"

terraform -chdir="${TERRAFORM_DIR}" fmt -recursive
terraform -chdir="${TERRAFORM_DIR}" validate
terraform -chdir="${TERRAFORM_DIR}" plan
