#!/usr/bin/env bash
# Dev 환경 Terraform 초기화 (프로젝트 루트에서 실행)
#
# 사용:
#   ./tinit.sh
#
# 전제:
#   - terraform/environments/dev/backend.hcl 존재
#   - terraform/environments/dev/terraform.tfvars 존재
#   - AWS 자격 증명 설정 완료 (aws configure 또는 환경변수)
#
# 이 스크립트는 terraform/environments/dev 로 이동해서
# terraform init -backend-config=backend.hcl 을 실행한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"

cd "${TERRAFORM_DIR}"

if ! command -v terraform >/dev/null 2>&1; then
  echo "[tinit] Terraform이 설치되어 있지 않습니다."
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "[tinit] AWS CLI가 설치되어 있지 않습니다."
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[tinit] AWS 인증 정보를 확인해주세요."
  exit 1
fi

if [ ! -f "backend.hcl" ]; then
  echo "[tinit] backend.hcl 파일이 없습니다."
  echo "        cp backend.hcl.example backend.hcl 로 복사한 뒤 실제 값을 입력해주세요."
  exit 1
fi

terraform init -backend-config=backend.hcl
