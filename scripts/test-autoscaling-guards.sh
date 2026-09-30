#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_CONTEXT="test"
EXPECTED_AWS_REGION=ap-northeast-2
AUTOSCALING_READY_TIMEOUT_SECONDS=1
AUTOSCALING_READY_POLL_INTERVAL_SECONDS=1

log() { :; }

# shellcheck source=scripts/lib/autoscaling-guards.sh
source "${SCRIPT_DIR}/lib/autoscaling-guards.sh"

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

test_mng_count_excludes_karpenter_nodes() {
  autoscaling_kubectl() {
    printf '%s\n' '{"items":[
      {"metadata":{"labels":{"eks.amazonaws.com/nodegroup":"petflow-node-group"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
      {"metadata":{"labels":{"eks.amazonaws.com/nodegroup":"petflow-node-group"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
      {"metadata":{"labels":{"karpenter.sh/nodepool":"on-demand"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}
    ]}'
  }
  [[ "$(count_ready_managed_nodes petflow-node-group)" == "2" ]] \
    || fail_test "Karpenter node was counted as an MNG node"
}

test_metrics_success() {
  aws() { printf 'ACTIVE\n'; }
  autoscaling_deployment_ready() { return 0; }
  autoscaling_kubectl() {
    if [[ " $* " == *" --raw "* ]]; then
      printf '%s\n' '{"items":[{}]}'
    else
      printf '%s\n' '{"status":{"conditions":[{"type":"Available","status":"True"}]}}'
    fi
  }
  wait_for_metrics_server petflow-eks ap-northeast-2 \
    || fail_test "ready Metrics Server did not pass"
}

test_keda_inactive_is_not_failure() {
  autoscaling_application_ready() { return 0; }
  autoscaling_deployment_ready() { return 0; }
  autoscaling_crd_established() { return 0; }
  autoscaling_kubectl() {
    printf '%s\n' '{"status":{"conditions":[{"type":"Available","status":"True"}]}}'
  }
  wait_for_keda petflow-eks ap-northeast-2 \
    || fail_test "ready but inactive KEDA did not pass"
}

test_karpenter_zero_nodes_is_not_failure() {
  autoscaling_application_ready() { return 0; }
  autoscaling_deployment_ready() { return 0; }
  autoscaling_crd_established() { return 0; }
  autoscaling_condition_true() { return 0; }
  wait_for_karpenter petflow-eks ap-northeast-2 \
    || fail_test "ready Karpenter with zero NodeClaims did not pass"
}

test_missing_target_times_out() {
  autoscaling_condition_true() { return 1; }
  autoscaling_kubectl() { return 1; }
  diagnose_autoscaling() { :; }
  if wait_for_autoscaling_targets petflow-eks ap-northeast-2; then
    fail_test "missing autoscaling target was accepted"
  fi
}

test_mng_count_excludes_karpenter_nodes
test_metrics_success
test_keda_inactive_is_not_failure
test_karpenter_zero_nodes_is_not_failure
test_missing_target_times_out

printf 'autoscaling guard tests passed\n'
