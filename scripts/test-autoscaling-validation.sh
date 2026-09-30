#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT_DIR}/scripts/autoscaling-validation/run-kafka.sh"
CLEANUP="${ROOT_DIR}/scripts/autoscaling-validation/cleanup.sh"
TEST_DIR="$(mktemp -d)"
FAKE_BIN="${TEST_DIR}/bin"
mkdir -p "${FAKE_BIN}"
trap 'rm -rf "${TEST_DIR}"' EXIT

cat >"${FAKE_BIN}/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_LOG:?}"
: "${MOCK_SCENARIO:?}"
printf '%s\n' "$*" >>"${MOCK_LOG}"

if [[ "${1:-}" == "config" && "${2:-}" == "current-context" ]]; then
  case "${MOCK_SCENARIO}" in
    context_failure)
      echo "모의 kubeconfig 조회 실패" >&2
      exit 1
      ;;
    context_mismatch)
      echo "production"
      ;;
    *)
      echo "petflow-dev"
      ;;
  esac
  exit 0
fi

args=("$@")
if [[ "${args[0]:-}" == "--context" ]]; then
  args=("${args[@]:2}")
fi
command_name="${args[0]:-}"
resource="${args[1]:-}"

if [[ "${MOCK_SCENARIO}" == "runner" ]]; then
  if [[ "${command_name}" == "get" && "${resource}" == "kafka" ]]; then
    exit 0
  fi
  if [[ "${command_name}" == "get" && "${resource}" == "secret" ]]; then
    if [[ " $* " == *" autoscaling-validation-20260930 "* ]]; then
      printf '%s\n' '{"data":{"password":"ZmFrZS1wYXNzd29yZA=="}}'
    else
      printf '%s\n' '{"data":{"ca.crt":"ZmFrZS1jYQ==","ca.p12":"ZmFrZS1wMTI=","ca.password":"ZmFrZS1jYS1wYXNz"}}'
    fi
  fi
  if [[ "${command_name}" == "apply" && " $* " == *" -f - "* ]]; then
    cat >/dev/null
  fi
  exit 0
fi

if [[ "${command_name}" == "get" ]]; then
  case "${MOCK_SCENARIO}:${resource}" in
    forbidden:networkpolicy)
      echo "서버 응답 오류(Forbidden): 접근 거부" >&2
      exit 1
      ;;
    get_timeout:kafkatopic)
      echo "서버 연결 timeout" >&2
      exit 1
      ;;
    invalid_json:kafkatopic)
      printf '%s\n' '{not-json'
      exit 0
      ;;
    partial_notfound:namespace|partial_notfound:kafkatopic|all_notfound:*)
      exit 0
      ;;
  esac

  owner="autoscaling-validation"
  if [[ "${MOCK_SCENARIO}" == "owner_mismatch" && "${resource}" == "kafkauser" ]]; then
    owner="someone-else"
  fi
  printf '{"metadata":{"labels":{"app.kubernetes.io/part-of":"%s"}}}\n' "${owner}"
  exit 0
fi

if [[ "${command_name}" == "delete" ]]; then
  case "${MOCK_SCENARIO}:${resource}" in
    delete_failure:networkpolicy)
      echo "모의 삭제 실패" >&2
      exit 1
      ;;
    delete_timeout:kafkatopic)
      echo "모의 삭제 timeout" >&2
      exit 1
      ;;
  esac
  exit 0
fi

exit 0
MOCK
chmod +x "${FAKE_BIN}/kubectl"

fail() {
  echo "실패: $*" >&2
  exit 1
}

run_case() {
  local scenario="$1"
  local script="$2"
  local expected="$3"
  local log_file="${TEST_DIR}/${scenario}.calls"
  local output_file="${TEST_DIR}/${scenario}.output"
  local status

  : >"${log_file}"
  set +e
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
    MOCK_SCENARIO="${scenario}" \
    MOCK_LOG="${log_file}" \
    EXPECTED_CONTEXT=petflow-dev \
    "${script}" >"${output_file}" 2>&1
  status=$?
  set -e

  if [[ "${expected}" == "success" && ${status} -ne 0 ]]; then
    sed -n '1,160p' "${output_file}" >&2
    fail "${scenario}의 종료 코드는 ${status}이며 성공을 예상했습니다"
  fi
  if [[ "${expected}" == "failure" && ${status} -eq 0 ]]; then
    fail "${scenario}가 성공했지만 실패를 예상했습니다"
  fi

  LAST_LOG="${log_file}"
  LAST_OUTPUT="${output_file}"
}

call_count() {
  local pattern="$1"
  awk -v pattern="${pattern}" '$0 ~ pattern {count++} END {print count + 0}' "${LAST_LOG}"
}

assert_no_delete() {
  [[ "$(call_count " delete ")" == "0" ]] || fail "예상하지 않은 삭제 호출: ${LAST_LOG}"
}

assert_no_success_message() {
  ! grep -q '오토스케일링 검증 리소스 정리를 완료했습니다' "${LAST_OUTPUT}" ||
    fail "실패 상황에서 성공 메시지가 출력됐습니다: ${LAST_OUTPUT}"
}

# Kafka 실행기: 모든 kubectl 호출을 모의 처리하고 가짜 Secret 값만 사용한다.
run_case runner "${RUNNER}" success
grep -q '^관측:' "${LAST_OUTPUT}" || fail "실행기가 관측 안내를 출력하지 않았습니다"
grep -q '^정리:' "${LAST_OUTPUT}" || fail "실행기가 정리 안내를 출력하지 않았습니다"
! grep -q '^diff --git ' "${RUNNER}" || fail "실행기에 잘못된 diff 명령이 남아 있습니다"

# 컨텍스트 오류는 어떤 삭제보다 먼저 실패해야 한다.
run_case context_mismatch "${CLEANUP}" failure
assert_no_delete
run_case context_failure "${CLEANUP}" failure
assert_no_delete

# 소유권이 정상이면 명시한 네 대상만 삭제한다. current-context 이후의 모든
# 작업은 검증한 컨텍스트와 유한한 timeout을 사용해야 한다.
run_case valid "${CLEANUP}" success
[[ "$(call_count " get ")" == "4" ]] || fail "정상 정리에서 네 대상을 모두 사전 검사하지 않았습니다"
[[ "$(call_count " delete ")" == "4" ]] || fail "정상 정리에서 삭제 호출이 네 건이 아닙니다"
for target in \
  'delete namespace autoscaling-validation ' \
  'delete networkpolicy -n kafka allow-autoscaling-validation ' \
  'delete kafkatopic -n kafka autoscaling-validation-20260930 ' \
  'delete kafkauser -n kafka autoscaling-validation-20260930 '; do
  grep -Fq "${target}" "${LAST_LOG}" || fail "명시한 삭제 대상이 없습니다: ${target}"
done
awk 'NR > 1 && $0 !~ /^--context petflow-dev / {exit 1}' "${LAST_LOG}" ||
  fail "검증 이후 kubectl 호출에 --context petflow-dev가 고정되지 않았습니다"
awk '/ get / && $0 !~ /--request-timeout=15s/ {exit 1}' "${LAST_LOG}" ||
  fail "조회 호출에 유한한 요청 timeout이 없습니다"
awk '/ delete / && ($0 !~ /--request-timeout=15s/ || $0 !~ /--timeout=120s/) {exit 1}' \
  "${LAST_LOG}" || fail "삭제 호출에 유한한 timeout이 없습니다"

# 마지막 사전 검사 대상의 소유권이 달라도 삭제 호출은 0건이어야 한다.
run_case owner_mismatch "${CLEANUP}" failure
[[ "$(call_count " get ")" == "4" ]] || fail "소유권 불일치 시 사전 검사 대상이 누락됐습니다"
assert_no_delete
grep -q 'KafkaUser/kafka/autoscaling-validation-20260930' "${LAST_OUTPUT}" ||
  fail "소유권 오류 메시지에 KafkaUser가 표시되지 않았습니다"
assert_no_success_message

# NotFound는 안전하게 처리하고 존재하면서 소유권이 확인된 리소스만 삭제한다.
run_case partial_notfound "${CLEANUP}" success
[[ "$(call_count " get ")" == "4" ]] || fail "일부 NotFound에서 사전 검사 대상이 누락됐습니다"
[[ "$(call_count " delete ")" == "2" ]] || fail "일부 NotFound에서 삭제 호출 수가 올바르지 않습니다"
run_case all_notfound "${CLEANUP}" success
[[ "$(call_count " get ")" == "4" ]] || fail "전체 NotFound에서 사전 검사 대상이 누락됐습니다"
assert_no_delete

# 조회 및 JSON 오류는 모든 삭제 전에 중단돼야 한다.
for scenario in forbidden get_timeout invalid_json; do
  run_case "${scenario}" "${CLEANUP}" failure
  [[ "$(call_count " get ")" == "4" ]] || fail "${scenario}에서 사전 검사 대상이 누락됐습니다"
  assert_no_delete
  assert_no_success_message
done

# 삭제 실패와 timeout은 0이 아닌 종료 코드로 끝나며 성공을 표시하면 안 된다.
run_case delete_failure "${CLEANUP}" failure
[[ "$(call_count " delete ")" == "2" ]] || fail "삭제 실패 호출 순서가 변경됐습니다"
assert_no_success_message
grep -q 'NetworkPolicy/kafka/allow-autoscaling-validation' "${LAST_OUTPUT}" ||
  fail "삭제 실패 메시지에 NetworkPolicy가 표시되지 않았습니다"

run_case delete_timeout "${CLEANUP}" failure
[[ "$(call_count " delete ")" == "3" ]] || fail "삭제 timeout 호출 순서가 변경됐습니다"
assert_no_success_message
grep -q 'KafkaTopic/kafka/autoscaling-validation-20260930' "${LAST_OUTPUT}" ||
  fail "삭제 timeout 메시지에 KafkaTopic이 표시되지 않았습니다"

echo "오토스케일링 검증 스크립트 모의 테스트: 통과"
