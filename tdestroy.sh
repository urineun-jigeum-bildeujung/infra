#!/usr/bin/env bash
# Kubernetes 리소스 정리부터 Terraform DEV 인프라 삭제까지 수행하는 공개 진입점이다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="/tmp/petflow-dev-infra.lock"
EXPECTED_AWS_ACCOUNT_ID="297165773875"
EXPECTED_AWS_REGION="ap-northeast-2"

fail() {
  printf '[tdestroy] ERROR: %s\n' "$*" >&2
  exit 1
}

for command_name in aws terraform kubectl jq flock; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "${command_name} 명령이 필요합니다."
done

[[ -n "${AWS_PROFILE:-}" ]] || fail "AWS_PROFILE을 명시해주세요. 예: AWS_PROFILE=ujibil2 ./tdestroy.sh"

aws_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region --profile "${AWS_PROFILE}" 2>/dev/null || true)}}"
[[ "${aws_region}" == "${EXPECTED_AWS_REGION}" ]] \
  || fail "잘못된 AWS Region입니다: ${aws_region:-unset} (예상: ${EXPECTED_AWS_REGION})"

caller_account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
[[ "${caller_account}" == "${EXPECTED_AWS_ACCOUNT_ID}" ]] \
  || fail "잘못된 AWS Account 또는 인증 정보입니다: ${caller_account:-unknown}"

exec 9>"${LOCK_FILE}"
flock -n 9 || fail "다른 PetFlow 인프라 Apply/Destroy 작업이 실행 중입니다."

export AWS_REGION="${aws_region}"
export PETFLOW_DESTROY_RUN_ID="${PETFLOW_DESTROY_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
export PETFLOW_DESTROY_EVIDENCE_DIR="${PETFLOW_DESTROY_EVIDENCE_DIR:-${SCRIPT_DIR}/.destroy-evidence}"
export PETFLOW_CNPG_BACKUP_MANIFEST="${PETFLOW_CNPG_BACKUP_MANIFEST:-${PETFLOW_DESTROY_EVIDENCE_DIR}/${PETFLOW_DESTROY_RUN_ID}-cnpg-backups.json}"

echo "======================================"
echo " Full DEV Infrastructure Destroy"
echo "======================================"
echo "[tdestroy] AWS Account: ${caller_account}"
echo "[tdestroy] AWS Region : ${aws_region}"
echo "[tdestroy] CNPG Backup 증거: ${PETFLOW_CNPG_BACKUP_MANIFEST}"

echo "[1/2] Kubernetes LB/Persistent Storage Cleanup"
"${SCRIPT_DIR}/cleanup-k8s.sh"

echo "[2/2] Terraform DEV Infra Destroy"
PETFLOW_INTERNAL_ORCHESTRATOR=true "${SCRIPT_DIR}/scripts/destroy-infra.sh"

echo "======================================"
echo " Full DEV Infrastructure Destroy Completed"
echo "======================================"
