#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://leechs.shop}"
RUN_20_RPS="${RUN_20_RPS:-true}"
OUTPUT_DIR="${OUTPUT_DIR:-docs/evidence/autoscaling-validation-$(date -u +%Y%m%dT%H%M%SZ)}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOAD_SCRIPT="${SCRIPT_DIR}/http-read-load.js"

command -v k6 >/dev/null
mkdir -p "${OUTPUT_DIR}"

run_stage() {
  local rate="$1"
  local duration="$2"

  echo "Starting ${rate} RPS for ${duration}"
  env \
    BASE_URL="${BASE_URL}" \
    RATE="${rate}" \
    DURATION="${duration}" \
    k6 run --quiet \
      --summary-export "${OUTPUT_DIR}/http-${rate}rps-summary.json" \
      "${LOAD_SCRIPT}"
}

# Total active duration is 8 minutes without the optional stage and exactly
# 11 minutes with it. The k6 script caps concurrency at 20 and has no retries.
run_stage 1 2m
run_stage 5 3m
run_stage 10 3m

if [[ "${RUN_20_RPS}" == "true" ]]; then
  run_stage 20 3m
fi

echo "HTTP evidence written to ${OUTPUT_DIR}"
echo "The operator must also watch DB connections, pod availability, HPA,"
echo "business lag, and NodeClaims; stop immediately on the runbook guards."
