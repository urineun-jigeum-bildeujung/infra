#!/usr/bin/env bash
# CNPG base backup과 WAL을 확인한 뒤 다음 apply가 사용할 복원 지점을 기록한다.
set -Eeuo pipefail

KUBECONFIG_PATH="${1:-${KUBECONFIG:-}}"
[[ -n "${KUBECONFIG_PATH}" ]] || { echo 'KUBECONFIG 경로가 필요합니다.' >&2; exit 1; }
K=(kubectl --kubeconfig "${KUBECONFIG_PATH}" -n database)
BUCKET=petflow-dev-db-backups
CLUSTER="${CNPG_CLUSTER_NAME:-petflow-db}"
OBJECTSTORE="${CNPG_OBJECTSTORE_NAME:-petflow-db-backups}"
MARKER=cnpg/recovery/latest.json
TIMEOUT_SECONDS="${CNPG_S3_BACKUP_TIMEOUT_SECONDS:-3600}"
PINNED_OUTPUT="${PETFLOW_CNPG_PINNED_OUTPUT:-}"
RESTORE_POINT="${PETFLOW_CNPG_RESTORE_POINT:-}"
[[ "${CLUSTER}" =~ ^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$ && "${OBJECTSTORE}" =~ ^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$ ]] || exit 1
[[ "${CLUSTER}" == petflow-db || -n "${PINNED_OUTPUT}" ]] || {
  echo '테스트 클러스터 백업에는 별도 고정 출력이 필요합니다. 운영 marker 갱신을 차단합니다.' >&2; exit 1;
}
[[ -z "${RESTORE_POINT}" || "${RESTORE_POINT}" =~ ^petflow_[a-zA-Z0-9_]{1,48}$ ]] || {
  echo '복원 지점 이름이 올바르지 않습니다.' >&2; exit 1;
}
[[ -z "${PINNED_OUTPUT}" || -n "${RESTORE_POINT}" ]] || {
  echo '고정 백업 출력에는 named restore point가 필요합니다.' >&2; exit 1;
}
[[ "${TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] || { echo '백업 제한시간이 올바르지 않습니다.' >&2; exit 1; }

"${K[@]}" wait --for=condition=Ready "cluster/${CLUSTER}" --timeout=30m
destination="$("${K[@]}" get objectstore "${OBJECTSTORE}" -o jsonpath='{.spec.configuration.destinationPath}')"
[[ "${destination}" =~ ^s3://petflow-dev-db-backups/cnpg(/[a-zA-Z0-9/_-]+)?$ ]] || {
  echo "CNPG ObjectStore 경로가 예상 범위를 벗어났습니다: ${destination}" >&2; exit 1;
}
prefix="${destination#s3://${BUCKET}/}"
backup_name="${CLUSTER}-$(date -u +%Y%m%dt%H%M%sz)"
backup_started_epoch="$(date +%s)"
printf '[cnpg-s3-backup] base backup 시작: %s (%s)\n' "${backup_name}" "${destination}"
jq -n --arg name "${backup_name}" --arg cluster "${CLUSTER}" '{
  apiVersion:"postgresql.cnpg.io/v1",kind:"Backup",
  metadata:{name:$name,namespace:"database"},
  spec:{cluster:{name:$cluster},method:"plugin",
    pluginConfiguration:{name:"barman-cloud.cloudnative-pg.io"}}
}' | "${K[@]}" apply -f -

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
while (( $(date +%s) < deadline )); do
  backup_json="$("${K[@]}" get backup "${backup_name}" -o json)"
  phase="$(jq -r '.status.phase // "pending"' <<<"${backup_json}")"
  case "${phase}" in
    completed) break ;;
    failed) echo "CNPG base backup 실패: ${backup_json}" >&2; exit 1 ;;
    *) sleep 15 ;;
  esac
done
[[ "${phase}" == completed ]] || { echo 'CNPG base backup 대기시간 초과' >&2; exit 1; }

# base 파일만으로는 PITR을 할 수 없다. 양쪽 파일이 실제 S3에 보여야 성공이다.
primary_pod="$("${K[@]}" get pods \
  -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${primary_pod}" ]] || { echo 'CNPG primary Pod를 찾지 못했습니다.' >&2; exit 1; }
if [[ -n "${RESTORE_POINT}" ]]; then
  backup_id="$(jq -r '.status.backupId // .status.backupID // empty' <<<"${backup_json}")"
  [[ "${backup_id}" =~ ^[0-9]{8}T[0-9]{6}$ ]] || {
    echo 'Barman base backup ID를 확인하지 못했습니다.' >&2; exit 1;
  }
  restore_lsn="$("${K[@]}" exec "${primary_pod}" -c postgres -- psql -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -Atqc "SELECT pg_create_restore_point('${RESTORE_POINT}');")"
  wal_name="$("${K[@]}" exec "${primary_pod}" -c postgres -- psql -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -Atqc "SELECT pg_walfile_name('${restore_lsn}'::pg_lsn);")"
  [[ "${wal_name}" =~ ^[0-9A-F]{24}$ ]] || { echo 'WAL 이름 확인 실패' >&2; exit 1; }
fi
# 사용량이 없는 DEV DB에서는 pg_switch_wal()만 호출하면 새 WAL이 생기지 않을 수 있다.
# 업무 테이블을 변경하지 않는 논리 메시지를 먼저 기록해 검증용 WAL을 확실히 만든다.
"${K[@]}" exec "${primary_pod}" -c postgres -- \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc \
  "SELECT pg_logical_emit_message(false, 'petflow-tdestroy', 'ensure pre-destroy WAL archive'); SELECT pg_switch_wal();" \
  >/dev/null
while (( $(date +%s) < deadline )); do
  # aws-cli 2.31.35 + Python 3.14 조합에서 `s3api list-objects-v2`의 help 텍스트
  # 렌더링이 깨져 명령 자체가 "badly formed help string"으로 실패한다(2026-09-28
  # 실제 재현·격리 확인 — 다른 s3api 하위 명령과 `aws s3 ls`는 영향 없음). 같은
  # 정보를 얻을 수 있는 `aws s3 ls`로 대체한다.
  base_count="$(aws s3 ls "s3://${BUCKET}/${prefix}/${CLUSTER}/base/" --recursive 2>/dev/null \
    | wc -l || true)"
  newest_wal="$(aws s3 ls "s3://${BUCKET}/${prefix}/${CLUSTER}/wals/" --recursive 2>/dev/null \
    | awk '{print $1" "$2}' | sort | tail -1 || true)"
  if [[ "${base_count:-0}" -ge 1 && -n "${newest_wal}" ]] \
    && (( $(date -d "${newest_wal}" +%s) >= backup_started_epoch )); then break; fi
  sleep 15
done
[[ "${base_count:-0}" -ge 1 && -n "${newest_wal:-}" ]] \
  && (( $(date -d "${newest_wal}" +%s) >= backup_started_epoch )) || {
  echo "S3 base/WAL 검증 실패: base=${base_count:-0}, newestWal=${newest_wal:-none}" >&2; exit 1;
}

marker_file="$(mktemp /tmp/petflow-cnpg-marker.XXXXXX)"
trap 'rm -f "${marker_file}"' EXIT
if [[ -n "${PINNED_OUTPUT}" ]]; then
  base_key="${prefix}/${CLUSTER}/base/${backup_id}/backup.info"
  wal_key="${prefix}/${CLUSTER}/wals/${wal_name:0:16}/${wal_name}.gz"
  aws s3api head-object --bucket "${BUCKET}" --key "${base_key}" >/dev/null
  while (( $(date +%s) < deadline )); do
    if wal_metadata="$(aws s3api head-object --bucket "${BUCKET}" --key "${wal_key}" 2>/dev/null)"; then break; fi
    sleep 15
  done
  [[ -n "${wal_metadata:-}" ]] || { echo '지정 복원 지점 WAL 보관 실패' >&2; exit 1; }
  wal_version="$(jq -r '.VersionId // empty' <<<"${wal_metadata}")"
  [[ -n "${wal_version}" && "${wal_version}" != null ]] || { echo 'WAL 객체 버전 누락' >&2; exit 1; }
  jq -n --arg path "${destination}" --arg backup "${backup_name}" --arg id "${backup_id}" \
    --arg name "${RESTORE_POINT}" --arg lsn "${restore_lsn}" --arg wal "${wal_key}" \
    --arg version "${wal_version}" --arg base "${base_key}" --arg cluster "${CLUSTER}" '{
      schemaVersion:2,destinationPath:$path,serverName:$cluster,backupName:$backup,
      backupID:$id,targetName:$name,restoreLSN:$lsn,baseInfoKey:$base,walKey:$wal,walVersionId:$version
    }' >"${PINNED_OUTPUT}"
  chmod 600 "${PINNED_OUTPUT}"
  echo '[cnpg-s3-backup] 지정 base backup/named restore point WAL 검증 완료. 통합 marker는 아직 게시하지 않습니다.'
  exit 0
fi
jq -n --arg path "${destination}" --arg backup "${backup_name}" \
  --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    schemaVersion:1,destinationPath:$path,serverName:"petflow-db",
    backupName:$backup,completedAt:$completed
  }' >"${marker_file}"
aws s3api put-object --bucket "${BUCKET}" --key "${MARKER}" \
  --body "${marker_file}" --content-type application/json >/dev/null
printf '[cnpg-s3-backup] 복원 지점 확인: %s, base+WAL 존재, marker=s3://%s/%s\n' \
  "${backup_name}" "${BUCKET}" "${MARKER}"
