#!/usr/bin/env bash
# Kubernetes 리소스 정리부터 Terraform DEV 인프라 삭제까지 수행하는 공개 진입점이다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="/tmp/petflow-dev-infra.lock"
CNPG_AUTO_BACKUP_SCRIPT="${SCRIPT_DIR}/scripts/backup-cnpg-before-destroy.sh"
EXPECTED_AWS_ACCOUNT_ID="297165773875"
EXPECTED_AWS_REGION="ap-northeast-2"
EXPECTED_EKS_CLUSTER_NAME="petflow-eks"

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

eks_exists=true
eks_describe_error="$(mktemp /tmp/petflow-tdestroy-eks.XXXXXX)"
if ! aws eks describe-cluster --name "${EXPECTED_EKS_CLUSTER_NAME}" --region "${aws_region}" \
  >/dev/null 2>"${eks_describe_error}"; then
  if grep -q ResourceNotFoundException "${eks_describe_error}"; then
    eks_exists=false
  else
    cat "${eks_describe_error}" >&2
    rm -f "${eks_describe_error}"
    fail "EKS Cluster 상태를 확인하지 못했습니다."
  fi
fi
rm -f "${eks_describe_error}"

echo "======================================"
echo " Full DEV Infrastructure Destroy"
echo "======================================"
echo "[tdestroy] AWS Account: ${caller_account}"
echo "[tdestroy] AWS Region : ${aws_region}"
echo "[tdestroy] CNPG Backup 증거: ${PETFLOW_CNPG_BACKUP_MANIFEST}"

if [[ "${eks_exists}" == "true" ]]; then
  echo "[1/3] 현재 CNPG EBS 온디맨드 Backup 생성 및 검증"
  "${CNPG_AUTO_BACKUP_SCRIPT}" --manifest "${PETFLOW_CNPG_BACKUP_MANIFEST}"

  echo "[2/3] Kubernetes LB/Persistent Storage Cleanup"
  "${SCRIPT_DIR}/cleanup-k8s.sh" --backup-manifest "${PETFLOW_CNPG_BACKUP_MANIFEST}"
else
  echo "[tdestroy] EKS Cluster가 이미 없어 CNPG Backup/Kubernetes Cleanup을 건너뜁니다."
fi

echo "[3/3] Terraform DEV Infra Destroy"
PETFLOW_INTERNAL_ORCHESTRATOR=true "${SCRIPT_DIR}/scripts/destroy-infra.sh"

echo "======================================"
echo " Full DEV Infrastructure Destroy Completed"
echo "======================================"
