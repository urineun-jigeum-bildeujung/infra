#!/usr/bin/env bash
set -euo pipefail

EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-petflow-dev}"
TEST_NAMESPACE="autoscaling-validation"
TEST_TOPIC="autoscaling-validation-20260930"
TEST_KAFKA_USER="autoscaling-validation-20260930"
TEST_NETWORK_POLICY="allow-autoscaling-validation"
OWNER_LABEL="app.kubernetes.io/part-of"
OWNER_VALUE="autoscaling-validation"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-15s}"
DELETE_TIMEOUT="${DELETE_TIMEOUT:-120s}"

for command in kubectl jq; do
  command -v "${command}" >/dev/null
done

if ! validated_context="$(kubectl config current-context)"; then
  echo "ERROR: unable to read the current Kubernetes context" >&2
  exit 1
fi

if [[ "${validated_context}" != "${EXPECTED_CONTEXT}" ]]; then
  echo "ERROR: refusing context ${validated_context}; expected ${EXPECTED_CONTEXT}" >&2
  exit 1
fi

declare -A resource_exists=()
preflight_failed=0

preflight_resource() {
  local key="$1"
  local display_name="$2"
  shift 2
  local resource_json
  local owner_label

  if ! resource_json="$(kubectl --context "${validated_context}" get "$@" \
    --ignore-not-found -o json --request-timeout="${REQUEST_TIMEOUT}")"; then
    echo "ERROR: failed to inspect ${display_name}" >&2
    preflight_failed=1
    resource_exists["${key}"]=0
    return
  fi

  if [[ -z "${resource_json}" ]]; then
    resource_exists["${key}"]=0
    return
  fi

  if ! jq -e 'type == "object" and (.metadata | type == "object")' \
    >/dev/null <<<"${resource_json}"; then
    echo "ERROR: invalid JSON while inspecting ${display_name}" >&2
    preflight_failed=1
    resource_exists["${key}"]=0
    return
  fi

  owner_label="$(jq -r --arg key "${OWNER_LABEL}" \
    '.metadata.labels[$key] // ""' <<<"${resource_json}")"
  if [[ "${owner_label}" != "${OWNER_VALUE}" ]]; then
    echo "ERROR: ${display_name} is not owned by this test; expected label ${OWNER_LABEL}=${OWNER_VALUE}" >&2
    preflight_failed=1
    resource_exists["${key}"]=0
    return
  fi

  resource_exists["${key}"]=1
}

# Inspect every target before deleting any target. This prevents a late
# ownership failure from leaving a partially cleaned environment.
preflight_resource namespace "Namespace/${TEST_NAMESPACE}" \
  namespace "${TEST_NAMESPACE}"
preflight_resource networkpolicy "NetworkPolicy/kafka/${TEST_NETWORK_POLICY}" \
  networkpolicy -n kafka "${TEST_NETWORK_POLICY}"
preflight_resource topic "KafkaTopic/kafka/${TEST_TOPIC}" \
  kafkatopic -n kafka "${TEST_TOPIC}"
preflight_resource kafkauser "KafkaUser/kafka/${TEST_KAFKA_USER}" \
  kafkauser -n kafka "${TEST_KAFKA_USER}"

if ((preflight_failed != 0)); then
  echo "ERROR: cleanup preflight failed; no resources were deleted" >&2
  exit 1
fi

delete_resource() {
  local key="$1"
  local display_name="$2"
  shift 2

  if [[ "${resource_exists[${key}]:-0}" != "1" ]]; then
    return
  fi

  if ! kubectl --context "${validated_context}" delete "$@" --wait=true \
    --timeout="${DELETE_TIMEOUT}" --request-timeout="${REQUEST_TIMEOUT}"; then
    echo "ERROR: failed to delete ${display_name}" >&2
    exit 1
  fi
}

delete_resource namespace "Namespace/${TEST_NAMESPACE}" \
  namespace "${TEST_NAMESPACE}"
delete_resource networkpolicy "NetworkPolicy/kafka/${TEST_NETWORK_POLICY}" \
  networkpolicy -n kafka "${TEST_NETWORK_POLICY}"
delete_resource topic "KafkaTopic/kafka/${TEST_TOPIC}" \
  kafkatopic -n kafka "${TEST_TOPIC}"
delete_resource kafkauser "KafkaUser/kafka/${TEST_KAFKA_USER}" \
  kafkauser -n kafka "${TEST_KAFKA_USER}"

echo "autoscaling validation resources removed"
