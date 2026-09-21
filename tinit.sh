#!/usr/bin/env bash
# Dev 환경 Terraform Backend 초기화 (프로젝트 루트에서 실행)
# 사용: AWS_PROFILE=petflow-terraform-<사용자> ./tinit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"

for command_name in aws terraform; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "[tinit] ${command_name} 명령이 필요합니다." >&2
    exit 1
  }
done

# shellcheck source=scripts/lib/terraform-auth.sh
source "${SCRIPT_DIR}/scripts/lib/terraform-auth.sh"
petflow_validate_terraform_identity "tinit"

if [[ ! -f "${TERRAFORM_DIR}/backend.hcl" ]]; then
  echo "[tinit] backend.hcl 파일이 없습니다." >&2
  echo "        cp backend.hcl.example backend.hcl 로 복사한 뒤 실제 값을 입력해주세요." >&2
  exit 1
fi

terraform -chdir="${TERRAFORM_DIR}" init -backend-config=backend.hcl
