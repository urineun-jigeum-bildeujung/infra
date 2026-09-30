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

  echo "${rate} RPS 부하를 ${duration} 동안 시작합니다"
  env \
    BASE_URL="${BASE_URL}" \
    RATE="${rate}" \
    DURATION="${duration}" \
    k6 run --quiet \
      --summary-export "${OUTPUT_DIR}/http-${rate}rps-summary.json" \
      "${LOAD_SCRIPT}"
}

# 선택 단계를 제외하면 전체 활성 시간은 8분, 포함하면 정확히 11분이다.
# k6 스크립트는 동시성을 20으로 제한하고 재시도하지 않는다.
run_stage 1 2m
run_stage 5 3m
run_stage 10 3m

if [[ "${RUN_20_RPS}" == "true" ]]; then
  run_stage 20 3m
fi

echo "HTTP 증적 저장 위치: ${OUTPUT_DIR}"
echo "DB 연결, Pod 가용성, HPA, 업무 lag, NodeClaim도 함께 관측해야 합니다."
echo "실행 지시서의 중단 조건이 발생하면 즉시 중단하세요."
