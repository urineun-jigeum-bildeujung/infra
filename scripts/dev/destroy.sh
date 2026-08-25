#!/usr/bin/env bash
# Dev 환경 Terraform 삭제 스크립트
# 반복적인 테스트를 위해 Dev 환경 리소스를 정리한다.
#
# 사용 예:
#   ./scripts/dev/destroy.sh
#
# 주의:
#   이 스크립트는 Dev 환경 리소스만 삭제한다.
#   Terraform State 저장용 S3 Bucket 은 terraform/bootstrap/state-backend 에서 별도로 관리하며,
#   이 스크립트로는 삭제되지 않는다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../../terraform/environments/dev"

cd "${TERRAFORM_DIR}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS 인증 정보를 확인해주세요."
  exit 1
fi

echo "DEV 인프라 삭제 계획을 확인합니다."

terraform plan -destroy

echo
echo "DEV 인프라를 삭제합니다."

terraform destroy
