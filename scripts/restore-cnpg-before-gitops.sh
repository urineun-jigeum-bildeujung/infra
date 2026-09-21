#!/usr/bin/env bash
# GitOps의 서비스 배포 전에 CNPG를 복원하거나 최초 initdb로 생성한다.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_DIR="${GITOPS_DIR:-${SCRIPT_DIR}/../../gitops}"
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/config}"
export KUBECONFIG="${KUBECONFIG_PATH}"
K=(kubectl --kubeconfig "${KUBECONFIG_PATH}")
DB=(kubectl --kubeconfig "${KUBECONFIG_PATH}" -n database)
BUCKET=petflow-dev-db-backups
MARKER=cnpg/recovery/latest.json
IMAGE=297165773875.dkr.ecr.ap-northeast-2.amazonaws.com/petflow/postgresql-pg-bigm:17.11-pg-bigm-1.2-20250903
PLUGIN=barman-cloud.cloudnative-pg.io
BACKUP_SCRIPT="${CNPG_BACKUP_SCRIPT:-${SCRIPT_DIR}/cnpg-s3-backup.sh}"

fail() { printf '[cnpg-restore] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[cnpg-restore] %s\n' "$*"; }
for command_name in aws kubectl helm jq date; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} 명령이 필요합니다."
done

# 재실행 시 기존 DB를 절대로 다시 bootstrap하지 않는다.
if "${DB[@]}" get cluster petflow-db >/dev/null 2>&1; then
  log '기존 petflow-db 발견. 현재 Cluster를 유지하고 Ready 상태를 검증합니다.'
  "${DB[@]}" wait --for=condition=Ready cluster/petflow-db --timeout=30m
  "${BACKUP_SCRIPT}" "${KUBECONFIG_PATH}"
  exit 0
fi

log 'CNPG 선행 구성 요소 설치'
"${K[@]}" create namespace database --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" create namespace cert-manager --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" create namespace cnpg-system --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" apply -f "${GITOPS_DIR}/platform/05-storageclass/manifests/gp3-cnpg.yaml"
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null
helm repo update jetstack cnpg >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.1 \
  --namespace cert-manager --set installCRDs=true --wait --timeout 10m
helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.0 \
  --namespace cnpg-system --wait --timeout 10m
helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud --version 0.7.1 \
  --namespace cnpg-system --wait --timeout 10m

source_path=''
marker_key="$(aws s3api list-objects-v2 --bucket "${BUCKET}" --prefix "${MARKER}" \
  --max-keys 1 --query 'Contents[0].Key' --output text)" \
  || fail 'S3 복원 지점 목록을 읽지 못했습니다.'
if [[ "${marker_key}" == "${MARKER}" ]]; then
  marker_file="$(mktemp /tmp/petflow-cnpg-source.XXXXXX)"
  trap 'rm -f "${marker_file}"' EXIT
  aws s3api get-object --bucket "${BUCKET}" --key "${MARKER}" "${marker_file}" >/dev/null \
    || fail '복원 지점 marker를 읽지 못했습니다.'
  jq -e '.schemaVersion == 1 and .serverName == "petflow-db" and
    (.backupName | type == "string" and length > 0) and
    (.destinationPath | type == "string")' "${marker_file}" >/dev/null \
    || fail '복원 지점 marker 형식이 올바르지 않습니다.'
  source_path="$(jq -r '.destinationPath' "${marker_file}")"
  [[ "${source_path}" =~ ^s3://petflow-dev-db-backups/cnpg(/[a-zA-Z0-9/_-]+)?$ ]] \
    || fail "복원 경로가 예상 범위를 벗어났습니다: ${source_path}"
  source_prefix="${source_path#s3://${BUCKET}/}"
  for kind in base wals; do
    count="$(aws s3api list-objects-v2 --bucket "${BUCKET}" \
      --prefix "${source_prefix}/petflow-db/${kind}/" --max-keys 1 \
      --query KeyCount --output text)" || fail "${kind} 확인 실패"
    [[ "${count}" == 1 ]] || fail "marker가 가리키는 ${kind} 파일이 없습니다. initdb로 넘어가지 않습니다."
  done
  log "복원 지점 확인: ${source_path}"
else
  # marker가 없는데 새 세대 경로에 데이터가 있다면 marker 손실 가능성이 있다.
  existing="$(aws s3api list-objects-v2 --bucket "${BUCKET}" \
    --prefix cnpg/generations/ --max-keys 1 --query KeyCount --output text)" \
    || fail 'S3 백업 경로를 확인하지 못했습니다.'
  [[ "${existing}" == 0 ]] || fail '복원 marker 없이 이전 세대 데이터가 있습니다. 자동 initdb를 중단합니다.'
  legacy_base="$(aws s3api list-objects-v2 --bucket "${BUCKET}" \
    --prefix cnpg/petflow-db/base/ --max-keys 1 --query KeyCount --output text)" \
    || fail '기존 S3 base backup 경로를 확인하지 못했습니다.'
  [[ "${legacy_base}" == 0 ]] || fail '기존 base backup이 있으나 marker가 없습니다. 자동 initdb를 중단합니다.'
  log '복원 가능한 백업이 없습니다. 최초 initdb를 수행합니다.'
fi

generation="$(date -u +%Y%m%dT%H%M%SZ)-$(cat /proc/sys/kernel/random/uuid)"
destination="s3://${BUCKET}/cnpg/generations/${generation}"
empty="$(aws s3api list-objects-v2 --bucket "${BUCKET}" \
  --prefix "cnpg/generations/${generation}/" --max-keys 1 --query KeyCount --output text)" \
  || fail '새 WAL 경로의 비어 있음 확인에 실패했습니다.'
[[ "${empty}" == 0 ]] || fail '새 WAL 경로가 이미 사용 중입니다.'
log "새 backup/WAL 세대: ${destination}"

objectstore_file="$(mktemp /tmp/petflow-cnpg-objectstore.XXXXXX)"
cluster_file="$(mktemp /tmp/petflow-cnpg-cluster.XXXXXX)"
trap 'rm -f "${marker_file:-}" "${objectstore_file}" "${cluster_file}"' EXIT
jq -n --arg path "${destination}" '{
  apiVersion:"barmancloud.cnpg.io/v1",kind:"ObjectStore",
  metadata:{name:"petflow-db-backups",namespace:"database"},
  spec:{configuration:{destinationPath:$path,
    s3Credentials:{inheritFromIAMRole:true},wal:{compression:"gzip"}},
    retentionPolicy:"30d"}
}' >"${objectstore_file}"
"${K[@]}" apply -f "${objectstore_file}"

if [[ -n "${source_path}" ]]; then
  jq -n --arg path "${source_path}" '{
    apiVersion:"barmancloud.cnpg.io/v1",kind:"ObjectStore",
    metadata:{name:"petflow-db-restore-source",namespace:"database"},
    spec:{configuration:{destinationPath:$path,s3Credentials:{inheritFromIAMRole:true}}}
  }' | "${K[@]}" apply -f -
  bootstrap="$(jq -n '{recovery:{source:"previous-generation"}}')"
  external="$(jq -n --arg plugin "${PLUGIN}" '[{name:"previous-generation",
    plugin:{name:$plugin,parameters:{barmanObjectName:"petflow-db-restore-source",
      serverName:"petflow-db"}}}]')"
else
  bootstrap='{"initdb":{"database":"app","owner":"app"}}'
  external='[]'
fi

jq -n --arg image "${IMAGE}" --arg plugin "${PLUGIN}" \
  --argjson bootstrap "${bootstrap}" --argjson external "${external}" '{
  apiVersion:"postgresql.cnpg.io/v1",kind:"Cluster",
  metadata:{name:"petflow-db",namespace:"database"},
  spec:{instances:2,imageName:$image,
    postgresql:{shared_preload_libraries:["pg_bigm"]},
    bootstrap:$bootstrap,externalClusters:$external,
    affinity:{enablePodAntiAffinity:true,
      topologyKey:"topology.kubernetes.io/zone",podAntiAffinityType:"required"},
    storage:{storageClass:"gp3-cnpg",size:"20Gi"},
    resources:{requests:{cpu:"500m",memory:"1Gi"},limits:{cpu:"1",memory:"2Gi"}},
    plugins:[{name:$plugin,isWALArchiver:true,
      parameters:{barmanObjectName:"petflow-db-backups"}}]}
}' >"${cluster_file}"
"${K[@]}" apply -f "${cluster_file}"
log 'CNPG 복원/initdb 및 Ready 대기'
"${DB[@]}" wait --for=condition=Ready cluster/petflow-db --timeout=30m \
  || { "${DB[@]}" get cluster,pods -o wide >&2; fail 'DB 준비 실패. 자동 initdb 재시도는 하지 않습니다.'; }

# GitOps가 서비스 Application을 생성하기 전에 DB 이름과 백업을 준비한다.
"${K[@]}" apply -f "${GITOPS_DIR}/platform/60-cnpg-cluster/manifests/petflow-db.yaml"
"${K[@]}" apply -f "${GITOPS_DIR}/platform/60-cnpg-cluster/manifests/networkpolicy.yaml"
"${BACKUP_SCRIPT}" "${KUBECONFIG_PATH}"
log 'CNPG 준비 및 새 세대 base/WAL 백업 검증 완료'
