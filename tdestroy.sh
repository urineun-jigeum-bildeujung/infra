#!/usr/bin/env bash
# Kubernetes 리소스 정리부터 Terraform DEV 인프라 삭제까지 수행하는 공개 진입점이다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="/tmp/petflow-dev-infra.lock"
CNPG_AUTO_BACKUP_SCRIPT="${SCRIPT_DIR}/scripts/backup-cnpg-before-destroy.sh"
CNPG_S3_BACKUP_SCRIPT="${SCRIPT_DIR}/scripts/cnpg-s3-backup.sh"
EXPECTED_EKS_CLUSTER_NAME="petflow-eks"

fail() {
  printf '[tdestroy] ERROR: %s\n' "$*" >&2
  exit 1
}

for command_name in aws terraform kubectl jq flock; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "${command_name} 명령이 필요합니다."
done

# shellcheck source=scripts/lib/terraform-auth.sh
source "${SCRIPT_DIR}/scripts/lib/terraform-auth.sh"
petflow_validate_terraform_identity "tdestroy" || exit 1

aws_region="${AWS_REGION}"
caller_account="${PETFLOW_CALLER_ACCOUNT}"

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
  cnpg_temp_kubeconfig="$(mktemp /tmp/petflow-tdestroy-cnpg-kubeconfig.XXXXXX)"
  trap 'rm -f "${cnpg_temp_kubeconfig}"' EXIT
  aws eks update-kubeconfig --name "${EXPECTED_EKS_CLUSTER_NAME}" \
    --region "${aws_region}" --kubeconfig "${cnpg_temp_kubeconfig}" >/dev/null
  echo "[1/4] CNPG base backup과 WAL을 S3에 저장하고 복원 지점 검증"
  "${CNPG_S3_BACKUP_SCRIPT}" "${cnpg_temp_kubeconfig}"

  echo "[2/4] 현재 CNPG EBS 온디맨드 Backup 생성 및 검증"
  "${CNPG_AUTO_BACKUP_SCRIPT}" --manifest "${PETFLOW_CNPG_BACKUP_MANIFEST}"

  echo "[3/4] Kubernetes LB/Persistent Storage Cleanup"
  "${SCRIPT_DIR}/cleanup-k8s.sh" --backup-manifest "${PETFLOW_CNPG_BACKUP_MANIFEST}"
else
  echo "[tdestroy] EKS Cluster가 이미 없어 CNPG Backup/Kubernetes Cleanup을 건너뜁니다."
fi

echo "[4/4] Terraform DEV Infra Destroy"
PETFLOW_INTERNAL_ORCHESTRATOR=true "${SCRIPT_DIR}/scripts/destroy-infra.sh"

echo "======================================"
echo " Full DEV Infrastructure Destroy Completed"
echo "======================================"
