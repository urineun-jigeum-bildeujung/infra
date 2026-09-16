#!/usr/bin/env bash
# Terraform DEV 인프라부터 ALB Controller, GitOps, Web ALB까지 순서대로 복구한다.
#
# 사용:
#   ./tplan.sh
#   GITOPS_DIR=/home/user1/project/tong-p/gitops \
#   AWS_PROFILE=ujibil2 \
#     ./trestore.sh
#
# Route53 Alias와 공개 HTTPS까지 자동 복구하려면 명시적으로 활성화한다.
#   APPLY_WEB_DNS=true GITOPS_DIR=... AWS_PROFILE=ujibil2 ./trestore.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"
WEB_DNS_DIR="${SCRIPT_DIR}/terraform/environments/dev-web-dns"
EXPECTED_AWS_ACCOUNT_ID="297165773875"
EXPECTED_GITOPS_REMOTE="urineun-jigeum-bildeujung/gitops"
KUBECONFIG_CONTEXT="petflow-dev"
WEB_INGRESS_NAMESPACE="web"
WEB_INGRESS_NAME="generic-service"
WEB_ALB_NAME="petflow-dev-public"
APPLY_WEB_DNS="${APPLY_WEB_DNS:-false}"
GITOPS_DIR="${GITOPS_DIR:-}"
TEMP_DNS_PLAN=""

cleanup() {
  if [[ -n "${TEMP_DNS_PLAN}" && -f "${TEMP_DNS_PLAN}" ]]; then
    rm -f "${TEMP_DNS_PLAN}"
  fi
}
trap cleanup EXIT

log() {
  printf '[trestore] %s\n' "$*"
}

fail() {
  printf '[trestore] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    fail "${command_name} 명령이 필요합니다."
  fi
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

    if [[ "${node_group_status}" == "ACTIVE" && "${desired_count}" =~ ^[0-9]+$ ]] \
      && (( ready_count == desired_count )); then
      log "Worker Node Ready 확인 완료: ${ready_count}/${desired_count}"
      return
    fi

    log "Worker Node 준비 대기 중: nodeGroup=${node_group_status:-unknown}, ready=${ready_count}/${desired_count:-unknown}"
    sleep 10
  done

  fail "Worker Node가 제한 시간 내 Ready가 되지 않았습니다."
}

validate_gitops_checkout() {
  local git_root
  local branch_name
  local remote_url
  local local_head
  local remote_head

  [[ -n "${GITOPS_DIR}" ]] || fail "GITOPS_DIR 환경변수로 GitOps 저장소 경로를 지정해주세요."
  [[ -d "${GITOPS_DIR}" ]] || fail "GitOps 경로를 찾을 수 없습니다: ${GITOPS_DIR}"

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

wait_for_web_alb() {
  local aws_region="$1"
  local deadline
  local ingress_address
  local alb_state

  deadline=$(($(date +%s) + 900))
  while (( $(date +%s) < deadline )); do
    ingress_address="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace "${WEB_INGRESS_NAMESPACE}" \
      get ingress "${WEB_INGRESS_NAME}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    alb_state="$(aws elbv2 describe-load-balancers \
      --region "${aws_region}" \
      --names "${WEB_ALB_NAME}" \
      --query 'LoadBalancers[0].State.Code' \
      --output text 2>/dev/null || true)"

    if [[ -n "${ingress_address}" && "${alb_state}" == "active" ]]; then
      log "Web ALB active 확인: ${ingress_address}"
      return
    fi

    log "Web Ingress/ALB 준비 대기 중: address=${ingress_address:-empty}, state=${alb_state:-not-found}"
    sleep 10
  done

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

  fail "ALB Target이 제한 시간 내 healthy가 되지 않았습니다."
}

apply_web_dns() {
  local changed_count
  local expected_change_count

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

    if [[ "${http_code}" =~ ^30[1278]$ && "${https_code}" == "200" ]]; then
      log "공개 Web 검증 완료: HTTP=${http_code}, HTTPS=${https_code}"
      return
    fi

    log "공개 DNS/HTTPS 전파 대기 중: HTTP=${http_code:-000}, HTTPS=${https_code:-000}"
    sleep 10
  done

  fail "leechs.shop 공개 HTTP/HTTPS 검증 시간이 초과됐습니다."
}

for command_name in aws terraform kubectl helm task git gh jq curl; do
  require_command "${command_name}"
done

case "${APPLY_WEB_DNS}" in
  true|false) ;;
  *) fail "APPLY_WEB_DNS는 true 또는 false여야 합니다." ;;
esac

[[ -d "${TERRAFORM_DIR}" ]] \
  || fail "Terraform DEV 디렉터리를 찾을 수 없습니다: ${TERRAFORM_DIR}"

validate_gitops_checkout

caller_account="$(aws sts get-caller-identity --query Account --output text)"
[[ "${caller_account}" == "${EXPECTED_AWS_ACCOUNT_ID}" ]] \
  || fail "잘못된 AWS Account입니다: ${caller_account}"
log "AWS Account Guard 통과: ${caller_account}"

log "[1/8] Terraform DEV Apply와 PostgreSQL 이미지 준비"
"${SCRIPT_DIR}/tapply.sh"

cluster_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw eks_cluster_name)"
node_group_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw eks_node_group_name)"
aws_region="$(terraform -chdir="${TERRAFORM_DIR}" output -raw aws_region)"

log "[2/8] EKS ACTIVE와 Private API 준비 대기"
wait_for_eks_active "${cluster_name}" "${aws_region}"
aws eks update-kubeconfig \
  --name "${cluster_name}" \
  --region "${aws_region}" \
  --alias "${KUBECONFIG_CONTEXT}" >/dev/null
kubectl config use-context "${KUBECONFIG_CONTEXT}" >/dev/null
wait_for_eks_readyz

log "[3/8] Worker Node Ready 대기"
wait_for_worker_nodes "${cluster_name}" "${node_group_name}" "${aws_region}"

log "[4/8] AWS Load Balancer Controller 설치/업그레이드"
"${SCRIPT_DIR}/scripts/install-alb-controller.sh"

log "[5/8] GitOps Bootstrap"
(
  cd "${GITOPS_DIR}"
  task bootstrap
)

log "[6/8] Web Ingress와 ALB active 대기"
wait_for_web_alb "${aws_region}"

log "[7/8] ALB Target Health 검증"
verify_target_health "${aws_region}"

log "[8/8] Route53 Alias와 공개 HTTPS"
if [[ "${APPLY_WEB_DNS}" == true ]]; then
  apply_web_dns
  verify_public_web
else
  log "APPLY_WEB_DNS=false이므로 DNS Apply를 생략했습니다."
  log "ALB/Target Guard는 통과했습니다. DNS까지 복구하려면 APPLY_WEB_DNS=true로 실행하세요."
fi

log "DEV 전체 복구 절차 완료"
