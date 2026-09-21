#!/usr/bin/env bash
# CNPG base backup과 WAL을 확인한 뒤 다음 apply가 사용할 복원 지점을 기록한다.
set -Eeuo pipefail

KUBECONFIG_PATH="${1:-${KUBECONFIG:-}}"
[[ -n "${KUBECONFIG_PATH}" ]] || { echo 'KUBECONFIG 경로가 필요합니다.' >&2; exit 1; }
K=(kubectl --kubeconfig "${KUBECONFIG_PATH}" -n database)
BUCKET=petflow-dev-db-backups
CLUSTER=petflow-db
MARKER=cnpg/recovery/latest.json
TIMEOUT_SECONDS="${CNPG_S3_BACKUP_TIMEOUT_SECONDS:-3600}"
[[ "${TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] || { echo '백업 제한시간이 올바르지 않습니다.' >&2; exit 1; }

"${K[@]}" wait --for=condition=Ready "cluster/${CLUSTER}" --timeout=30m
destination="$("${K[@]}" get objectstore petflow-db-backups -o jsonpath='{.spec.configuration.destinationPath}')"
[[ "${destination}" =~ ^s3://petflow-dev-db-backups/cnpg(/[a-zA-Z0-9/_-]+)?$ ]] || {
  echo "CNPG ObjectStore 경로가 예상 범위를 벗어났습니다: ${destination}" >&2; exit 1;
}
prefix="${destination#s3://${BUCKET}/}"
backup_name="petflow-db-$(date -u +%Y%m%dt%H%M%sz)"
backup_started_epoch="$(date +%s)"
printf '[cnpg-s3-backup] base backup 시작: %s (%s)\n' "${backup_name}" "${destination}"
jq -n --arg name "${backup_name}" '{
  apiVersion:"postgresql.cnpg.io/v1",kind:"Backup",
  metadata:{name:$name,namespace:"database"},
  spec:{cluster:{name:"petflow-db"},method:"plugin",
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
  -l 'cnpg.io/cluster=petflow-db,cnpg.io/instanceRole=primary' \
  -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${primary_pod}" ]] || { echo 'CNPG primary Pod를 찾지 못했습니다.' >&2; exit 1; }
"${K[@]}" exec "${primary_pod}" -c postgres -- \
  psql -U postgres -d postgres -Atqc 'SELECT pg_switch_wal()' >/dev/null
while (( $(date +%s) < deadline )); do
  base_count="$(aws s3api list-objects-v2 --bucket "${BUCKET}" \
    --prefix "${prefix}/${CLUSTER}/base/" --max-keys 1 --query KeyCount --output text)"
  newest_wal="$(aws s3api list-objects-v2 --bucket "${BUCKET}" \
    --prefix "${prefix}/${CLUSTER}/wals/" --output json \
    | jq -r '[.Contents[]?.LastModified] | max // empty')"
  if [[ "${base_count}" == 1 && -n "${newest_wal}" ]] \
    && (( $(date -d "${newest_wal}" +%s) >= backup_started_epoch )); then break; fi
  sleep 15
done
[[ "${base_count:-0}" == 1 && -n "${newest_wal:-}" ]] \
  && (( $(date -d "${newest_wal}" +%s) >= backup_started_epoch )) || {
  echo "S3 base/WAL 검증 실패: base=${base_count:-0}, newestWal=${newest_wal:-none}" >&2; exit 1;
}

marker_file="$(mktemp /tmp/petflow-cnpg-marker.XXXXXX)"
trap 'rm -f "${marker_file}"' EXIT
jq -n --arg path "${destination}" --arg backup "${backup_name}" \
  --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    schemaVersion:1,destinationPath:$path,serverName:"petflow-db",
    backupName:$backup,completedAt:$completed
  }' >"${marker_file}"
aws s3api put-object --bucket "${BUCKET}" --key "${MARKER}" \
  --body "${marker_file}" --content-type application/json >/dev/null
printf '[cnpg-s3-backup] 복원 지점 확인: %s, base+WAL 존재, marker=s3://%s/%s\n' \
  "${backup_name}" "${BUCKET}" "${MARKER}"
