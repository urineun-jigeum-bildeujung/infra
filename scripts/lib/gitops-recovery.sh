#!/usr/bin/env bash
# Sourced by tapply.sh. Recovery changes no Git revisions, Secret values or prune policy.
declare -A GITOPS_RECOVERY_ATTEMPTS=()
declare -A GITOPS_RECOVERY_LAST_ATTEMPT=()

gitops_kubectl() {
  kubectl --context "${KUBECONFIG_CONTEXT}" --request-timeout=30s "$@"
}

prepare_gitops_dependencies() {
  # ExternalSecrets/RBAC can reference namespaces before service Applications sync.
  gitops_kubectl apply -f "${GITOPS_DIR}/platform/05-namespaces/manifests/namespaces.yaml" || return 1
  gitops_kubectl create namespace web --dry-run=client -o json | gitops_kubectl apply -f - || return 1
  # Prevent platform-root from being reconciled before its AppProject exists.
  gitops_kubectl apply -f "${GITOPS_DIR}/projects/"
}

gitops_retry_repo_failure() {
  local applications="$1" name application payload now attempts last
  # Retry only after the repository renderer is available again.
  gitops_kubectl get deployment argocd-repo-server -n argocd -o json \
    | jq -e '(.spec.replicas // 0) > 0 and
      (.status.observedGeneration // 0) >= .metadata.generation and
      (.status.availableReplicas // 0) == .spec.replicas' >/dev/null || return 0
  name=$(jq -r '[.items[] | select(
      (.spec.project == "services" or .metadata.name == "external-secrets-config") and
      .status.sync.status != "Synced" and .operation == null and
      (.status.operationState.phase == "Error" or .status.operationState.phase == "Failed") and
      ((.status.operationState.message // "") |
        test("ComparisonError:.*failed to generate manifest.*(DeadlineExceeded|connection refused|connection reset|transport.*Error while dialing)"))
    ) | .metadata.name] | .[]' <<<"$applications")
  now=$(date +%s)
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    attempts=${GITOPS_RECOVERY_ATTEMPTS[$name]:-0}
    last=${GITOPS_RECOVERY_LAST_ATTEMPT[$name]:-0}
    (( attempts < 2 && now - last >= 60 )) || continue
    # Re-read before mutation: never overwrite an active or newly completed sync.
    application=$(gitops_kubectl get application "$name" -n argocd -o json) || return 0
    jq -e '.operation == null and .status.sync.status != "Synced" and
      (.status.operationState.phase == "Error" or .status.operationState.phase == "Failed") and
      ((.status.operationState.message // "") |
        test("ComparisonError:.*failed to generate manifest.*(DeadlineExceeded|connection refused|connection reset|transport.*Error while dialing)"))' \
      <<<"$application" >/dev/null || continue
    payload=$(jq -c '{operation:{initiatedBy:{username:"tapply-recovery"},
      sync:{prune:false,syncOptions:((.spec.syncPolicy.syncOptions // []) + ["CreateNamespace=true"] | unique)},
      retry:{limit:2,backoff:{duration:"20s",factor:2,maxDuration:"2m"}}}}' <<<"$application")
    if gitops_kubectl patch application "$name" -n argocd --type merge -p "$payload" >/dev/null; then
      GITOPS_RECOVERY_ATTEMPTS[$name]=$((attempts + 1))
      GITOPS_RECOVERY_LAST_ATTEMPT[$name]=$now
      log "repo-server 회복 후 ${name} 재동기화 요청 ($((attempts + 1))/2, 기존 syncOptions 유지)"
    fi
    # Avoid reloading the renderer with every failed Application at once.
    return 0
  done <<<"$name"
}

wait_for_service_gitops_sync() {
  local deadline applications pending secrets secrets_ready
  deadline=$(($(date +%s) + AUTOSCALING_READY_TIMEOUT_SECONDS))
  while (( $(date +%s) < deadline )); do
    applications=$(gitops_kubectl get applications -n argocd -o json) || return 1
    gitops_retry_repo_failure "$applications"
    pending=$(jq -r '[.items[] | select(.spec.project == "services" or
      .metadata.name == "external-secrets-config") |
      select(.status.sync.status != "Synced" or .operation != null) | .metadata.name] | join(",")' <<<"$applications")
    secrets_ready=false
    if secrets=$(gitops_kubectl get externalsecret -n web juso-credentials -o json 2>/dev/null); then
      if jq -e 'any(.status.conditions[]?; .type == "Ready" and .status == "True")' <<<"$secrets" >/dev/null; then
        secrets_ready=true
      fi
    fi
    # Do not mistake an empty Application list for successful service deployment.
    if [[ -z $pending && $secrets_ready == true ]] && jq -e '
      [.items[].metadata.name] as $names |
      all(["dev-auth-service","dev-member-service","dev-product-service",
        "dev-review-service","dev-payment-service","dev-web","external-secrets-config"][];
        . as $name | $names | index($name) != null)' <<<"$applications" >/dev/null; then
      log '서비스 GitOps 동기화와 Web ExternalSecret 준비 완료'
      return 0
    fi
    log "서비스 GitOps 준비 대기 중: pending=${pending:-Application 생성 대기}, webSecret=${secrets_ready}"
    sleep "${AUTOSCALING_READY_POLL_INTERVAL_SECONDS}"
  done
  gitops_kubectl get applications -n argocd \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PHASE:.status.operationState.phase' >&2 || true
  return 1
}
