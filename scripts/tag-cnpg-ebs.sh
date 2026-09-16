#!/usr/bin/env bash
# 기존 CNPG PVC의 EBS에 AWS Backup 선택 태그를 한 번 부여한다.
# 새 PVC는 GitOps gp3-cnpg StorageClass가 같은 태그를 자동으로 부여한다.

set -euo pipefail

EXPECTED_AWS_ACCOUNT_ID="297165773875"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-petflow-eks}"
KUBE_CONTEXT="${KUBE_CONTEXT:-petflow-dev}"
CNPG_NAMESPACE="database"
CNPG_CLUSTER="petflow-db"
BACKUP_TAG_KEY="PetflowBackup"
BACKUP_TAG_VALUE="petflow-cnpg"
DATA_CLASS_TAG_VALUE="cnpg-data"
APPLY=false

if [[ "${1:-}" == "--apply" ]]; then
  APPLY=true
elif [[ -n "${1:-}" ]]; then
  echo "사용법: $0 [--apply]" >&2
  exit 1
fi

for command_name in aws kubectl; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "[tag-cnpg-ebs] ${command_name} 명령이 필요합니다." >&2
    exit 1
  fi
done

caller_account="$(aws sts get-caller-identity --query Account --output text)"
if [[ "${caller_account}" != "${EXPECTED_AWS_ACCOUNT_ID}" ]]; then
  echo "[tag-cnpg-ebs] 잘못된 AWS Account입니다: ${caller_account}" >&2
  exit 1
fi

expected_endpoint="$(aws eks describe-cluster \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER_NAME}" \
  --query 'cluster.endpoint' --output text)"
context_cluster="$(kubectl config view --context "${KUBE_CONTEXT}" --minify \
  -o jsonpath='{.contexts[0].context.cluster}')"
context_endpoint="$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${context_cluster}')].cluster.server}")"

if [[ -z "${context_endpoint}" || "${context_endpoint}" != "${expected_endpoint}" ]]; then
  echo "[tag-cnpg-ebs] kube context가 ${EKS_CLUSTER_NAME} endpoint와 일치하지 않습니다." >&2
  exit 1
fi

ready_instances="$(kubectl --context "${KUBE_CONTEXT}" get cluster "${CNPG_CLUSTER}" \
  --namespace "${CNPG_NAMESPACE}" -o jsonpath='{.status.readyInstances}')"
if [[ ! "${ready_instances}" =~ ^[0-9]+$ || "${ready_instances}" -lt 2 ]]; then
  echo "[tag-cnpg-ebs] Ready CNPG instance가 2개 미만입니다: ${ready_instances:-unknown}" >&2
  exit 1
fi

mapfile -t pvc_names < <(
  kubectl --context "${KUBE_CONTEXT}" get pvc --namespace "${CNPG_NAMESPACE}" \
    -l "cnpg.io/cluster=${CNPG_CLUSTER}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)

if [[ "${#pvc_names[@]}" -lt 2 ]]; then
  echo "[tag-cnpg-ebs] ${CNPG_CLUSTER} PVC가 2개 미만입니다." >&2
  exit 1
fi

for pvc_name in "${pvc_names[@]}"; do
  pv_name="$(kubectl --context "${KUBE_CONTEXT}" get pvc "${pvc_name}" \
    --namespace "${CNPG_NAMESPACE}" -o jsonpath='{.spec.volumeName}')"
  volume_id="$(kubectl --context "${KUBE_CONTEXT}" get pv "${pv_name}" \
    -o jsonpath='{.spec.csi.volumeHandle}')"

  if [[ ! "${volume_id}" =~ ^vol-[a-z0-9]+$ ]]; then
    echo "[tag-cnpg-ebs] EBS Volume ID가 아닙니다: pvc=${pvc_name}, volume=${volume_id}" >&2
    exit 1
  fi

  actual_namespace="$(aws ec2 describe-tags --region "${AWS_REGION}" \
    --filters "Name=resource-id,Values=${volume_id}" \
      "Name=key,Values=kubernetes.io/created-for/pvc/namespace" \
    --query 'Tags[0].Value' --output text)"
  actual_pvc="$(aws ec2 describe-tags --region "${AWS_REGION}" \
    --filters "Name=resource-id,Values=${volume_id}" \
      "Name=key,Values=kubernetes.io/created-for/pvc/name" \
    --query 'Tags[0].Value' --output text)"

  if [[ "${actual_namespace}" != "${CNPG_NAMESPACE}" || "${actual_pvc}" != "${pvc_name}" ]]; then
    echo "[tag-cnpg-ebs] EBS/PVC 소유권 태그가 일치하지 않습니다: volume=${volume_id}" >&2
    exit 1
  fi

  echo "[tag-cnpg-ebs] target pvc=${CNPG_NAMESPACE}/${pvc_name}, pv=${pv_name}, volume=${volume_id}"

  if [[ "${APPLY}" == true ]]; then
    aws ec2 create-tags --region "${AWS_REGION}" --resources "${volume_id}" --tags \
      "Key=${BACKUP_TAG_KEY},Value=${BACKUP_TAG_VALUE}" \
      "Key=DataClass,Value=${DATA_CLASS_TAG_VALUE}"
    echo "[tag-cnpg-ebs] tagged volume=${volume_id}"
  fi
done

if [[ "${APPLY}" == false ]]; then
  echo "[tag-cnpg-ebs] dry-run 완료. 검토 후 --apply로 실행하세요."
else
  echo "[tag-cnpg-ebs] 기존 ${CNPG_CLUSTER} EBS 태깅 완료"
fi
