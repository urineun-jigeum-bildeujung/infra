#!/usr/bin/env bash
# CNPG EBS를 삭제하기 전후에 동일한 AWS Backup Recovery Point가 실제로
# 존재하고 최소 보존시간이 남아 있는지 검증한다.

set -euo pipefail

EXPECTED_AWS_ACCOUNT_ID="297165773875"
DEFAULT_AWS_REGION="ap-northeast-2"
DEFAULT_BACKUP_VAULT="petflow-dev-cnpg-ebs"
DEFAULT_PURPOSE_TAG="pre-cnpg-maintenance"
DEFAULT_SOURCE_TAG="petflow-cnpg"
DEFAULT_MIN_REMAINING_HOURS=24

usage() {
  cat <<'USAGE'
Usage:
  cnpg-backup-guard.sh capture --manifest FILE [--volume-id vol-...]...
  cnpg-backup-guard.sh verify  --manifest FILE --phase NAME

Options:
  --region REGION
  --vault VAULT
  --volume-id VOLUME_ID       capture에서 여러 번 지정 가능
  --manifest FILE
  --phase NAME                verify 증거 단계 이름
  --min-remaining-hours HOURS 기본값: 24
USAGE
}

fail() {
  echo "[cnpg-backup-guard] $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 명령이 필요합니다."
}

[[ $# -ge 1 ]] || {
  usage >&2
  exit 1
}

mode="$1"
shift

aws_region="${PETFLOW_AWS_REGION:-${DEFAULT_AWS_REGION}}"
backup_vault="${PETFLOW_BACKUP_VAULT:-${DEFAULT_BACKUP_VAULT}}"
manifest=""
phase="manual-verify"
min_remaining_hours="${PETFLOW_BACKUP_MIN_REMAINING_HOURS:-${DEFAULT_MIN_REMAINING_HOURS}}"
volume_ids=()

while (($# > 0)); do
  case "$1" in
    --region)
      aws_region="$2"
      shift 2
      ;;
    --vault)
      backup_vault="$2"
      shift 2
      ;;
    --volume-id)
      volume_ids+=("$2")
      shift 2
      ;;
    --manifest)
      manifest="$2"
      shift 2
      ;;
    --phase)
      phase="$2"
      shift 2
      ;;
    --min-remaining-hours)
      min_remaining_hours="$2"
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

[[ "${mode}" == "capture" || "${mode}" == "verify" ]] || fail "mode는 capture 또는 verify여야 합니다."
[[ -n "${manifest}" ]] || fail "--manifest가 필요합니다."
[[ "${min_remaining_hours}" =~ ^[0-9]+$ ]] || fail "--min-remaining-hours는 0 이상의 정수여야 합니다."

require_command aws
require_command jq
require_command date

caller_account="$(aws sts get-caller-identity --query Account --output text)"
[[ "${caller_account}" == "${EXPECTED_AWS_ACCOUNT_ID}" ]] || \
  fail "잘못된 AWS Account입니다: ${caller_account} (expected ${EXPECTED_AWS_ACCOUNT_ID})"

vault_json="$(aws backup describe-backup-vault \
  --region "${aws_region}" \
  --backup-vault-name "${backup_vault}" \
  --output json)"

vault_locked="$(jq -r '.Locked // false' <<<"${vault_json}")"
vault_min_retention_days="$(jq -r '.MinRetentionDays // 0' <<<"${vault_json}")"

[[ "${vault_locked}" == "true" ]] || fail "Backup Vault Lock이 활성화되지 않았습니다: ${backup_vault}"
((vault_min_retention_days >= 7)) || \
  fail "Backup Vault 최소 보존기간이 7일보다 짧습니다: ${vault_min_retention_days}"

validate_recovery_point() {
  local volume_id="$1"
  local backup_job_id="$2"
  local recovery_point_arn="$3"
  local expected_resource_arn="arn:aws:ec2:${aws_region}:${caller_account}:volume/${volume_id}"
  local job_json
  local recovery_json
  local tags_json
  local status
  local resource_arn
  local delete_at
  local purpose_tag
  local source_tag
  local delete_epoch
  local required_epoch

  job_json="$(aws backup describe-backup-job \
    --region "${aws_region}" \
    --backup-job-id "${backup_job_id}" \
    --output json)" || return 1

  [[ "$(jq -r '.State' <<<"${job_json}")" == "COMPLETED" ]] || return 1
  [[ "$(jq -r '.RecoveryPointArn' <<<"${job_json}")" == "${recovery_point_arn}" ]] || return 1
  [[ "$(jq -r '.ResourceArn' <<<"${job_json}")" == "${expected_resource_arn}" ]] || return 1
  [[ "$(jq -r '.BackupVaultName' <<<"${job_json}")" == "${backup_vault}" ]] || return 1

  recovery_json="$(aws backup describe-recovery-point \
    --region "${aws_region}" \
    --backup-vault-name "${backup_vault}" \
    --recovery-point-arn "${recovery_point_arn}" \
    --output json)" || return 1

  status="$(jq -r '.Status' <<<"${recovery_json}")"
  resource_arn="$(jq -r '.ResourceArn' <<<"${recovery_json}")"
  delete_at="$(jq -r '.CalculatedLifecycle.DeleteAt // empty' <<<"${recovery_json}")"

  [[ "${status}" == "COMPLETED" ]] || return 1
  [[ "${resource_arn}" == "${expected_resource_arn}" ]] || return 1
  [[ -n "${delete_at}" ]] || return 1

  tags_json="$(aws backup list-tags \
    --region "${aws_region}" \
    --resource-arn "${recovery_point_arn}" \
    --output json)" || return 1
  purpose_tag="$(jq -r '.Tags.Purpose // empty' <<<"${tags_json}")"
  source_tag="$(jq -r '.Tags.Source // empty' <<<"${tags_json}")"

  [[ "${purpose_tag}" == "${DEFAULT_PURPOSE_TAG}" ]] || return 1
  [[ "${source_tag}" == "${DEFAULT_SOURCE_TAG}" ]] || return 1

  delete_epoch="$(date -d "${delete_at}" +%s)" || return 1
  required_epoch="$(( $(date +%s) + min_remaining_hours * 3600 ))"
  ((delete_epoch > required_epoch)) || return 1

  jq -n \
    --arg volumeId "${volume_id}" \
    --arg resourceArn "${expected_resource_arn}" \
    --arg backupJobId "${backup_job_id}" \
    --arg recoveryPointArn "${recovery_point_arn}" \
    --arg status "${status}" \
    --arg completionDate "$(jq -r '.CompletionDate' <<<"${job_json}")" \
    --arg deleteAt "${delete_at}" \
    '{
      volumeId: $volumeId,
      resourceArn: $resourceArn,
      backupJobId: $backupJobId,
      recoveryPointArn: $recoveryPointArn,
      status: $status,
      completionDate: $completionDate,
      deleteAt: $deleteAt
    }'
}

capture_manifest() {
  local volume_id
  local resource_arn
  local volume_json
  local backup_tag
  local jobs_json
  local candidate_row
  local job_id
  local recovery_point_arn
  local entry
  local found
  local resources_json
  local manifest_dir
  local temp_manifest
  local -a entries=()
  local -a candidate_rows=()

  for volume_id in "${volume_ids[@]}"; do
    [[ "${volume_id}" =~ ^vol-[0-9a-f]+$ ]] || fail "잘못된 EBS Volume ID입니다: ${volume_id}"
    resource_arn="arn:aws:ec2:${aws_region}:${caller_account}:volume/${volume_id}"

    volume_json="$(aws ec2 describe-volumes \
      --region "${aws_region}" \
      --volume-ids "${volume_id}" \
      --output json)"
    backup_tag="$(jq -r '.Volumes[0].Tags // [] | map(select(.Key == "PetflowBackup"))[0].Value // empty' <<<"${volume_json}")"
    [[ "${backup_tag}" == "${DEFAULT_SOURCE_TAG}" ]] || \
      fail "CNPG Backup 선택 태그가 없거나 다릅니다: ${volume_id}"

    jobs_json="$(aws backup list-backup-jobs \
      --region "${aws_region}" \
      --by-resource-arn "${resource_arn}" \
      --by-state COMPLETED \
      --output json)"

    mapfile -t candidate_rows < <(jq -r --arg vault "${backup_vault}" '
      [.BackupJobs[]
        | select(.BackupVaultName == $vault)
        | select(.RecoveryPointArn != null)]
      | sort_by(.CompletionDate)
      | reverse[]
      | [.BackupJobId, .RecoveryPointArn]
      | @tsv
    ' <<<"${jobs_json}")

    found=false
    for candidate_row in "${candidate_rows[@]}"; do
      IFS=$'\t' read -r job_id recovery_point_arn <<<"${candidate_row}"
      if entry="$(validate_recovery_point "${volume_id}" "${job_id}" "${recovery_point_arn}" 2>/dev/null)"; then
        entries+=("${entry}")
        found=true
        echo "[cnpg-backup-guard] 검증 완료: ${volume_id}, job=${job_id}, recoveryPoint=${recovery_point_arn}"
        break
      fi
    done

    [[ "${found}" == "true" ]] || \
      fail "유효한 온디맨드 Recovery Point를 찾지 못했습니다: ${volume_id}"
  done

  if ((${#entries[@]} == 0)); then
    resources_json='[]'
  else
    resources_json="$(printf '%s\n' "${entries[@]}" | jq -s '.')"
  fi

  manifest_dir="$(dirname "${manifest}")"
  mkdir -p "${manifest_dir}"
  temp_manifest="$(mktemp "${manifest}.tmp.XXXXXX")"
  jq -n \
    --arg schemaVersion "1" \
    --arg capturedAt "$(date --iso-8601=seconds)" \
    --arg accountId "${caller_account}" \
    --arg region "${aws_region}" \
    --arg backupVaultName "${backup_vault}" \
    --argjson vaultMinRetentionDays "${vault_min_retention_days}" \
    --argjson resources "${resources_json}" \
    '{
      schemaVersion: $schemaVersion,
      capturedAt: $capturedAt,
      accountId: $accountId,
      region: $region,
      backupVaultName: $backupVaultName,
      vaultLocked: true,
      vaultMinRetentionDays: $vaultMinRetentionDays,
      resources: $resources
    }' >"${temp_manifest}"
  chmod 600 "${temp_manifest}"
  mv "${temp_manifest}" "${manifest}"
  echo "[cnpg-backup-guard] 증거 manifest 저장: ${manifest}"
}

verify_manifest() {
  local manifest_account
  local manifest_region
  local manifest_vault
  local volume_id
  local job_id
  local recovery_point_arn
  local entry
  local resource_count

  [[ -f "${manifest}" ]] || fail "Backup 증거 manifest가 없습니다: ${manifest}"
  jq -e '.schemaVersion == "1" and (.resources | type == "array")' "${manifest}" >/dev/null || \
    fail "Backup 증거 manifest 형식이 올바르지 않습니다: ${manifest}"

  manifest_account="$(jq -r '.accountId' "${manifest}")"
  manifest_region="$(jq -r '.region' "${manifest}")"
  manifest_vault="$(jq -r '.backupVaultName' "${manifest}")"

  [[ "${manifest_account}" == "${caller_account}" ]] || fail "manifest AWS Account가 현재 계정과 다릅니다."
  [[ "${manifest_region}" == "${aws_region}" ]] || fail "manifest Region이 현재 Region과 다릅니다."
  [[ "${manifest_vault}" == "${backup_vault}" ]] || fail "manifest Backup Vault가 현재 Vault와 다릅니다."

  resource_count="$(jq -r '.resources | length' "${manifest}")"
  while IFS=$'\t' read -r volume_id job_id recovery_point_arn; do
    [[ -z "${volume_id}" ]] && continue
    if ! entry="$(validate_recovery_point "${volume_id}" "${job_id}" "${recovery_point_arn}")"; then
      fail "${phase} 단계에서 Recovery Point 검증에 실패했습니다: ${volume_id}"
    fi
    echo "[cnpg-backup-guard] ${phase} 유지 확인: ${volume_id}, recoveryPoint=${recovery_point_arn}"
  done < <(jq -r '.resources[] | [.volumeId, .backupJobId, .recoveryPointArn] | @tsv' "${manifest}")

  echo "[cnpg-backup-guard] ${phase} 검증 완료: ${resource_count}개"
}

case "${mode}" in
  capture)
    capture_manifest
    ;;
  verify)
    verify_manifest
    ;;
esac
