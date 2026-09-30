#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/karpenter-cleanup.sh
source "${SCRIPT_DIR}/lib/karpenter-cleanup.sh"

TESTS_RUN=0
DELETE_CALLS=0
DELETE_STARTED=false
MOCK_SCENARIO=""

fail_test() {
  printf '[test-karpenter-cleanup] FAIL: %s\n' "$*" >&2
  exit 1
}

assert_success() {
  local name="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  "$@" || fail_test "${name}"
  printf '[test-karpenter-cleanup] PASS: %s\n' "${name}"
}

assert_failure() {
  local name="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@"; then
    fail_test "${name}: 실패해야 하는 호출이 성공했습니다."
  fi
  printf '[test-karpenter-cleanup] PASS: %s\n' "${name}"
}

mock_reset() {
  MOCK_SCENARIO="$1"
  DELETE_CALLS=0
  DELETE_STARTED=false
  KARPENTER_CLEANUP_TIMEOUT_SECONDS=2
  KARPENTER_CLEANUP_POLL_SECONDS=1
}

karpenter_sleep() {
  :
}

karpenter_kubectl() {
  local args="$*"

  if [[ "${MOCK_SCENARIO}" == "kube_failure" && "${args}" == "get crd nodeclaims.karpenter.sh --ignore-not-found -o name" ]]; then
    return 1
  fi

  case "${args}" in
    "get statefulset argocd-application-controller --namespace argocd --ignore-not-found -o json"|\
    "get deployment argocd-application-controller --namespace argocd --ignore-not-found -o json")
      printf '%s' '{"spec":{"replicas":0},"status":{"readyReplicas":0}}'
      ;;
    "get crd nodeclaims.karpenter.sh --ignore-not-found -o name")
      if [[ "${MOCK_SCENARIO}" != "no_crds" ]]; then
        printf '%s' 'customresourcedefinition.apiextensions.k8s.io/nodeclaims.karpenter.sh'
      fi
      ;;
    "get crd nodepools.karpenter.sh --ignore-not-found -o name")
      if [[ "${MOCK_SCENARIO}" != "no_crds" ]]; then
        printf '%s' 'customresourcedefinition.apiextensions.k8s.io/nodepools.karpenter.sh'
      fi
      ;;
    "get nodeclaims -o json")
      if [[ "${DELETE_STARTED}" == true && "${MOCK_SCENARIO}" == "success" ]]; then
        printf '%s' '{"items":[]}'
      elif [[ "${MOCK_SCENARIO}" == "empty" || "${MOCK_SCENARIO}" == "no_crds" || "${MOCK_SCENARIO}" == "orphan" || "${MOCK_SCENARIO}" == "nodepool_only" ]]; then
        printf '%s' '{"items":[]}'
      else
        printf '%s' '{"items":[{"metadata":{"name":"claim-a"},"status":{"providerID":"aws:///ap-northeast-2b/i-0123456789abcdef0"}}]}'
      fi
      ;;
    "get nodepools -o json")
      if [[ "${MOCK_SCENARIO}" == "empty" || "${MOCK_SCENARIO}" == "no_crds" || "${MOCK_SCENARIO}" == "orphan" || ("${DELETE_STARTED}" == true && "${MOCK_SCENARIO}" == "nodepool_only") ]]; then
        printf '%s' '{"items":[]}'
      else
        printf '%s' '{"items":[{"metadata":{"name":"on-demand"}}]}'
      fi
      ;;
    "get deployment karpenter --namespace kube-system -o json")
      printf '%s' '{"spec":{"replicas":2},"status":{"availableReplicas":2}}'
      ;;
    "delete nodepools --all --wait=false"|"delete nodeclaims --all --wait=false")
      DELETE_CALLS=$((DELETE_CALLS + 1))
      DELETE_STARTED=true
      ;;
    *)
      # timeout 진단 명령은 성공한 빈 출력으로 처리한다.
      ;;
  esac
}

karpenter_aws() {
  local args="$*"

  [[ "${args}" == *"Name=tag:kubernetes.io/cluster/petflow-eks,Values=owned"* ]] \
    || fail_test "대상 클러스터 owned 태그 필터가 없습니다."
  [[ "${args}" == *"Name=tag-key,Values=karpenter.sh/nodepool"* ]] \
    || fail_test "Karpenter NodePool 태그 필터가 없습니다."
  [[ "${args}" == *"--region ap-northeast-2"* ]] \
    || fail_test "대상 Region 필터가 없습니다."

  if [[ "${MOCK_SCENARIO}" == "aws_failure" ]]; then
    return 1
  fi
  if [[ "${MOCK_SCENARIO}" == "empty" || "${MOCK_SCENARIO}" == "no_crds" || "${MOCK_SCENARIO}" == "nodepool_only" || \
        ("${DELETE_STARTED}" == true && "${MOCK_SCENARIO}" == "success") ]]; then
    printf '%s' '[]'
  else
    printf '%s' '[{"InstanceId":"i-0123456789abcdef0","State":"running","Tags":[{"Key":"kubernetes.io/cluster/petflow-eks","Value":"owned"},{"Key":"karpenter.sh/nodepool","Value":"on-demand"}]}]'
  fi
}

run_cleanup() {
  cleanup_karpenter_nodes petflow-eks ap-northeast-2
}

test_empty() {
  mock_reset empty
  run_cleanup
  [[ "${DELETE_CALLS}" -eq 0 ]]
}

test_no_crds_rerun() {
  mock_reset no_crds
  run_cleanup
  [[ "${DELETE_CALLS}" -eq 0 ]]
}

test_success() {
  mock_reset success
  run_cleanup
  [[ "${DELETE_CALLS}" -eq 2 ]]
}

test_nodepool_only() {
  mock_reset nodepool_only
  run_cleanup
  [[ "${DELETE_CALLS}" -eq 1 ]]
}

test_timeout() {
  mock_reset timeout
  run_cleanup
}

test_kube_failure() {
  mock_reset kube_failure
  if run_cleanup; then
    return 0
  fi
  [[ "${DELETE_CALLS}" -eq 0 ]] || return 1
  return 1
}

test_aws_failure() {
  mock_reset aws_failure
  run_cleanup
}

test_orphan_ec2() {
  mock_reset orphan
  if run_cleanup; then
    return 1
  fi
  [[ "${DELETE_CALLS}" -eq 0 ]]
}

test_flow_order() {
  local cleanup_file="${SCRIPT_DIR}/../cleanup-k8s.sh"
  local destroy_file="${SCRIPT_DIR}/../tdestroy.sh"
  local pre_guard_line
  local karpenter_line
  local post_guard_line
  local cleanup_call_line
  local destroy_call_line

  pre_guard_line="$(grep -n 'verify_cnpg_backup_evidence "pre-kubernetes-cleanup"' "${cleanup_file}" | cut -d: -f1)"
  karpenter_line="$(grep -n '^cleanup_karpenter_nodes ' "${cleanup_file}" | cut -d: -f1)"
  post_guard_line="$(grep -n 'verify_cnpg_backup_evidence "post-pvc-cleanup"' "${cleanup_file}" | cut -d: -f1)"
  cleanup_call_line="$(grep -n 'cleanup-k8s.sh.*--backup-manifest' "${destroy_file}" | cut -d: -f1)"
  destroy_call_line="$(grep -n 'destroy-infra.sh' "${destroy_file}" | tail -1 | cut -d: -f1)"

  ((pre_guard_line < karpenter_line && karpenter_line < post_guard_line)) || return 1
  ((cleanup_call_line < destroy_call_line)) || return 1
}

assert_success "대상 없음 no-op" test_empty
assert_success "MNG/타 클러스터 제외 태그 필터" test_empty
assert_success "미설치/재실행 no-op" test_no_crds_rerun
assert_success "NodeClaim 및 EC2 정상 종료" test_success
assert_success "빈 NodePool 제거로 재생성 차단" test_nodepool_only
assert_failure "종료 timeout 시 중단" test_timeout
assert_failure "Kubernetes 조회 실패 시 중단" test_kube_failure
assert_failure "AWS 조회 실패 시 중단" test_aws_failure
assert_success "NodeClaim 없는 잔여 EC2 자동 삭제 금지" test_orphan_ec2
assert_success "Backup/Karpenter Guard 실패 시 destroy 전 중단 순서" test_flow_order

printf '[test-karpenter-cleanup] %d tests passed.\n' "${TESTS_RUN}"
