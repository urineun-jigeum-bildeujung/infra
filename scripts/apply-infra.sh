#!/usr/bin/env bash
# tapply.sh가 내부적으로 호출하는 DEV Terraform 전용 적용 스크립트다.
# fmt → validate → apply --auto-approve → CNPG PostgreSQL 이미지 push 순으로 수행한다.
#
# 팀원은 이 파일을 직접 실행하지 않고 루트의 tapply.sh를 사용한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform/environments/dev"
if [[ "${PETFLOW_INTERNAL_ORCHESTRATOR:-false}" != "true" ]]; then
  echo "[apply-infra] 직접 실행하지 말고 AWS_PROFILE=<profile> ./tapply.sh를 사용하세요." >&2
  exit 1
fi


cd "${TERRAFORM_DIR}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[apply-infra] AWS 인증 정보를 확인해주세요."
  exit 1
fi

terraform fmt -recursive
terraform validate
terraform apply --auto-approve

# ArgoCD가 CNPG Cluster를 동기화하기 전에 pg_bigm 포함 PostgreSQL 이미지를 준비한다.
# ECR Repository는 위 Terraform apply에서 다른 서비스 Repository와 함께 생성된다.
"${SCRIPT_DIR}/build-postgres-image.sh"
