#!/usr/bin/env bash

# tapply.sh에서 source한다. 이 파일은 Secret/ConfigMap 본문을 출력하지 않는다.

autoscaling_kubectl() {
  kubectl --context "${KUBECONFIG_CONTEXT}" "$@"
}

count_ready_managed_nodes() {
  local node_group_name="$1"

  autoscaling_kubectl get nodes -o json 2>/dev/null \
    | jq --arg node_group "${node_group_name}" \
      '[.items[] | select(.metadata.labels["eks.amazonaws.com/nodegroup"] == $node_group) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length'
}

autoscaling_condition_true() {
  local namespace="$1"
  local resource="$2"
  local name="$3"
  local condition_type="$4"

  autoscaling_kubectl --namespace "${namespace}" get "${resource}" "${name}" -o json 2>/dev/null \
    | jq -e --arg type "${condition_type}" \
      'any(.status.conditions[]?; .type == $type and .status == "True")' >/dev/null
}

autoscaling_crd_established() {
  local name="$1"

  autoscaling_kubectl get crd "${name}" -o json 2>/dev/null \
    | jq -e 'any(.status.conditions[]?; .type == "Established" and .status == "True")' >/dev/null
}

autoscaling_application_ready() {
  local name="$1"

  autoscaling_kubectl --namespace argocd get application "${name}" -o json 2>/dev/null \
    | jq -e '.status.sync.status == "Synced" and .status.health.status == "Healthy"' >/dev/null
}

autoscaling_refresh_completed_crd_sync() {
  local name="$1"
  # A newly installed CRD can be absent from Argo CD's comparison cache even
  # after a successful sync. Refresh once, retaining the Synced/Healthy gate.
  autoscaling_kubectl --namespace argocd get application "${name}" -o json \
    | jq -e '.status.sync.status == "OutOfSync"
      and .status.health.status == "Healthy"
      and .status.operationState.phase == "Succeeded"
      and ((.status.conditions // []) | length == 0)
      and ([.status.resources[]? | select(.status != "Synced")] |
        length > 0 and all(.kind == "CustomResourceDefinition"))' >/dev/null || return 1
  autoscaling_kubectl --namespace argocd annotate application "${name}" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null || return 1
  log "${name} CRD 설치 완료 후 비교 캐시 갱신 요청"
}

autoscaling_deployment_ready() {
  local namespace="$1"
  local name="$2"

  autoscaling_kubectl --namespace "${namespace}" get deployment "${name}" -o json 2>/dev/null \
    | jq -e '(.spec.replicas // 0) > 0 and (.status.observedGeneration // 0) >= .metadata.generation and (.status.availableReplicas // 0) == .spec.replicas' >/dev/null
}

diagnose_autoscaling() {
  log "Autoscaling 복구 진단 정보를 출력합니다. Secret 값은 출력하지 않습니다."
  aws eks describe-addon --cluster-name "${1:-petflow-eks}" --addon-name metrics-server \
    --region "${2:-${EXPECTED_AWS_REGION}}" \
    --query 'addon.{Status:status,Version:addonVersion,Issues:health.issues[*].code}' --output table >&2 || true
  autoscaling_kubectl --namespace argocd get application \
    keda karpenter-crd karpenter karpenter-config \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' >&2 || true
  autoscaling_kubectl --namespace kube-system get deployment metrics-server karpenter overprovisioning -o wide >&2 || true
  autoscaling_kubectl --namespace keda get deployment -o wide >&2 || true
  autoscaling_kubectl get apiservice v1beta1.metrics.k8s.io v1beta1.external.metrics.k8s.io -o wide >&2 || true
  autoscaling_kubectl get hpa -A -o wide >&2 || true
  autoscaling_kubectl get scaledobject.keda.sh -A \
    -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,ACTIVE:.status.conditions[?(@.type=="Active")].status' >&2 || true
  autoscaling_kubectl get ec2nodeclass,nodepool,nodeclaim -A -o wide >&2 || true
  autoscaling_kubectl get nodes \
    -o custom-columns='NAME:.metadata.name,MNG:.metadata.labels.eks\.amazonaws\.com/nodegroup,NODEPOOL:.metadata.labels.karpenter\.sh/nodepool,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,READY:.status.conditions[?(@.type=="Ready")].status' >&2 || true
  autoscaling_kubectl get pods -A --field-selector=status.phase=Pending -o wide >&2 || true
  autoscaling_kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -n 60 >&2 || true
  autoscaling_kubectl --namespace keda logs deployment/keda-operator --tail=100 >&2 || true
  autoscaling_kubectl --namespace kube-system logs deployment/karpenter --tail=100 >&2 || true
}

wait_for_metrics_server() {
  local cluster_name="$1"
  local aws_region="$2"
  local deadline addon_status api_available metric_node_count metric_pod_count

  deadline=$(($(date +%s) + AUTOSCALING_READY_TIMEOUT_SECONDS))
  while (( $(date +%s) < deadline )); do
    addon_status="$(aws eks describe-addon --cluster-name "${cluster_name}" --addon-name metrics-server \
      --region "${aws_region}" --query 'addon.status' --output text 2>/dev/null || true)"
    api_available="$(autoscaling_kubectl get apiservice v1beta1.metrics.k8s.io -o json 2>/dev/null \
      | jq -r '[.status.conditions[]? | select(.type == "Available")][0].status // "False"' || true)"
    metric_node_count="$(autoscaling_kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes 2>/dev/null \
      | jq '.items | length' 2>/dev/null || printf '0')"
    metric_pod_count="$(autoscaling_kubectl get --raw /apis/metrics.k8s.io/v1beta1/pods 2>/dev/null \
      | jq '.items | length' 2>/dev/null || printf '0')"

    if [[ "${addon_status}" == "ACTIVE" && "${api_available}" == "True" \
      && "${metric_node_count}" =~ ^[1-9][0-9]*$ \
      && "${metric_pod_count}" =~ ^[1-9][0-9]*$ ]] \
      && autoscaling_deployment_ready kube-system metrics-server; then
      log "Metrics Server 준비 완료: addon=${addon_status}, APIService=${api_available}, metricNodes=${metric_node_count}, metricPods=${metric_pod_count}"
      return 0
    fi

    log "Metrics Server 준비 대기 중: addon=${addon_status:-unknown}, APIService=${api_available:-False}, metricNodes=${metric_node_count:-0}, metricPods=${metric_pod_count:-0}"
    sleep "${AUTOSCALING_READY_POLL_INTERVAL_SECONDS}"
  done

  diagnose_autoscaling "${cluster_name}" "${aws_region}"
  return 1
}

wait_for_keda() {
  local cluster_name="$1"
  local aws_region="$2"
  local deadline external_api_available ready=true deployment_name crd_name
  local crd_refresh_requested=false

  deadline=$(($(date +%s) + AUTOSCALING_READY_TIMEOUT_SECONDS))
  while (( $(date +%s) < deadline )); do
    ready=true
    if ! autoscaling_application_ready keda; then
      ready=false
      if [[ "${crd_refresh_requested}" == false ]] && autoscaling_refresh_completed_crd_sync keda; then
        crd_refresh_requested=true
      fi
    fi
    for deployment_name in keda-operator keda-operator-metrics-apiserver keda-admission-webhooks; do
      autoscaling_deployment_ready keda "${deployment_name}" || ready=false
    done
    for crd_name in scaledobjects.keda.sh triggerauthentications.keda.sh; do
      autoscaling_crd_established "${crd_name}" || ready=false
    done
    external_api_available="$(autoscaling_kubectl get apiservice v1beta1.external.metrics.k8s.io -o json 2>/dev/null \
      | jq -r '[.status.conditions[]? | select(.type == "Available")][0].status // "False"' || true)"
    [[ "${external_api_available}" == "True" ]] || ready=false

    if [[ "${ready}" == true ]]; then
      log "KEDA 준비 완료: Application Synced/Healthy, deployments=3/3, externalMetrics=True"
      return 0
    fi
    log "KEDA 준비 대기 중: externalMetrics=${external_api_available:-False}"
    sleep "${AUTOSCALING_READY_POLL_INTERVAL_SECONDS}"
  done

  diagnose_autoscaling "${cluster_name}" "${aws_region}"
  return 1
}

wait_for_karpenter() {
  local cluster_name="$1"
  local aws_region="$2"
  local deadline ready=true application_name crd_name

  deadline=$(($(date +%s) + AUTOSCALING_READY_TIMEOUT_SECONDS))
  while (( $(date +%s) < deadline )); do
    ready=true
    for application_name in karpenter-crd karpenter karpenter-config; do
      autoscaling_application_ready "${application_name}" || ready=false
    done
    autoscaling_deployment_ready kube-system karpenter || ready=false
    for crd_name in nodepools.karpenter.sh nodeclaims.karpenter.sh ec2nodeclasses.karpenter.k8s.aws; do
      autoscaling_crd_established "${crd_name}" || ready=false
    done
    autoscaling_condition_true kube-system ec2nodeclass.karpenter.k8s.aws default Ready || ready=false
    autoscaling_condition_true kube-system nodepool.karpenter.sh on-demand Ready || ready=false

    if [[ "${ready}" == true ]]; then
      log "Karpenter 준비 완료: CRD/controller/config 및 NodeClass/NodePool Ready"
      return 0
    fi
    log "Karpenter 준비 대기 중"
    sleep "${AUTOSCALING_READY_POLL_INTERVAL_SECONDS}"
  done

  diagnose_autoscaling "${cluster_name}" "${aws_region}"
  return 1
}

wait_for_autoscaling_targets() {
  local cluster_name="$1"
  local aws_region="$2"
  local deadline ready=true namespace hpa_name pdb_name
  local -a namespaces=(auth-service member-service product-service review-service)

  deadline=$(($(date +%s) + AUTOSCALING_READY_TIMEOUT_SECONDS))
  while (( $(date +%s) < deadline )); do
    ready=true
    for namespace in "${namespaces[@]}"; do
      hpa_name="${namespace}-hpa"
      pdb_name="${namespace}-pdb"
      autoscaling_condition_true "${namespace}" hpa "${hpa_name}" AbleToScale || ready=false
      autoscaling_condition_true "${namespace}" hpa "${hpa_name}" ScalingActive || ready=false
      autoscaling_kubectl --namespace "${namespace}" get pdb "${pdb_name}" -o json 2>/dev/null \
        | jq -e '.spec.selector.matchLabels["app.kubernetes.io/name"] == "generic-service"' >/dev/null \
        || ready=false
    done
    autoscaling_condition_true payment-service scaledobject.keda.sh payment-service-scaler Ready || ready=false
    autoscaling_condition_true payment-service hpa keda-hpa-payment-service-scaler AbleToScale || ready=false
    autoscaling_condition_true payment-service hpa keda-hpa-payment-service-scaler ScalingActive || ready=false

    if [[ "${ready}" == true ]]; then
      log "서비스 Autoscaling 준비 완료: HPA/PDB=4/4, payment ScaledObject/HPA=Ready"
      return 0
    fi
    log "서비스 HPA/PDB/KEDA 대상 준비 대기 중"
    sleep "${AUTOSCALING_READY_POLL_INTERVAL_SECONDS}"
  done

  diagnose_autoscaling "${cluster_name}" "${aws_region}"
  return 1
}
