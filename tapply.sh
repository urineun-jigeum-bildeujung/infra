#!/usr/bin/env bash
# Terraform DEV 인프라부터 Public Web 및 Private 관리 HTTPS까지 준비하는 전체 Apply 진입점이다.
#
# 사용:
#   ./tplan.sh
#   AWS_PROFILE=ujibil2 ./tapply.sh
#
# GitOps가 기본 위치(../gitops)가 아니면 GITOPS_DIR로 재정의한다.
# DNS 적용을 의도적으로 제외할 때만 APPLY_WEB_DNS=false를 사용한다.
# Management Alias 적용을 제외할 때만 APPLY_MANAGEMENT_DNS=false를 사용한다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"
WEB_DNS_DIR="${SCRIPT_DIR}/terraform/environments/dev-web-dns"
EXPECTED_AWS_ACCOUNT_ID="297165773875"
EXPECTED_AWS_REGION="ap-northeast-2"
EXPECTED_GITOPS_REMOTE="urineun-jigeum-bildeujung/gitops"
KUBECONFIG_CONTEXT="petflow-dev"
WEB_INGRESS_NAMESPACE="web"
WEB_INGRESS_NAME="generic-service"
WEB_ALB_NAME="petflow-dev-public"
APPLY_WEB_DNS="${APPLY_WEB_DNS:-true}"
APPLY_MANAGEMENT_DNS="${APPLY_MANAGEMENT_DNS:-true}"
GITOPS_DIR="${GITOPS_DIR:-${SCRIPT_DIR}/../gitops}"
LOCK_FILE="/tmp/petflow-dev-infra.lock"
TEMP_DNS_PLAN=""
FINAL_HTTP_CODE=""
FINAL_HTTPS_CODE=""

cleanup() {
  if [[ -n "${TEMP_DNS_PLAN}" && -f "${TEMP_DNS_PLAN}" ]]; then
    rm -f "${TEMP_DNS_PLAN}"
  fi
}
trap cleanup EXIT

log() {
  printf '[tapply] %s\n' "$*"
}

fail() {
  printf '[tapply] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    fail "${command_name} 명령이 필요합니다."
  fi
}

diagnose_eks() {
  local cluster_name="${1:-petflow-eks}"
  local aws_region="${2:-${EXPECTED_AWS_REGION}}"

  log "EKS/Worker 진단 정보를 출력합니다."
  aws eks describe-cluster --name "${cluster_name}" --region "${aws_region}" \
    --query 'cluster.{Name:name,Status:status,Endpoint:endpoint}' --output table >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" get nodes -o wide >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" get pods -A \
    --field-selector=status.phase=Pending -o wide >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" get events -A \
    --sort-by=.lastTimestamp 2>/dev/null | tail -n 40 >&2 || true
}

wait_for_eks_active() {
  local cluster_name="$1"
  local aws_region="$2"
  local deadline
  local status

  deadline=$(($(date +%s) + 1200))
  while (( $(date +%s) < deadline )); do
    status="$(aws eks describe-cluster \
      --name "${cluster_name}" \
      --region "${aws_region}" \
      --query 'cluster.status' \
      --output text 2>/dev/null || true)"

    if [[ "${status}" == "ACTIVE" ]]; then
      log "EKS Cluster ACTIVE 확인: ${cluster_name}"
      return
    fi

    log "EKS Cluster ACTIVE 대기 중: ${status:-not-found}"
    sleep 10
  done

  diagnose_eks "${cluster_name}" "${aws_region}"
  fail "EKS Cluster가 제한 시간 내 ACTIVE가 되지 않았습니다."
}

wait_for_eks_readyz() {
  local deadline
  local readyz

  deadline=$(($(date +%s) + 900))
  while (( $(date +%s) < deadline )); do
    readyz="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      get --raw=/readyz 2>/dev/null || true)"

    if [[ "${readyz}" == "ok" ]]; then
      log "EKS /readyz 확인 완료"
      return
    fi

    log "Private EKS API 준비 대기 중"
    sleep 10
  done

  diagnose_eks
  fail "Private EKS API /readyz 확인 시간이 초과됐습니다. Tailscale Route를 확인해주세요."
}

wait_for_worker_nodes() {
  local cluster_name="$1"
  local node_group_name="$2"
  local aws_region="$3"
  local deadline
  local desired_count
  local ready_count
  local node_group_status

  deadline=$(($(date +%s) + 1200))
  while (( $(date +%s) < deadline )); do
    node_group_status="$(aws eks describe-nodegroup \
      --cluster-name "${cluster_name}" \
      --nodegroup-name "${node_group_name}" \
      --region "${aws_region}" \
      --query 'nodegroup.status' \
      --output text 2>/dev/null || true)"
    desired_count="$(aws eks describe-nodegroup \
      --cluster-name "${cluster_name}" \
      --nodegroup-name "${node_group_name}" \
      --region "${aws_region}" \
      --query 'nodegroup.scalingConfig.desiredSize' \
      --output text 2>/dev/null || true)"
    ready_count="$(kubectl --context "${KUBECONFIG_CONTEXT}" get nodes -o json 2>/dev/null \
      | jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' \
      || printf '0')"

    if [[ "${node_group_status}" == "ACTIVE" && "${desired_count}" =~ ^[1-9][0-9]*$ ]] \
      && (( ready_count == desired_count )); then
      log "Worker Node Ready 확인 완료: ${ready_count}/${desired_count}"
      return
    fi

    log "Worker Node 준비 대기 중: nodeGroup=${node_group_status:-unknown}, ready=${ready_count}/${desired_count:-unknown}"
    sleep 10
  done

  diagnose_eks "${cluster_name}" "${aws_region}"
  fail "Worker Node가 제한 시간 내 Ready가 되지 않았습니다."
}

validate_gitops_checkout() {
  local git_root
  local branch_name
  local remote_url
  local local_head
  local remote_head

  [[ -d "${GITOPS_DIR}" ]] || fail "GitOps 경로를 찾을 수 없습니다: ${GITOPS_DIR}"
  [[ -f "${GITOPS_DIR}/Taskfile.yml" ]] || fail "GitOps Taskfile을 찾을 수 없습니다: ${GITOPS_DIR}/Taskfile.yml"

  git_root="$(git -C "${GITOPS_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ "${git_root}" == "$(cd "${GITOPS_DIR}" && pwd)" ]] \
    || fail "GITOPS_DIR은 GitOps 저장소 루트여야 합니다: ${GITOPS_DIR}"

  if [[ -n "$(git -C "${GITOPS_DIR}" status --porcelain)" ]]; then
    fail "GitOps 저장소에 커밋되지 않은 변경이 있습니다. 자동으로 덮어쓰지 않습니다."
  fi

  branch_name="$(git -C "${GITOPS_DIR}" branch --show-current)"
  [[ "${branch_name}" == "main" ]] \
    || fail "GitOps 저장소는 main 브랜치여야 합니다. 현재 브랜치: ${branch_name:-detached}"

  remote_url="$(git -C "${GITOPS_DIR}" remote get-url origin 2>/dev/null || true)"
  [[ "${remote_url}" == *"${EXPECTED_GITOPS_REMOTE}"* ]] \
    || fail "예상한 GitOps origin이 아닙니다: ${remote_url:-missing}"

  local_head="$(git -C "${GITOPS_DIR}" rev-parse HEAD)"
  remote_head="$(git -C "${GITOPS_DIR}" ls-remote origin refs/heads/main | awk 'NR == 1 {print $1}')"
  [[ -n "${remote_head}" ]] || fail "GitOps origin/main을 조회하지 못했습니다."
  [[ "${local_head}" == "${remote_head}" ]] \
    || fail "GitOps main이 origin/main 최신 상태가 아닙니다. 스크립트는 자동 pull하지 않습니다."

  log "GitOps Checkout Guard 통과: ${GITOPS_DIR}@${local_head:0:12}"
}

diagnose_gitops() {
  log "GitOps Bootstrap 진단 정보를 출력합니다."
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace argocd get pods -o wide >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace argocd \
    get applications.argoproj.io -o wide >&2 || true
}

diagnose_alb_controller() {
  log "AWS Load Balancer Controller 진단 정보를 출력합니다."
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace argocd \
    get application cert-manager aws-load-balancer-controller -o yaml >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace kube-system \
    get deployment,pod,service,endpoints \
    --selector app.kubernetes.io/name=aws-load-balancer-controller -o wide >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace kube-system \
    get certificate,issuer -o wide >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${WEB_INGRESS_NAMESPACE}" \
    describe ingress "${WEB_INGRESS_NAME}" >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace kube-system \
    logs deployment/aws-load-balancer-controller --tail=200 >&2 || true
}

wait_for_alb_controller() {
  local deadline
  local sync_status
  local health_status
  local cert_manager_sync_status
  local cert_manager_health_status
  local desired_count
  local available_count
  local ready_pod_count
  local certificate_count
  local ready_certificate_count
  local webhook_endpoint_count
  local crd_count

  deadline=$(($(date +%s) + 900))
  while (( $(date +%s) < deadline )); do
    sync_status="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace argocd get application aws-load-balancer-controller \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health_status="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace argocd get application aws-load-balancer-controller \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    cert_manager_sync_status="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace argocd get application cert-manager \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    cert_manager_health_status="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace argocd get application cert-manager \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    desired_count="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace kube-system get deployment aws-load-balancer-controller \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    available_count="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace kube-system get deployment aws-load-balancer-controller \
      -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    ready_pod_count="$(kubectl --context "${KUBECONFIG_CONTEXT}" --namespace kube-system get pod \
      --selector app.kubernetes.io/name=aws-load-balancer-controller -o json 2>/dev/null \
      | jq '[.items[] | select(.status.phase == "Running" and any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' || printf '0')"
    certificate_count="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace kube-system get certificate \
      --selector app.kubernetes.io/name=aws-load-balancer-controller -o json 2>/dev/null \
      | jq '.items | length' || printf '0')"
    ready_certificate_count="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace kube-system get certificate \
      --selector app.kubernetes.io/name=aws-load-balancer-controller -o json 2>/dev/null \
      | jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' \
      || printf '0')"
    webhook_endpoint_count="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace kube-system get endpoints aws-load-balancer-webhook-service -o json 2>/dev/null \
      | jq '[.subsets[]?.addresses[]?] | length' || printf '0')"
    crd_count=0
    for crd_name in targetgroupbindings.elbv2.k8s.aws ingressclassparams.elbv2.k8s.aws; do
      if kubectl --context "${KUBECONFIG_CONTEXT}" get crd "${crd_name}" >/dev/null 2>&1; then
        ((crd_count += 1))
      fi
    done

    if [[ "${sync_status}" == "Synced" && "${health_status}" == "Healthy" \
      && "${cert_manager_sync_status}" == "Synced" && "${cert_manager_health_status}" == "Healthy" \
      && "${desired_count}" =~ ^[1-9][0-9]*$ && "${available_count}" == "${desired_count}" \
      && "${ready_pod_count}" == "${desired_count}" \
      && "${certificate_count}" =~ ^[1-9][0-9]*$ \
      && "${ready_certificate_count}" == "${certificate_count}" \
      && "${webhook_endpoint_count}" =~ ^[1-9][0-9]*$ && "${crd_count}" == "2" ]]; then
      log "AWS Load Balancer Controller 준비 완료: available=${available_count}/${desired_count}, readyPods=${ready_pod_count}/${desired_count}, certificates=${ready_certificate_count}/${certificate_count}, webhookEndpoints=${webhook_endpoint_count}, crds=${crd_count}/2"
      return
    fi

    log "Controller 준비 대기 중: controller=${sync_status:-unknown}/${health_status:-unknown}, certManager=${cert_manager_sync_status:-unknown}/${cert_manager_health_status:-unknown}, available=${available_count:-0}/${desired_count:-0}, readyPods=${ready_pod_count:-0}, certificates=${ready_certificate_count:-0}/${certificate_count:-0}, webhookEndpoints=${webhook_endpoint_count:-0}, crds=${crd_count}/2"
    sleep 10
  done

  diagnose_alb_controller
  fail "AWS Load Balancer Controller가 제한 시간 내 Synced/Healthy/Available 상태가 되지 않았습니다."
}

wait_for_web_alb() {
  local aws_region="$1"
  local deadline
  local ingress_address
  local alb_arn
  local alb_dns
  local alb_state
  local listener_ports
  local target_group_count

  deadline=$(($(date +%s) + 900))
  while (( $(date +%s) < deadline )); do
    ingress_address="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace "${WEB_INGRESS_NAMESPACE}" \
      get ingress "${WEB_INGRESS_NAME}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    alb_arn="$(aws elbv2 describe-load-balancers \
      --region "${aws_region}" \
      --names "${WEB_ALB_NAME}" \
      --query 'LoadBalancers[0].LoadBalancerArn' \
      --output text 2>/dev/null || true)"
    alb_dns="$(aws elbv2 describe-load-balancers \
      --region "${aws_region}" \
      --names "${WEB_ALB_NAME}" \
      --query 'LoadBalancers[0].DNSName' \
      --output text 2>/dev/null || true)"
    alb_state="$(aws elbv2 describe-load-balancers \
      --region "${aws_region}" \
      --names "${WEB_ALB_NAME}" \
      --query 'LoadBalancers[0].State.Code' \
      --output text 2>/dev/null || true)"
    listener_ports="$(aws elbv2 describe-listeners \
      --region "${aws_region}" \
      --load-balancer-arn "${alb_arn}" \
      --query 'Listeners[].Port' \
      --output text 2>/dev/null || true)"
    target_group_count="$(aws elbv2 describe-target-groups \
      --region "${aws_region}" \
      --load-balancer-arn "${alb_arn}" \
      --query 'length(TargetGroups)' \
      --output text 2>/dev/null || printf '0')"

    if [[ -n "${ingress_address}" && "${ingress_address}" == "${alb_dns}" \
      && "${alb_state}" == "active" \
      && "${listener_ports}" =~ (^|[[:space:]])80($|[[:space:]]) \
      && "${listener_ports}" =~ (^|[[:space:]])443($|[[:space:]]) \
      && "${target_group_count}" =~ ^[1-9][0-9]*$ ]]; then
      log "Web ALB 준비 완료: dns=${alb_dns}, state=${alb_state}, listeners=${listener_ports}, targetGroups=${target_group_count}"
      return
    fi

    log "Web Ingress/ALB 준비 대기 중: ingress=${ingress_address:-empty}, albDns=${alb_dns:-not-found}, state=${alb_state:-not-found}, listeners=${listener_ports:-none}, targetGroups=${target_group_count:-0}"
    sleep 10
  done

  diagnose_alb_controller
  fail "Web Ingress ADDRESS 또는 ALB active 확인 시간이 초과됐습니다."
}

verify_target_health() {
  local aws_region="$1"
  local deadline
  local alb_arn
  local target_group_arns
  local target_group_arn
  local target_count
  local unhealthy_count
  local all_healthy

  alb_arn="$(aws elbv2 describe-load-balancers \
    --region "${aws_region}" \
    --names "${WEB_ALB_NAME}" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)"
  deadline=$(($(date +%s) + 600))

  while (( $(date +%s) < deadline )); do
    target_group_arns="$(aws elbv2 describe-target-groups \
      --region "${aws_region}" \
      --load-balancer-arn "${alb_arn}" \
      --query 'TargetGroups[].TargetGroupArn' \
      --output text)"
    all_healthy=true

    if [[ -z "${target_group_arns}" || "${target_group_arns}" == "None" ]]; then
      all_healthy=false
    else
      for target_group_arn in ${target_group_arns}; do
        target_count="$(aws elbv2 describe-target-health \
          --region "${aws_region}" \
          --target-group-arn "${target_group_arn}" \
          --query 'length(TargetHealthDescriptions)' \
          --output text)"
        # shellcheck disable=SC2016 # JMESPath의 backtick은 AWS CLI 숫자 리터럴이다.
        unhealthy_count="$(aws elbv2 describe-target-health \
          --region "${aws_region}" \
          --target-group-arn "${target_group_arn}" \
          --query 'length(TargetHealthDescriptions[?TargetHealth.State!=`healthy`])' \
          --output text)"

        if (( target_count == 0 || unhealthy_count > 0 )); then
          all_healthy=false
        fi
      done
    fi

    if [[ "${all_healthy}" == true ]]; then
      log "모든 ALB Target healthy 확인 완료"
      return
    fi

    log "ALB Target healthy 대기 중"
    sleep 10
  done

  for target_group_arn in ${target_group_arns:-}; do
    aws elbv2 describe-target-health --region "${aws_region}" \
      --target-group-arn "${target_group_arn}" \
      --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
      --output table >&2 || true
  done
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${WEB_INGRESS_NAMESPACE}" \
    get service,endpoints -o wide >&2 || true
  diagnose_alb_controller
  fail "ALB Target이 제한 시간 내 healthy가 되지 않았습니다."
}

apply_web_dns() {
  local aws_region="$1"
  local changed_count
  local expected_change_count

  wait_for_web_alb "${aws_region}"
  verify_target_health "${aws_region}"

  [[ -f "${WEB_DNS_DIR}/backend.hcl" ]] \
    || fail "Web DNS backend.hcl 파일이 없습니다: ${WEB_DNS_DIR}/backend.hcl"
  [[ -f "${WEB_DNS_DIR}/terraform.tfvars" ]] \
    || fail "Web DNS terraform.tfvars 파일이 없습니다: ${WEB_DNS_DIR}/terraform.tfvars"

  terraform -chdir="${WEB_DNS_DIR}" init \
    -backend-config=backend.hcl \
    -input=false >/dev/null

  TEMP_DNS_PLAN="$(mktemp /tmp/petflow-web-dns.XXXXXX)"
  terraform -chdir="${WEB_DNS_DIR}" plan \
    -input=false \
    -out="${TEMP_DNS_PLAN}"

  changed_count="$(terraform -chdir="${WEB_DNS_DIR}" show -json "${TEMP_DNS_PLAN}" \
    | jq '[.resource_changes[] | select(.mode == "managed" and (.change.actions != ["no-op"]))] | length')"
  expected_change_count="$(terraform -chdir="${WEB_DNS_DIR}" show -json "${TEMP_DNS_PLAN}" \
    | jq '[.resource_changes[] | select(.mode == "managed" and .address == "aws_route53_record.web" and .type == "aws_route53_record" and .change.actions == ["update"])] | length')"

  if (( changed_count == 0 )); then
    log "Web DNS는 이미 현재 ALB와 일치합니다."
  elif (( changed_count == 1 && expected_change_count == 1 )); then
    log "Web DNS Guard 통과: aws_route53_record.web in-place update 1건"
    terraform -chdir="${WEB_DNS_DIR}" apply -input=false "${TEMP_DNS_PLAN}"
  else
    terraform -chdir="${WEB_DNS_DIR}" show "${TEMP_DNS_PLAN}" >&2
    fail "Web DNS Plan에 예상하지 않은 변경이 있습니다. Apply하지 않습니다."
  fi

  terraform -chdir="${WEB_DNS_DIR}" plan -input=false -detailed-exitcode
  log "Web DNS 사후 Plan No changes 확인 완료"
}

verify_public_web() {
  local deadline
  local http_code
  local https_code

  deadline=$(($(date +%s) + 300))
  while (( $(date +%s) < deadline )); do
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      http://leechs.shop/ 2>/dev/null || true)"
    https_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      https://leechs.shop/ 2>/dev/null || true)"

    if [[ "${http_code}" == "301" && "${https_code}" == "200" ]]; then
      FINAL_HTTP_CODE="${http_code}"
      FINAL_HTTPS_CODE="${https_code}"
      log "공개 Web 검증 완료: HTTP=${http_code}, HTTPS=${https_code}"
      return
    fi

    log "공개 DNS/HTTPS 전파 대기 중: HTTP=${http_code:-000}, HTTPS=${https_code:-000}"
    sleep 10
  done

  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 leechs.shop >&2 || true
  fi
  curl -sS -I --max-time 15 http://leechs.shop/ >&2 || true
  curl -sS -I --max-time 15 https://leechs.shop/ >&2 || true
  aws route53 list-resource-record-sets --hosted-zone-id "$(terraform -chdir="${WEB_DNS_DIR}" output -raw route53_zone_id 2>/dev/null || true)" \
    --query "ResourceRecordSets[?Name=='leechs.shop.']" --output table >&2 || true
  fail "leechs.shop 공개 HTTP/HTTPS 검증 시간이 초과됐습니다."
}

print_final_summary() {
  local cluster_name="$1"
  local aws_region="$2"
  local zone_id
  local target_group_arn

  log "========== DEV 전체 Apply 최종 상태 =========="
  aws eks describe-cluster --name "${cluster_name}" --region "${aws_region}" --query 'cluster.{Name:name,Status:status}' --output table
  kubectl --context "${KUBECONFIG_CONTEXT}" get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' --no-headers
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace argocd get applications.argoproj.io -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers
  aws elbv2 describe-load-balancers --region "${aws_region}" --names "${WEB_ALB_NAME}" --query 'LoadBalancers[0].{Name:LoadBalancerName,DNS:DNSName,State:State.Code}' --output table
  for target_group_arn in $(aws elbv2 describe-target-groups --region "${aws_region}" --load-balancer-arn "$(aws elbv2 describe-load-balancers --region "${aws_region}" --names "${WEB_ALB_NAME}" --query 'LoadBalancers[0].LoadBalancerArn' --output text)" --query 'TargetGroups[].TargetGroupArn' --output text); do
    aws elbv2 describe-target-health --region "${aws_region}" --target-group-arn "${target_group_arn}" --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State}' --output table
  done
  zone_id="$(terraform -chdir="${WEB_DNS_DIR}" output -raw route53_zone_id)"
  aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" --query "ResourceRecordSets[?Name=='leechs.shop.' && Type=='A'].{Name:Name,Alias:AliasTarget.DNSName}" --output table
  log "Public Web: HTTP=${FINAL_HTTP_CODE:-skipped}, HTTPS=${FINAL_HTTPS_CODE:-skipped}"
  log "=============================================="
}

for command_name in aws terraform kubectl helm task git jq curl flock; do
  require_command "${command_name}"
done
[[ -n "${AWS_PROFILE:-}" ]] || fail "AWS_PROFILE을 명시해주세요. 예: AWS_PROFILE=ujibil2 ./tapply.sh"

case "${APPLY_WEB_DNS}" in
  true|false) ;;
  *) fail "APPLY_WEB_DNS는 true 또는 false여야 합니다." ;;
esac

case "${APPLY_MANAGEMENT_DNS}" in
  true|false) ;;
  *) fail "APPLY_MANAGEMENT_DNS는 true 또는 false여야 합니다." ;;
esac
requested_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region --profile "${AWS_PROFILE}" 2>/dev/null || true)}}"
[[ "${requested_region}" == "${EXPECTED_AWS_REGION}" ]] || fail "잘못된 AWS Region입니다: ${requested_region:-unset} (예상: ${EXPECTED_AWS_REGION})"
export AWS_REGION="${requested_region}"

[[ -d "${TERRAFORM_DIR}" ]] \
  || fail "Terraform DEV 디렉터리를 찾을 수 없습니다: ${TERRAFORM_DIR}"

validate_gitops_checkout

caller_account="$(aws sts get-caller-identity --query Account --output text)"
[[ "${caller_account}" == "${EXPECTED_AWS_ACCOUNT_ID}" ]] \
  || fail "잘못된 AWS Account입니다: ${caller_account}"
log "AWS Account Guard 통과: ${caller_account}"
log "AWS Region Guard 통과: ${requested_region}"
exec 9>"${LOCK_FILE}"
flock -n 9 || fail "다른 PetFlow 인프라 Apply/Destroy 작업이 실행 중입니다."
log "인프라 작업 Lock 획득: ${LOCK_FILE}"

log "[1/10] Terraform DEV Apply와 PostgreSQL 이미지 준비"
PETFLOW_INTERNAL_ORCHESTRATOR=true "${SCRIPT_DIR}/scripts/apply-infra.sh"

cluster_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw eks_cluster_name)"
node_group_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw eks_node_group_name)"
aws_region="$(terraform -chdir="${TERRAFORM_DIR}" output -raw aws_region)"
[[ "${aws_region}" == "${EXPECTED_AWS_REGION}" ]] || fail "Terraform output Region 불일치: ${aws_region}"

log "[2/10] EKS ACTIVE와 Private API 준비 대기"
wait_for_eks_active "${cluster_name}" "${aws_region}"
aws eks update-kubeconfig \
  --name "${cluster_name}" \
  --region "${aws_region}" \
  --alias "${KUBECONFIG_CONTEXT}" >/dev/null
kubectl config use-context "${KUBECONFIG_CONTEXT}" >/dev/null
wait_for_eks_readyz

log "[3/10] Worker Node Ready 대기"
wait_for_worker_nodes "${cluster_name}" "${node_group_name}" "${aws_region}"

log "[4/10] GitOps Bootstrap"
if ! (
  cd "${GITOPS_DIR}"
  task bootstrap:core
); then
  diagnose_gitops
  fail "GitOps bootstrap:core 실행에 실패했습니다."
fi

log "[5/10] AWS Load Balancer Controller GitOps Sync와 Ready 대기"
wait_for_alb_controller

log "[6/10] Web Ingress와 Public ALB active 대기"
wait_for_web_alb "${aws_region}"

log "[7/10] Public Web ALB Target Health 검증"
verify_target_health "${aws_region}"

log "[8/10] Grafana·Prometheus Internal ALB, Target, Route53, HTTPS"
APPLY_MANAGEMENT_DNS="${APPLY_MANAGEMENT_DNS}" \
  PETFLOW_INTERNAL_ORCHESTRATOR=true \
  "${SCRIPT_DIR}/scripts/configure-management-access.sh"

log "[9/10] Web Route53 Alias와 공개 HTTPS"
if [[ "${APPLY_WEB_DNS}" == true ]]; then
  apply_web_dns "${aws_region}"
  verify_public_web
else
  log "APPLY_WEB_DNS=false이므로 DNS Apply를 생략했습니다."
  log "ALB/Target Guard는 통과했습니다. DNS까지 복구하려면 APPLY_WEB_DNS=true로 실행하세요."
fi

log "[10/10] 최종 상태 요약"
print_final_summary "${cluster_name}" "${aws_region}"

log "DEV 전체 Apply 완료"
