#!/usr/bin/env bash
# Karpenter가 생성한 DEV NodeClaim/EC2를 Terraform destroy 전에 정상 종료한다.
# 호출자는 AWS 계정/Region/EKS cluster 검증과 Argo CD 중지를 먼저 완료해야 한다.

karpenter_cleanup_log() {
  printf '[cleanup-k8s] %s\n' "$*"
}

karpenter_cleanup_error() {
  printf '[cleanup-k8s] %s\n' "$*" >&2
}

karpenter_kubectl() {
  "${KUBECTL[@]}" "$@"
}

karpenter_aws() {
  aws "$@"
}

karpenter_sleep() {
  sleep "$1"
}

karpenter_get_resource_json() {
  local resource="$1"
  local result

  if ! result="$(karpenter_kubectl get "${resource}" -o json)"; then
    karpenter_cleanup_error "Karpenter ${resource} 조회에 실패했습니다. 리소스 0개로 취급하지 않습니다."
    return 1
  fi

  if ! jq -e '.items | type == "array"' >/dev/null <<< "${result}"; then
    karpenter_cleanup_error "Karpenter ${resource} 조회 결과가 올바른 Kubernetes List JSON이 아닙니다."
    return 1
  fi

  printf '%s' "${result}"
}

karpenter_crd_exists() {
  local crd_name="$1"
  local result

  if ! result="$(karpenter_kubectl get crd "${crd_name}" --ignore-not-found -o name)"; then
    karpenter_cleanup_error "Karpenter CRD 존재 여부를 확인하지 못했습니다: ${crd_name}"
    return 2
  fi

  [[ -n "${result}" ]]
}

karpenter_verify_argocd_stopped() {
  local kind
  local controller_json
  local desired
  local ready

  for kind in statefulset deployment; do
    if ! controller_json="$(karpenter_kubectl get "${kind}" argocd-application-controller \
      --namespace argocd --ignore-not-found -o json)"; then
      karpenter_cleanup_error "Argo CD Application Controller 상태를 확인하지 못했습니다."
      return 1
    fi

    [[ -z "${controller_json}" ]] && continue
    desired="$(jq -r '.spec.replicas // 0' <<< "${controller_json}")"
    ready="$(jq -r '.status.readyReplicas // 0' <<< "${controller_json}")"
    if ((desired != 0 || ready != 0)); then
      karpenter_cleanup_error "Argo CD Application Controller가 아직 동작 중입니다: kind=${kind}, desired=${desired}, ready=${ready}"
      return 1
    fi
  done

  karpenter_cleanup_log "Argo CD Application Controller 중지 상태 확인 완료"
}

karpenter_get_owned_instances_json() {
  local cluster_name="$1"
  local aws_region="$2"
  local result

  # 두 태그를 모두 요구해 MNG와 다른 클러스터의 EC2를 제외한다. terminated는
  # 종료 완료로 간주하므로 조회 대상에서 제외한다.
  if ! result="$(karpenter_aws ec2 describe-instances \
    --region "${aws_region}" \
    --filters \
      "Name=tag:kubernetes.io/cluster/${cluster_name},Values=owned" \
      "Name=tag-key,Values=karpenter.sh/nodepool" \
      "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
    --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Tags:Tags}' \
    --output json)"; then
    karpenter_cleanup_error "${cluster_name} 소유 Karpenter EC2 조회에 실패했습니다. 인스턴스 0개로 취급하지 않습니다."
    return 1
  fi

  if ! jq -e 'type == "array" and all(.[]; (.InstanceId | (type == "string" and test("^i-[0-9a-f]+$"))) and (.State | type == "string"))' \
    >/dev/null <<< "${result}"; then
    karpenter_cleanup_error "Karpenter EC2 조회 결과가 올바른 JSON 배열이 아닙니다."
    return 1
  fi

  printf '%s' "${result}"
}

karpenter_extract_claim_instance_ids() {
  local nodeclaims_json="$1"
  local provider_id

  while IFS= read -r provider_id; do
    [[ -z "${provider_id}" ]] && continue
    if [[ ! "${provider_id}" =~ /((i-[0-9a-f]+))$ ]]; then
      karpenter_cleanup_error "NodeClaim providerID 형식을 확인할 수 없습니다: ${provider_id}"
      return 1
    fi
    printf '%s\n' "${BASH_REMATCH[1]}"
  done < <(jq -r '.items[] | .status.providerID // empty' <<< "${nodeclaims_json}")
}

karpenter_array_contains() {
  local expected="$1"
  shift
  local item

  for item in "$@"; do
    [[ "${item}" == "${expected}" ]] && return 0
  done
  return 1
}

karpenter_verify_controller_available() {
  local controller_json
  local desired
  local available

  if ! controller_json="$(karpenter_kubectl get deployment karpenter \
    --namespace karpenter -o json)"; then
    karpenter_cleanup_error "Karpenter Controller 상태를 확인하지 못했습니다."
    return 1
  fi

  desired="$(jq -r '.spec.replicas // 0' <<< "${controller_json}")"
  available="$(jq -r '.status.availableReplicas // 0' <<< "${controller_json}")"
  if ((desired < 1 || available < 1)); then
    karpenter_cleanup_error "Karpenter Controller가 정상 동작 중이 아닙니다: desired=${desired}, available=${available}"
    return 1
  fi
}

karpenter_cleanup_diagnostics() {
  local cluster_name="$1"
  local aws_region="$2"

  karpenter_cleanup_error "Karpenter 정리 진단 정보를 출력합니다. 강제 종료나 finalizer 제거는 수행하지 않습니다."
  karpenter_kubectl get nodepools,nodeclaims -o wide >&2 || true
  karpenter_kubectl get nodes -l karpenter.sh/nodepool -o wide >&2 || true
  karpenter_get_owned_instances_json "${cluster_name}" "${aws_region}" >&2 || true
  karpenter_kubectl logs deployment/karpenter --namespace karpenter --tail=100 >&2 || true
  karpenter_kubectl get events --all-namespaces --sort-by=.lastTimestamp >&2 || true
}

cleanup_karpenter_nodes() {
  local cluster_name="$1"
  local aws_region="$2"
  local timeout_seconds="${KARPENTER_CLEANUP_TIMEOUT_SECONDS:-900}"
  local poll_seconds="${KARPENTER_CLEANUP_POLL_SECONDS:-10}"
  local nodeclaim_crd=false
  local nodepool_crd=false
  local nodeclaims_json='{"items":[]}'
  local nodepools_json='{"items":[]}'
  local owned_instances_json
  local nodeclaim_count
  local nodepool_count
  local owned_count
  local claim_id
  local instance_id
  local claim_instance_lines
  local crd_status
  local attempt
  local max_attempts
  local -a claim_instance_ids=()
  local -a owned_instance_ids=()

  if [[ ! "${timeout_seconds}" =~ ^[1-9][0-9]*$ || ! "${poll_seconds}" =~ ^[1-9][0-9]*$ ]]; then
    karpenter_cleanup_error "Karpenter timeout/poll 값은 양의 정수여야 합니다."
    return 1
  fi

  karpenter_verify_argocd_stopped || return 1

  crd_status=0
  karpenter_crd_exists nodeclaims.karpenter.sh || crd_status=$?
  if ((crd_status == 0)); then
    nodeclaim_crd=true
    nodeclaims_json="$(karpenter_get_resource_json nodeclaims)" || return 1
  elif ((crd_status != 1)); then
    return 1
  fi
  crd_status=0
  karpenter_crd_exists nodepools.karpenter.sh || crd_status=$?
  if ((crd_status == 0)); then
    nodepool_crd=true
    nodepools_json="$(karpenter_get_resource_json nodepools)" || return 1
  elif ((crd_status != 1)); then
    return 1
  fi

  owned_instances_json="$(karpenter_get_owned_instances_json "${cluster_name}" "${aws_region}")" || return 1
  nodeclaim_count="$(jq '.items | length' <<< "${nodeclaims_json}")"
  nodepool_count="$(jq '.items | length' <<< "${nodepools_json}")"
  owned_count="$(jq 'length' <<< "${owned_instances_json}")"

  claim_instance_lines="$(karpenter_extract_claim_instance_ids "${nodeclaims_json}")" || return 1
  if [[ -n "${claim_instance_lines}" ]]; then
    mapfile -t claim_instance_ids <<< "${claim_instance_lines}"
  fi
  mapfile -t owned_instance_ids < <(jq -r '.[].InstanceId' <<< "${owned_instances_json}")

  karpenter_cleanup_log "Karpenter 정리 대상: NodePool=${nodepool_count}, NodeClaim=${nodeclaim_count}, EC2=${owned_count}"

  if ((nodepool_count == 0 && nodeclaim_count == 0 && owned_count == 0)); then
    karpenter_cleanup_log "정리할 Karpenter NodePool/NodeClaim/EC2가 없습니다."
    return 0
  fi

  # NodeClaim에 연결된 인스턴스는 반드시 대상 클러스터 owned 태그와 NodePool 태그를
  # 모두 가져야 한다. 반대로 태그 대상 EC2에 NodeClaim이 없으면 고아 인스턴스이므로
  # 자동 terminate하지 않고 중단한다.
  for claim_id in "${claim_instance_ids[@]}"; do
    if ! karpenter_array_contains "${claim_id}" "${owned_instance_ids[@]}"; then
      karpenter_cleanup_error "NodeClaim EC2의 클러스터 소유권을 확인할 수 없습니다: ${claim_id}"
      return 1
    fi
  done
  for instance_id in "${owned_instance_ids[@]}"; do
    if ! karpenter_array_contains "${instance_id}" "${claim_instance_ids[@]}"; then
      karpenter_cleanup_error "NodeClaim 없이 남은 Karpenter EC2를 발견했습니다: ${instance_id}"
      karpenter_cleanup_error "소유권을 확인한 뒤 수동 조치하세요. 자동 terminate하지 않습니다."
      return 1
    fi
  done

  karpenter_verify_controller_available || return 1

  if [[ "${nodepool_crd}" == true && "${nodepool_count}" -gt 0 ]]; then
    karpenter_cleanup_log "NodePool 삭제 요청으로 신규 NodeClaim 생성을 차단합니다."
    karpenter_kubectl delete nodepools --all --wait=false || return 1
  fi
  if [[ "${nodeclaim_crd}" == true && "${nodeclaim_count}" -gt 0 ]]; then
    karpenter_cleanup_log "검증된 NodeClaim 정상 삭제를 요청합니다."
    karpenter_kubectl delete nodeclaims --all --wait=false || return 1
  fi

  max_attempts=$(((timeout_seconds + poll_seconds - 1) / poll_seconds))
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if [[ "${nodeclaim_crd}" == true ]]; then
      nodeclaims_json="$(karpenter_get_resource_json nodeclaims)" || return 1
    else
      nodeclaims_json='{"items":[]}'
    fi
    owned_instances_json="$(karpenter_get_owned_instances_json "${cluster_name}" "${aws_region}")" || return 1
    nodeclaim_count="$(jq '.items | length' <<< "${nodeclaims_json}")"
    owned_count="$(jq 'length' <<< "${owned_instances_json}")"

    if ((nodeclaim_count == 0 && owned_count == 0)); then
      karpenter_cleanup_log "Karpenter NodeClaim 삭제 및 EC2 종료 확인 완료"
      return 0
    fi

    karpenter_cleanup_log "Karpenter 종료 대기 중: NodeClaim=${nodeclaim_count}, EC2=${owned_count}, attempt=${attempt}/${max_attempts}"
    if ((attempt < max_attempts)); then
      karpenter_sleep "${poll_seconds}"
    fi
  done

  karpenter_cleanup_error "Karpenter NodeClaim/EC2 종료 대기 시간이 초과됐습니다."
  karpenter_cleanup_diagnostics "${cluster_name}" "${aws_region}"
  return 1
}
