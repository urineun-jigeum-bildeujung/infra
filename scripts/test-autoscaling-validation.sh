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
      echo "mock kubeconfig failure" >&2
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
      echo "Error from server (Forbidden): forbidden" >&2
      exit 1
      ;;
    get_timeout:kafkatopic)
      echo "Unable to connect to the server: timeout" >&2
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
      echo "mock delete failure" >&2
      exit 1
      ;;
    delete_timeout:kafkatopic)
      echo "mock delete timeout" >&2
      exit 1
      ;;
  esac
  exit 0
fi

exit 0
MOCK
chmod +x "${FAKE_BIN}/kubectl"

fail() {
  echo "FAIL: $*" >&2
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
    fail "${scenario} returned ${status}; expected success"
  fi
  if [[ "${expected}" == "failure" && ${status} -eq 0 ]]; then
    fail "${scenario} succeeded; expected failure"
  fi

  LAST_LOG="${log_file}"
  LAST_OUTPUT="${output_file}"
}

call_count() {
  local pattern="$1"
  awk -v pattern="${pattern}" '$0 ~ pattern {count++} END {print count + 0}' "${LAST_LOG}"
}

assert_no_delete() {
  [[ "$(call_count " delete ")" == "0" ]] || fail "unexpected delete in ${LAST_LOG}"
}

assert_no_success_message() {
  ! grep -q 'autoscaling validation resources removed' "${LAST_OUTPUT}" ||
    fail "false success message in ${LAST_OUTPUT}"
}

# Kafka runner: all kubectl calls are mocked and fake Secret material is used.
run_case runner "${RUNNER}" success
grep -q '^Watch:' "${LAST_OUTPUT}" || fail "runner did not print Watch guidance"
grep -q '^Cleanup:' "${LAST_OUTPUT}" || fail "runner did not print Cleanup guidance"
! grep -q '^diff --git ' "${RUNNER}" || fail "runner still contains the invalid diff command"

# Context failures must happen before any delete.
run_case context_mismatch "${CLEANUP}" failure
assert_no_delete
run_case context_failure "${CLEANUP}" failure
assert_no_delete

# Valid ownership deletes exactly the four explicit targets. Every operation
# after current-context must pin the validated context and use finite timeouts.
run_case valid "${CLEANUP}" success
[[ "$(call_count " get ")" == "4" ]] || fail "valid cleanup did not preflight four targets"
[[ "$(call_count " delete ")" == "4" ]] || fail "valid cleanup did not issue four deletes"
for target in \
  'delete namespace autoscaling-validation ' \
  'delete networkpolicy -n kafka allow-autoscaling-validation ' \
  'delete kafkatopic -n kafka autoscaling-validation-20260930 ' \
  'delete kafkauser -n kafka autoscaling-validation-20260930 '; do
  grep -Fq "${target}" "${LAST_LOG}" || fail "missing explicit delete target: ${target}"
done
awk 'NR > 1 && $0 !~ /^--context petflow-dev / {exit 1}' "${LAST_LOG}" ||
  fail "a post-validation kubectl call did not pin --context petflow-dev"
awk '/ get / && $0 !~ /--request-timeout=15s/ {exit 1}' "${LAST_LOG}" ||
  fail "a get call had no finite request timeout"
awk '/ delete / && ($0 !~ /--request-timeout=15s/ || $0 !~ /--timeout=120s/) {exit 1}' \
  "${LAST_LOG}" || fail "a delete call had no finite timeout"

# A mismatch on the last preflight target must still result in zero deletes.
run_case owner_mismatch "${CLEANUP}" failure
[[ "$(call_count " get ")" == "4" ]] || fail "ownership mismatch skipped a preflight target"
assert_no_delete
grep -q 'KafkaUser/kafka/autoscaling-validation-20260930' "${LAST_OUTPUT}" ||
  fail "ownership failure did not identify KafkaUser"
assert_no_success_message

# NotFound is safe; only resources that exist and are owned are deleted.
run_case partial_notfound "${CLEANUP}" success
[[ "$(call_count " get ")" == "4" ]] || fail "partial NotFound skipped a preflight target"
[[ "$(call_count " delete ")" == "2" ]] || fail "partial NotFound deleted the wrong count"
run_case all_notfound "${CLEANUP}" success
[[ "$(call_count " get ")" == "4" ]] || fail "all NotFound skipped a preflight target"
assert_no_delete

# Lookup and JSON failures stop before all deletion.
for scenario in forbidden get_timeout invalid_json; do
  run_case "${scenario}" "${CLEANUP}" failure
  [[ "$(call_count " get ")" == "4" ]] || fail "${scenario} skipped a preflight target"
  assert_no_delete
  assert_no_success_message
done

# Delete failures and delete timeouts are non-zero and never claim success.
run_case delete_failure "${CLEANUP}" failure
[[ "$(call_count " delete ")" == "2" ]] || fail "delete failure call sequence changed"
assert_no_success_message
grep -q 'NetworkPolicy/kafka/allow-autoscaling-validation' "${LAST_OUTPUT}" ||
  fail "delete failure did not identify NetworkPolicy"

run_case delete_timeout "${CLEANUP}" failure
[[ "$(call_count " delete ")" == "3" ]] || fail "delete timeout call sequence changed"
assert_no_success_message
grep -q 'KafkaTopic/kafka/autoscaling-validation-20260930' "${LAST_OUTPUT}" ||
  fail "delete timeout did not identify KafkaTopic"

echo "autoscaling validation script mocks: PASS"
