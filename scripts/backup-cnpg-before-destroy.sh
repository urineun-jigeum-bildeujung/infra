#!/usr/bin/env bash
# 현재 CNPG PVC가 사용하는 EBS마다 삭제 직전 AWS Backup을 만들고
# 이번 실행 전용 schema v2 증거 Manifest를 생성한다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${REPO_DIR}/terraform/environments/dev"
BACKUP_GUARD="${SCRIPT_DIR}/cnpg-backup-guard.sh"
EXPECTED_AWS_ACCOUNT_ID="297165773875"
EXPECTED_AWS_REGION="ap-northeast-2"
EXPECTED_EKS_CLUSTER_NAME="petflow-eks"
ENVIRONMENT="dev"
CNPG_NAMESPACE="${CNPG_NAMESPACE:-database}"
CNPG_CLUSTER_NAME="${CNPG_CLUSTER_NAME:-petflow-db}"
BACKUP_POLL_INTERVAL_SECONDS="${BACKUP_POLL_INTERVAL_SECONDS:-30}"
BACKUP_TIMEOUT_SECONDS="${BACKUP_TIMEOUT_SECONDS:-3600}"
DESTROY_RUN_ID="${PETFLOW_DESTROY_RUN_ID:-}"
MANIFEST=""
TEMP_KUBECONFIG=""

log() {
  printf '[cnpg-auto-backup] %s\n' "$*"
}

fail() {
  printf '[cnpg-auto-backup] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_KUBECONFIG}" && -f "${TEMP_KUBECONFIG}" ]]; then
    rm -f "${TEMP_KUBECONFIG}"
  fi
}
trap cleanup EXIT

usage() {
  echo "Usage: backup-cnpg-before-destroy.sh --manifest ABSOLUTE_PATH" >&2
}

while (($# > 0)); do
  case "$1" in
    --manifest)
      MANIFEST="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "알 수 없는 인자입니다: $1"
      ;;
  esac
done

for command_name in aws terraform kubectl jq date realpath; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} 명령이 필요합니다."
done

[[ -n "${AWS_PROFILE:-}" ]] || fail "AWS_PROFILE을 명시해주세요."
[[ -n "${DESTROY_RUN_ID}" ]] || fail "PETFLOW_DESTROY_RUN_ID가 필요합니다."
[[ -n "${MANIFEST}" ]] || fail "--manifest가 필요합니다."
[[ "${BACKUP_POLL_INTERVAL_SECONDS}" =~ ^[1-9][0-9]*$ ]] || fail "BACKUP_POLL_INTERVAL_SECONDS는 양의 정수여야 합니다."
[[ "${BACKUP_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] || fail "BACKUP_TIMEOUT_SECONDS는 양의 정수여야 합니다."

mkdir -p "$(dirname "${MANIFEST}")"
MANIFEST="$(realpath -m "${MANIFEST}")"
[[ "${MANIFEST}" == /* ]] || fail "Manifest는 절대 경로여야 합니다."
RESUME_MANIFEST=false
[[ ! -e "${MANIFEST}" ]] || RESUME_MANIFEST=true

caller_account="$(aws sts get-caller-identity --query Account --output text)"
[[ "${caller_account}" == "${EXPECTED_AWS_ACCOUNT_ID}" ]] ||   fail "잘못된 AWS Account입니다: ${caller_account}"

cluster_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw eks_cluster_name)"
aws_region="$(terraform -chdir="${TERRAFORM_DIR}" output -raw aws_region)"
backup_vault="$(terraform -chdir="${TERRAFORM_DIR}" output -raw cnpg_ebs_backup_vault_name)"
backup_role_arn="$(terraform -chdir="${TERRAFORM_DIR}" output -raw cnpg_ebs_backup_role_arn)"

[[ "${cluster_name}" == "${EXPECTED_EKS_CLUSTER_NAME}" ]] || fail "잘못된 EKS Cluster입니다: ${cluster_name}"
[[ "${aws_region}" == "${EXPECTED_AWS_REGION}" ]] || fail "잘못된 AWS Region입니다: ${aws_region}"
[[ "${backup_role_arn}" =~ ^arn:aws:iam::${EXPECTED_AWS_ACCOUNT_ID}:role/ ]] || fail "Backup Role ARN이 올바르지 않습니다."

vault_json="$(aws backup describe-backup-vault --region "${aws_region}" --backup-vault-name "${backup_vault}" --output json)"
vault_locked="$(jq -r '.Locked // false' <<<"${vault_json}")"
vault_min_retention_days="$(jq -r '.MinRetentionDays // 0' <<<"${vault_json}")"
[[ "${vault_locked}" == "true" ]] || fail "Backup Vault Lock이 활성화되지 않았습니다: ${backup_vault}"
((vault_min_retention_days >= 7)) || fail "Backup Vault 최소 보존기간이 7일보다 짧습니다."

TEMP_KUBECONFIG="$(mktemp /tmp/petflow-cnpg-backup-kubeconfig.XXXXXX)"
aws eks update-kubeconfig --name "${cluster_name}" --region "${aws_region}" --kubeconfig "${TEMP_KUBECONFIG}" >/dev/null
KUBECTL=(kubectl --kubeconfig "${TEMP_KUBECONFIG}")
"${KUBECTL[@]}" get --raw=/readyz --request-timeout=10s >/dev/null || fail "Kubernetes API에 접근할 수 없습니다."
if [[ "${RESUME_MANIFEST}" == "false" ]]; then
  "${KUBECTL[@]}" --namespace "${CNPG_NAMESPACE}" get clusters.postgresql.cnpg.io "${CNPG_CLUSTER_NAME}" >/dev/null || fail "CNPG Cluster를 찾을 수 없습니다: ${CNPG_NAMESPACE}/${CNPG_CLUSTER_NAME}"
fi

log "[1/7] CNPG PVC/PV/EBS 조회"
pvc_json='{"items":[]}'
if ! pvc_json="$("${KUBECTL[@]}" --namespace "${CNPG_NAMESPACE}" get pvc --selector "cnpg.io/cluster=${CNPG_CLUSTER_NAME}" -o json 2>/dev/null)"; then
  if [[ "${RESUME_MANIFEST}" == "true" ]]; then
    pvc_json='{"items":[]}'
  else
    fail "CNPG PVC를 조회할 수 없습니다: ${CNPG_NAMESPACE}/${CNPG_CLUSTER_NAME}"
  fi
fi
pvc_count="$(jq '.items | length' <<<"${pvc_json}")"
if ((pvc_count == 0)); then
  if [[ "${RESUME_MANIFEST}" == "true" ]]; then
    log "현재 CNPG PVC가 없어 기존 Manifest를 기준으로 cleanup 이후 재개 여부를 검증합니다."
    bash "${BACKUP_GUARD}" verify \
      --region "${aws_region}" --vault "${backup_vault}" --manifest "${MANIFEST}" \
      --destroy-run-id "${DESTROY_RUN_ID}" --phase resume-after-kubernetes-cleanup
    log "[7/7] 기존 백업 보호 조건 재검증 완료 — cleanup/destroy 재개"
    exit 0
  fi
  fail "CNPG 볼륨이 0개입니다. 자동 Destroy를 중단합니다."
fi

resources='[]'
declare -A seen_volumes=()
mapfile -t pvc_rows < <(jq -r '.items[] | @base64' <<<"${pvc_json}")
for pvc_row in "${pvc_rows[@]}"; do
  pvc_item="$(base64 -d <<<"${pvc_row}")"
  pvc_name="$(jq -r '.metadata.name' <<<"${pvc_item}")"
  pvc_uid="$(jq -r '.metadata.uid' <<<"${pvc_item}")"
  pv_name="$(jq -r '.spec.volumeName // empty' <<<"${pvc_item}")"
  [[ -n "${pv_name}" ]] || fail "PVC에 Bound PV가 없습니다: ${CNPG_NAMESPACE}/${pvc_name}"

  pv_json="$("${KUBECTL[@]}" get pv "${pv_name}" -o json)"
  csi_driver="$(jq -r '.spec.csi.driver // empty' <<<"${pv_json}")"
  volume_id="$(jq -r '.spec.csi.volumeHandle // empty' <<<"${pv_json}")"
  [[ "${csi_driver}" == "ebs.csi.aws.com" ]] || fail "EBS CSI PV가 아닙니다: ${pv_name}"
  [[ "${volume_id}" =~ ^vol-[0-9a-f]+$ ]] || fail "EBS Volume ID를 찾지 못했습니다: ${pv_name}"
  [[ -z "${seen_volumes[${volume_id}]:-}" ]] || fail "동일한 EBS가 중복 조회됐습니다: ${volume_id}"
  seen_volumes["${volume_id}"]=1

  volume_json="$(aws ec2 describe-volumes --region "${aws_region}" --volume-ids "${volume_id}" --output json)"
  [[ "$(jq '.Volumes | length' <<<"${volume_json}")" == "1" ]] || fail "EBS가 현재 계정/Region에 없습니다: ${volume_id}"
  volume_state="$(jq -r '.Volumes[0].State' <<<"${volume_json}")"
  availability_zone="$(jq -r '.Volumes[0].AvailabilityZone' <<<"${volume_json}")"
  size_gib="$(jq -r '.Volumes[0].Size' <<<"${volume_json}")"
  [[ "${volume_state}" == "in-use" ]] || fail "CNPG EBS가 in-use 상태가 아닙니다: ${volume_id}, state=${volume_state}"

  tag_value() {
    jq -r --arg key "$1" '.Volumes[0].Tags // [] | map(select(.Key == $key))[0].Value // empty' <<<"${volume_json}"
  }
  [[ "$(tag_value KubernetesCluster)" == "${cluster_name}" ]] || fail "KubernetesCluster 태그 불일치: ${volume_id}"
  [[ "$(tag_value kubernetes.io/created-for/pvc/namespace)" == "${CNPG_NAMESPACE}" ]] || fail "PVC namespace 태그 불일치: ${volume_id}"
  [[ "$(tag_value kubernetes.io/created-for/pvc/name)" == "${pvc_name}" ]] || fail "PVC name 태그 불일치: ${volume_id}"
  [[ "$(tag_value kubernetes.io/created-for/pv/name)" == "${pv_name}" ]] || fail "PV name 태그 불일치: ${volume_id}"
  [[ "$(tag_value CSIVolumeName)" == "${pv_name}" ]] || fail "CSI Volume 태그 불일치: ${volume_id}"
  [[ "$(tag_value PetflowBackup)" == "petflow-cnpg" ]] || fail "PetflowBackup 태그가 없습니다: ${volume_id}"

  resource_arn="arn:aws:ec2:${aws_region}:${caller_account}:volume/${volume_id}"
  resources="$(jq -c     --arg namespace "${CNPG_NAMESPACE}" --arg cluster "${CNPG_CLUSTER_NAME}"     --arg pvc "${pvc_name}" --arg pvcUid "${pvc_uid}" --arg pv "${pv_name}"     --arg volume "${volume_id}" --arg arn "${resource_arn}" --arg az "${availability_zone}"     --arg state "${volume_state}" --argjson size "${size_gib}"     '. + [{namespace:$namespace,cnpgClusterName:$cluster,pvcName:$pvc,pvcUid:$pvcUid,pvName:$pv,
      volumeId:$volume,resourceArn:$arn,availabilityZone:$az,sizeGiB:$size,volumeState:$state}]' <<<"${resources}")"
done

resource_count="$(jq 'length' <<<"${resources}")"
[[ "${resource_count}" == "${pvc_count}" ]] || fail "PVC와 EBS 매핑 개수가 다릅니다."
log "[2/7] 삭제 대상 EBS ${resource_count}개 검증 완료"
if [[ "${RESUME_MANIFEST}" == "true" ]]; then
  log "동일 DestroyRunId의 기존 Manifest를 재검증하고 백업 단계를 재개합니다."
  guard_args=(verify --region "${aws_region}" --vault "${backup_vault}" --manifest "${MANIFEST}" \
    --destroy-run-id "${DESTROY_RUN_ID}" --phase resume-auto-backup)
  mapfile -t resume_volume_ids < <(jq -r '.[].volumeId' <<<"${resources}")
  for volume_id in "${resume_volume_ids[@]}"; do
    guard_args+=(--volume-id "${volume_id}")
  done
  bash "${BACKUP_GUARD}" "${guard_args[@]}"
  log "[7/7] 기존 백업 보호 조건 재검증 완료 — cleanup/destroy 재개"
  exit 0
fi

backup_started_at="$(date --iso-8601=seconds)"
backup_started_epoch="$(date -d "${backup_started_at}" +%s)"
declare -a volume_ids=()
declare -a job_ids=()

log "[3/7] AWS Backup Job 생성"
mapfile -t volume_ids < <(jq -r '.[].volumeId' <<<"${resources}")
for volume_id in "${volume_ids[@]}"; do
  resource_arn="arn:aws:ec2:${aws_region}:${caller_account}:volume/${volume_id}"
  tags_json="$(jq -nc --arg volume "${volume_id}" --arg run "${DESTROY_RUN_ID}" '{
    Project:"petflow",Environment:"dev",BackupType:"pre-destroy",SourceVolumeId:$volume,
    DestroyRunId:$run,CreatedBy:"tdestroy.sh",ProtectedResource:"cnpg",
    Purpose:"pre-cnpg-maintenance",Source:"petflow-cnpg"
  }')"
  job_id="$(aws backup start-backup-job --region "${aws_region}"     --backup-vault-name "${backup_vault}" --resource-arn "${resource_arn}"     --iam-role-arn "${backup_role_arn}" --lifecycle DeleteAfterDays=7     --recovery-point-tags "${tags_json}" --query BackupJobId --output text)" ||     fail "Backup Job 생성 실패: volume=${volume_id}"
  [[ -n "${job_id}" && "${job_id}" != "None" ]] || fail "Backup Job ID가 없습니다: volume=${volume_id}"
  job_ids+=("${job_id}")
  resources="$(jq -c --arg volume "${volume_id}" --arg job "${job_id}"     'map(if .volumeId == $volume then . + {backupJobId:$job} else . end)' <<<"${resources}")"
  log "Backup Job 시작: volume=${volume_id}, job=${job_id}"
done

log "[4/7] Backup Job 완료 대기"
deadline="$(( $(date +%s) + BACKUP_TIMEOUT_SECONDS ))"
while true; do
  completed=0
  for index in "${!job_ids[@]}"; do
    job_id="${job_ids[${index}]}"
    volume_id="${volume_ids[${index}]}"
    job_json="$(aws backup describe-backup-job --region "${aws_region}" --backup-job-id "${job_id}" --output json)"
    state="$(jq -r '.State' <<<"${job_json}")"
    status_message="$(jq -r '.StatusMessage // empty' <<<"${job_json}")"
    case "${state}" in
      COMPLETED)
        ((completed += 1))
        ;;
      CREATED|PENDING|RUNNING)
        ;;
      ABORTED|FAILED|EXPIRED)
        fail "Backup 실패: volume=${volume_id}, job=${job_id}, state=${state}, message=${status_message:-none}"
        ;;
      *)
        fail "알 수 없는 Backup 상태: volume=${volume_id}, job=${job_id}, state=${state}, message=${status_message:-none}"
        ;;
    esac
  done
  log "Backup Job 완료 대기: ${completed}/${#job_ids[@]} COMPLETED"
  ((completed == ${#job_ids[@]})) && break
  (( $(date +%s) < deadline )) || fail "Backup 대기 시간 초과: timeout=${BACKUP_TIMEOUT_SECONDS}s"
  sleep "${BACKUP_POLL_INTERVAL_SECONDS}"
done

backup_completed_at="$(date --iso-8601=seconds)"
for index in "${!job_ids[@]}"; do
  job_id="${job_ids[${index}]}"
  volume_id="${volume_ids[${index}]}"
  job_json="$(aws backup describe-backup-job --region "${aws_region}" --backup-job-id "${job_id}" --output json)"
  recovery_point_arn="$(jq -r '.RecoveryPointArn // empty' <<<"${job_json}")"
  completion_date="$(jq -r '.CompletionDate // empty' <<<"${job_json}")"
  [[ -n "${recovery_point_arn}" && -n "${completion_date}" ]] || fail "완료 Job의 Recovery Point 정보가 없습니다: ${job_id}"
  (( $(date -d "${completion_date}" +%s) >= backup_started_epoch )) || fail "이번 실행 이전 Backup Job입니다: ${job_id}"
  recovery_json="$(aws backup describe-recovery-point --region "${aws_region}"     --backup-vault-name "${backup_vault}" --recovery-point-arn "${recovery_point_arn}" --output json)"
  recovery_status="$(jq -r '.Status' <<<"${recovery_json}")"
  recovery_created_at="$(jq -r '.CreationDate // empty' <<<"${recovery_json}")"
  [[ "${recovery_status}" == "COMPLETED" ]] || fail "Recovery Point가 COMPLETED가 아닙니다: ${volume_id}"
  tags_json="$(aws backup list-tags --region "${aws_region}" --resource-arn "${recovery_point_arn}" --output json)"
  jq -e --arg volume "${volume_id}" --arg run "${DESTROY_RUN_ID}" '
    .Tags.Project == "petflow" and
    .Tags.Environment == "dev" and
    .Tags.BackupType == "pre-destroy" and
    .Tags.SourceVolumeId == $volume and
    .Tags.DestroyRunId == $run and
    .Tags.CreatedBy == "tdestroy.sh" and
    .Tags.ProtectedResource == "cnpg"
  ' <<<"${tags_json}" >/dev/null || fail "Recovery Point 실행 태그 검증 실패: ${volume_id}"
  applied_tags="$(jq -c '.Tags' <<<"${tags_json}")"
  resources="$(jq -c \
    --arg volume "${volume_id}" --arg recovery "${recovery_point_arn}" \
    --arg completion "${completion_date}" --arg created "${recovery_created_at}" \
    --arg status "${recovery_status}" --argjson tags "${applied_tags}" \
    'map(if .volumeId == $volume then . + {
      recoveryPointArn:$recovery,recoveryPointStatus:$status,
      backupCompletionDate:$completion,recoveryPointCreationDate:$created,
      recoveryPointTags:$tags,
      verification:{result:"passed"}
    } else . end)' <<<"${resources}")"
done
log "[5/7] Recovery Point 및 태그 검증 완료"

temp_manifest="$(mktemp "${MANIFEST}.tmp.XXXXXX")"
jq -n --arg schemaVersion "2" --arg run "${DESTROY_RUN_ID}"   --arg started "${backup_started_at}" --arg completed "${backup_completed_at}"   --arg account "${caller_account}" --arg region "${aws_region}"   --arg environment "${ENVIRONMENT}" --arg eks "${cluster_name}"   --arg namespace "${CNPG_NAMESPACE}" --arg cluster "${CNPG_CLUSTER_NAME}"   --arg vault "${backup_vault}" --arg role "${backup_role_arn}"   --argjson minRetention "${vault_min_retention_days}" --argjson resources "${resources}" '{
    schemaVersion:$schemaVersion,destroyRunId:$run,backupStartedAt:$started,backupCompletedAt:$completed,
    accountId:$account,region:$region,environment:$environment,eksClusterName:$eks,
    cnpgNamespace:$namespace,cnpgClusterName:$cluster,backupVaultName:$vault,backupRoleArn:$role,
    vaultLocked:true,vaultMinRetentionDays:$minRetention,resources:$resources,
    verification:{result:"passed",verifiedAt:$completed}
  }' >"${temp_manifest}" || fail "Backup Manifest 생성에 실패했습니다."
chmod 600 "${temp_manifest}"
mv "${temp_manifest}" "${MANIFEST}"
log "[6/7] Backup Manifest 저장 완료: ${MANIFEST}"

guard_args=(verify --region "${aws_region}" --vault "${backup_vault}" --manifest "${MANIFEST}"   --destroy-run-id "${DESTROY_RUN_ID}" --phase post-auto-backup)
for volume_id in "${volume_ids[@]}"; do
  guard_args+=(--volume-id "${volume_id}")
done
bash "${BACKUP_GUARD}" "${guard_args[@]}"
log "[7/7] 백업 보호 조건 충족 — cleanup/destroy 시작"
