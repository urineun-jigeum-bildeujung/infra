#!/usr/bin/env bash
# Dev 환경 Terraform 초기화 스크립트
# Repository 를 Clone 한 후 최초 1회 실행하며, backend.hcl / provider 갱신 시에도 다시 실행한다.
#
# 사용 예:
#   ./scripts/dev/init.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../../terraform/environments/dev"

cd "${TERRAFORM_DIR}"

if ! command -v terraform >/dev/null 2>&1; then
  echo "Terraform이 설치되어 있지 않습니다."
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "AWS CLI가 설치되어 있지 않습니다."
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS 인증 정보를 확인해주세요."
  exit 1
fi

if [ ! -f "backend.hcl" ]; then
  echo "backend.hcl 파일이 없습니다."
  echo "backend.hcl.example을 복사한 후 실제 값을 입력해주세요."
  exit 1
fi

terraform init -backend-config=backend.hcl
