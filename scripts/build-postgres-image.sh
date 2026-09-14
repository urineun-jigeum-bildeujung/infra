#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
EXPECTED_AWS_ACCOUNT_ID="297165773875"
ECR_REPOSITORY="petflow/postgresql-pg-bigm"
IMAGE_TAG="${IMAGE_TAG:-17.11-pg-bigm-1.2-20250903}"

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "[postgres-image] ${command_name} 명령이 필요합니다." >&2
    exit 1
  fi
}

require_command aws

caller_account_id="$(aws sts get-caller-identity --query Account --output text)"
if [[ "${caller_account_id}" != "${EXPECTED_AWS_ACCOUNT_ID}" ]]; then
  echo "[postgres-image] 잘못된 AWS Account입니다: ${caller_account_id}" >&2
  echo "[postgres-image] 예상 Account: ${EXPECTED_AWS_ACCOUNT_ID}" >&2
  exit 1
fi

if ! aws ecr describe-repositories \
  --region "${AWS_REGION}" \
  --repository-names "${ECR_REPOSITORY}" \
  >/dev/null 2>&1; then
  echo "[postgres-image] ECR Repository가 없습니다: ${ECR_REPOSITORY}" >&2
  echo "[postgres-image] bootstrap/terraform-access를 먼저 apply하세요." >&2
  exit 1
fi

registry="${caller_account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
image_uri="${registry}/${ECR_REPOSITORY}:${IMAGE_TAG}"

existing_image_count="$(aws ecr batch-get-image \
  --region "${AWS_REGION}" \
  --repository-name "${ECR_REPOSITORY}" \
  --image-ids "imageTag=${IMAGE_TAG}" \
  --query 'length(images)' \
  --output text)"

if [[ "${existing_image_count}" != "0" ]]; then
  echo "[postgres-image] 이미지가 이미 있어 build/push를 생략합니다: ${image_uri}"
  exit 0
fi

require_command docker

echo "[postgres-image] ECR 로그인: ${registry}"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${registry}"

echo "[postgres-image] CNPG PostgreSQL + pg_bigm 이미지 빌드: ${image_uri}"
docker build --pull \
  --tag "${image_uri}" \
  "${PROJECT_DIR}/images/postgresql-pg-bigm"

echo "[postgres-image] 이미지 push: ${image_uri}"
docker push "${image_uri}"
