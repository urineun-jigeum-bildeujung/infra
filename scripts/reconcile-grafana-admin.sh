#!/usr/bin/env bash
set -Eeuo pipefail
GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-observability}"
GRAFANA_NAME="${GRAFANA_NAME:-kube-prometheus-stack-grafana}"
GRAFANA_SERVICE="${GRAFANA_SERVICE:-kube-prometheus-stack-grafana}"
GRAFANA_ADMIN_SECRET_NAME="${GRAFANA_ADMIN_SECRET_NAME:-grafana-admin-credentials}"
GRAFANA_ADMIN_PASSWORD_MIN_LENGTH="${GRAFANA_ADMIN_PASSWORD_MIN_LENGTH:-10}"
grafana_die() { printf '[grafana-admin] ERROR: %s\n' "$*" >&2; exit 1; }
grafana_log() { printf '[grafana-admin] %s\n' "$*" >&2; }
grafana_tmp() { mktemp "$GRAFANA_TMP/file.XXXXXX"; }
grafana_cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n ${GRAFANA_FORWARD_PID:-} ]]; then
    kill "$GRAFANA_FORWARD_PID" 2>/dev/null || :
    wait "$GRAFANA_FORWARD_PID" 2>/dev/null || :
  fi
  [[ -z ${GRAFANA_TMP:-} ]] || rm -rf -- "$GRAFANA_TMP"
  exit "$rc"
}
grafana_init() {
  umask 077
  local dep
  for dep in curl jq kubectl base64 mktemp cmp tr wc sed head; do
    command -v "$dep" >/dev/null || grafana_die "required command missing: $dep"
  done
  GRAFANA_TMP=$(mktemp -d /tmp/petflow-grafana.XXXXXX)
  trap grafana_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  GRAFANA_KUBE=(kubectl --request-timeout=30s --context "${KUBE_CONTEXT:-petflow-dev}")
}
grafana_kube() {
  local rc
  if "${GRAFANA_KUBE[@]}" "$@" 2>"$GRAFANA_TMP/command-error"; then return 0; else
    rc=$?; grafana_die "kubectl failed (exit $rc; response redacted)"
  fi
}
grafana_status() {
  local path=$1 authenticated=${2:-yes} config=()
  [[ $authenticated != yes ]] || config=(--config "$GRAFANA_CURL_CONFIG")
  curl --silent --show-error --max-time 10 --output /dev/null --write-out '%{http_code}' "${config[@]}" "$GRAFANA_URL$path" 2>"$GRAFANA_TMP/curl-error" || return 1
}
grafana_validate_credentials() {
  local user_file=$1 password_file=$2 normalized_file=$3
  [[ $GRAFANA_ADMIN_PASSWORD_MIN_LENGTH =~ ^[1-9][0-9]*$ ]] \
    || grafana_die 'Grafana minimum password length must be a positive integer'
  [[ -s $user_file && $(wc -m <"$password_file") -ge $GRAFANA_ADMIN_PASSWORD_MIN_LENGTH ]] \
    || grafana_die 'invalid Grafana administrator Secret format/length'
  tr -d '\r\n' <"$password_file" >"$normalized_file"
  cmp -s "$password_file" "$normalized_file" || grafana_die 'Grafana password contains newline'
  [[ $(cat "$user_file") != admin || $(cat "$password_file") != admin ]] \
    || grafana_die 'default Grafana admin/admin credential is not allowed'
}
grafana_reconcile() {
  local code attempt
  code=$(grafana_status /api/user) || grafana_die 'Grafana authentication request failed'
  [[ $code != 200 ]] || { grafana_log 'Grafana administrator Secret authentication verified'; return; }
  [[ $code == 401 && $GRAFANA_USER == admin ]] || grafana_die "Grafana administrator authentication failed: HTTP $code"
  { cat "$GRAFANA_PASSWORD_FILE"; printf '\n'; } | grafana_kube exec -i -n "$GRAFANA_NAMESPACE" "statefulset/$GRAFANA_NAME" -c grafana -- grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini admin reset-admin-password --password-from-stdin --user-id 1 >/dev/null
  for ((attempt=0;attempt<15;attempt++)); do
    code=$(grafana_status /api/user) || grafana_die 'Grafana post-reset authentication request failed'
    [[ $code != 200 ]] || { grafana_log 'Grafana DB password synchronized to existing Secret and verified (values redacted)'; return; }
    [[ $code == 401 ]] || break
    ((attempt==14)) || sleep 2
  done
  grafana_die 'Grafana authentication failed after synchronization'
}
grafana_main() {
  local secret user password normalized token forward port start pid
  [[ $# == 0 ]] || grafana_die 'this Grafana helper does not accept target-file arguments'
  [[ -z ${PETFLOW_STATEFUL_TARGET_FILE:-} ]] || grafana_die 'sandbox targets belong to infra-stateful-shell, not this hybrid entrypoint'
  grafana_init
  secret=$(grafana_tmp); user=$(grafana_tmp); password=$(grafana_tmp); normalized=$(grafana_tmp)
  grafana_kube get secret "$GRAFANA_ADMIN_SECRET_NAME" -n "$GRAFANA_NAMESPACE" -o json >"$secret"
  jq -er '.data["admin-user"]' "$secret"|base64 -d >"$user"
  jq -er '.data["admin-password"]' "$secret"|base64 -d >"$password"
  grafana_validate_credentials "$user" "$password" "$normalized"
  GRAFANA_USER=$(cat "$user"); GRAFANA_PASSWORD_FILE=$password; GRAFANA_CURL_CONFIG=$(grafana_tmp)
  token=$({ cat "$user"; printf ':'; cat "$password"; } | base64 -w0)
  printf 'header = "Authorization: Basic %s"\n' "$token" >"$GRAFANA_CURL_CONFIG"; unset token
  forward=$(grafana_tmp)
  "${GRAFANA_KUBE[@]}" -n "$GRAFANA_NAMESPACE" port-forward --address=127.0.0.1 "service/$GRAFANA_SERVICE" :80 >"$forward" 2>&1 &
  pid=$!; GRAFANA_FORWARD_PID=$pid; start=$SECONDS; port=''
  while ((SECONDS-start<120)); do
    kill -0 "$pid" 2>/dev/null || grafana_die 'Grafana port-forward failed'
    port=$(sed -n 's/.*Forwarding from 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$forward"|head -1)
    if [[ -n $port ]]; then
      GRAFANA_URL="http://127.0.0.1:$port"
      if [[ $(grafana_status /api/health no || :) == 200 ]]; then grafana_reconcile; return; fi
    fi
    sleep 2
  done
  grafana_die 'Grafana API readiness timed out'
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then grafana_main "$@"; fi
