#!/usr/bin/env bash
# Kubernetes 리소스 정리부터 Terraform DEV 인프라 삭제까지 수행하는 공개 진입점이다.

set -Eeuo pipefail

RESUME_TERRAFORM_RUN=""
case "${1:-}" in
  "") [[ $# == 0 ]] || exit 1 ;;
  --resume-terraform)
    [[ $# == 2 && $2 =~ ^[A-Za-z0-9_-]{1,40}$ ]] || {
      echo 'Usage: ./tdestroy.sh --resume-terraform <runId>' >&2; exit 1;
    }
    RESUME_TERRAFORM_RUN=$2 ;;
  *) echo 'Usage: ./tdestroy.sh [--resume-terraform <runId>]' >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_FILE="/tmp/petflow-dev-infra.lock"
CNPG_AUTO_BACKUP_SCRIPT="${SCRIPT_DIR}/scripts/backup-cnpg-before-destroy.sh"
CNPG_S3_BACKUP_SCRIPT="${SCRIPT_DIR}/scripts/cnpg-s3-backup.sh"
EXPECTED_EKS_CLUSTER_NAME="petflow-eks"

fail() {
  printf '[tdestroy] ERROR: %s\n' "$*" >&2
  exit 1
}

for command_name in aws terraform kubectl jq flock python3 helm; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "${command_name} 명령이 필요합니다."
done

python3 -c "import yaml" >/dev/null 2>&1 \
  || fail "PyYAML이 필요합니다. python3 -m pip install PyYAML로 준비하세요."

# shellcheck source=scripts/lib/terraform-auth.sh
source "${SCRIPT_DIR}/scripts/lib/terraform-auth.sh"
petflow_validate_terraform_identity "tdestroy" || exit 1

aws_region="${AWS_REGION}"
caller_account="${PETFLOW_CALLER_ACCOUNT}"

exec 9>"${LOCK_FILE}"
flock -n 9 || fail "다른 PetFlow 인프라 Apply/Destroy 작업이 실행 중입니다."

export AWS_REGION="${aws_region}"
if [[ -n "${RESUME_TERRAFORM_RUN}" ]]; then
  export PETFLOW_DESTROY_RUN_ID="${RESUME_TERRAFORM_RUN}"
  export PETFLOW_DESTROY_EVIDENCE_DIR="${SCRIPT_DIR}/.destroy-evidence"
  export PETFLOW_CNPG_BACKUP_MANIFEST="${PETFLOW_DESTROY_EVIDENCE_DIR}/${RESUME_TERRAFORM_RUN}-cnpg-backups.json"
fi
export PETFLOW_DESTROY_RUN_ID="${PETFLOW_DESTROY_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
export PETFLOW_DESTROY_EVIDENCE_DIR="${PETFLOW_DESTROY_EVIDENCE_DIR:-${SCRIPT_DIR}/.destroy-evidence}"
export PETFLOW_CNPG_BACKUP_MANIFEST="${PETFLOW_CNPG_BACKUP_MANIFEST:-${PETFLOW_DESTROY_EVIDENCE_DIR}/${PETFLOW_DESTROY_RUN_ID}-cnpg-backups.json}"
export PETFLOW_STATEFUL_BACKUP_MANIFEST="${PETFLOW_DESTROY_EVIDENCE_DIR}/${PETFLOW_DESTROY_RUN_ID}-stateful.json"

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

if [[ -n "${RESUME_TERRAFORM_RUN}" ]]; then
  echo '[tdestroy] 기존 삭제 실행의 백업을 재검증하고 Terraform 단계만 재개합니다.'
  jq -e --arg run "${RESUME_TERRAFORM_RUN}" \
    '.runId == $run and .status == "deleting"' \
    "${PETFLOW_DESTROY_EVIDENCE_DIR}/${RESUME_TERRAFORM_RUN}-maintenance.json" >/dev/null \
    || fail '삭제 단계에 진입한 동일 run의 maintenance journal이 필요합니다.'
  python3 "${SCRIPT_DIR}/scripts/stateful/control.py" verify --manifest "${PETFLOW_STATEFUL_BACKUP_MANIFEST}"
  if [[ "${eks_exists}" == true ]]; then
    # Resume skips cleanup only when its persistent storage has actually gone.
    for resource in pvc pv; do
      kubectl --context petflow-dev --request-timeout=30s get "$resource" -A -o json \
        | jq -e --arg resource "$resource" '
            ["database","redis","kafka","jenkins","observability"] as $namespaces |
            all(.items[];
              (if $resource == "pv" then .spec.claimRef.namespace else .metadata.namespace end) as $ns |
              ($namespaces | index($ns)) == null)' >/dev/null \
        || fail 'cleanup 대상 PVC/PV가 남아 있어 Terraform만 재개할 수 없습니다.'
    done
  fi
  PETFLOW_INTERNAL_ORCHESTRATOR=true "${SCRIPT_DIR}/scripts/destroy-infra.sh"
  echo '[tdestroy] Terraform 삭제 재개 완료'
  exit 0
fi

if [[ "${eks_exists}" == "true" ]]; then
  cnpg_temp_kubeconfig="$(mktemp /tmp/petflow-tdestroy-cnpg-kubeconfig.XXXXXX)"
  trap 'rm -f "${cnpg_temp_kubeconfig}"' EXIT
  aws eks update-kubeconfig --name "${EXPECTED_EKS_CLUSTER_NAME}" \
    --region "${aws_region}" --kubeconfig "${cnpg_temp_kubeconfig}" >/dev/null
  export KUBECONFIG="${cnpg_temp_kubeconfig}"
  echo "[1/4] 업무 쓰기 중단 및 CNPG/장바구니/Kafka 통합 백업 검증"
  "${SCRIPT_DIR}/scripts/stateful-backup.sh"
  echo "[2/4] 이번 실행의 통합 복원 지점 게시 완료"

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
