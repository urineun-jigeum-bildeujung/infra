#!/usr/bin/env bash
# Grafana/Prometheus Internal ALB, Target, Route53 Alias와 HTTPS를 검증·구성하는 내부 스크립트다.
# shellcheck disable=SC2016 # 작은따옴표 안 backtick은 AWS CLI JMESPath 리터럴이다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform/environments/dev"
MANAGEMENT_DNS_DIR="${ROOT_DIR}/terraform/environments/dev-management-dns"
KUBECONFIG_CONTEXT="petflow-dev"
OBSERVABILITY_NAMESPACE="observability"
GRAFANA_INGRESS_NAME="grafana-internal"
PROMETHEUS_INGRESS_NAME="prometheus-internal"
MANAGEMENT_ALB_NAME="petflow-dev-management"
EXPECTED_INGRESS_STACK="petflow-dev-management"
EXPECTED_EKS_CLUSTER_NAME="petflow-eks"
GRAFANA_HOSTNAME="grafana.leechs.shop"
PROMETHEUS_HOSTNAME="prometheus.leechs.shop"
APPLY_MANAGEMENT_DNS="${APPLY_MANAGEMENT_DNS:-true}"
TEMP_DNS_PLAN=""

log() {
  printf '[management-access] %s\n' "$*"
}

fail() {
  printf '[management-access] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_DNS_PLAN}" && -f "${TEMP_DNS_PLAN}" ]]; then
    rm -f "${TEMP_DNS_PLAN}"
  fi
}
trap cleanup EXIT

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1     || fail "${command_name} 명령이 필요합니다."
}

diagnose_management_alb() {
  local aws_region="$1"

  log "Management Ingress/ALB 진단 정보를 출력합니다."
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${OBSERVABILITY_NAMESPACE}"     get ingress "${GRAFANA_INGRESS_NAME}" "${PROMETHEUS_INGRESS_NAME}" -o wide >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${OBSERVABILITY_NAMESPACE}"     describe ingress "${GRAFANA_INGRESS_NAME}" >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${OBSERVABILITY_NAMESPACE}"     describe ingress "${PROMETHEUS_INGRESS_NAME}" >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${OBSERVABILITY_NAMESPACE}"     get service,endpoints     kube-prometheus-stack-grafana kube-prometheus-stack-prometheus -o wide >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace kube-system     logs deployment/aws-load-balancer-controller --tail=200 >&2 || true
  aws elbv2 describe-load-balancers --region "${aws_region}"     --names "${MANAGEMENT_ALB_NAME}" --output table >&2 || true
}

host_rule_count() {
  local aws_region="$1"
  local listener_arn="$2"
  local hostname="$3"

  aws elbv2 describe-rules --region "${aws_region}" --listener-arn "${listener_arn}"     --output json 2>/dev/null     | jq --arg hostname "${hostname}"       '[.Rules[] | select(any(.Conditions[]?; .Field == "host-header" and ((.Values // []) | index($hostname) != null)))] | length'     || printf '0'
}

wait_for_management_alb() {
  local aws_region="$1"
  local expected_vpc_id="$2"
  local deadline
  local grafana_address
  local prometheus_address
  local alb_arn
  local alb_dns
  local alb_state
  local alb_scheme
  local alb_vpc_id
  local stack_tag
  local cluster_tag
  local listener_ports
  local https_listener_arn
  local target_group_count
  local grafana_rule_count
  local prometheus_rule_count

  deadline=$(($(date +%s) + 1200))
  while (( $(date +%s) < deadline )); do
    grafana_address="$(kubectl --context "${KUBECONFIG_CONTEXT}"       --namespace "${OBSERVABILITY_NAMESPACE}" get ingress "${GRAFANA_INGRESS_NAME}"       -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    prometheus_address="$(kubectl --context "${KUBECONFIG_CONTEXT}"       --namespace "${OBSERVABILITY_NAMESPACE}" get ingress "${PROMETHEUS_INGRESS_NAME}"       -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

    alb_arn="$(aws elbv2 describe-load-balancers --region "${aws_region}"       --names "${MANAGEMENT_ALB_NAME}" --query 'LoadBalancers[0].LoadBalancerArn'       --output text 2>/dev/null || true)"
    alb_dns="$(aws elbv2 describe-load-balancers --region "${aws_region}"       --names "${MANAGEMENT_ALB_NAME}" --query 'LoadBalancers[0].DNSName'       --output text 2>/dev/null || true)"
    alb_state="$(aws elbv2 describe-load-balancers --region "${aws_region}"       --names "${MANAGEMENT_ALB_NAME}" --query 'LoadBalancers[0].State.Code'       --output text 2>/dev/null || true)"
    alb_scheme="$(aws elbv2 describe-load-balancers --region "${aws_region}"       --names "${MANAGEMENT_ALB_NAME}" --query 'LoadBalancers[0].Scheme'       --output text 2>/dev/null || true)"
    alb_vpc_id="$(aws elbv2 describe-load-balancers --region "${aws_region}"       --names "${MANAGEMENT_ALB_NAME}" --query 'LoadBalancers[0].VpcId'       --output text 2>/dev/null || true)"
    stack_tag="$(aws elbv2 describe-tags --region "${aws_region}"       --resource-arns "${alb_arn}"       --query 'TagDescriptions[0].Tags[?Key==`ingress.k8s.aws/stack`].Value | [0]'       --output text 2>/dev/null || true)"
    cluster_tag="$(aws elbv2 describe-tags --region "${aws_region}"       --resource-arns "${alb_arn}"       --query 'TagDescriptions[0].Tags[?Key==`elbv2.k8s.aws/cluster`].Value | [0]'       --output text 2>/dev/null || true)"
    listener_ports="$(aws elbv2 describe-listeners --region "${aws_region}"       --load-balancer-arn "${alb_arn}" --query 'Listeners[].Port'       --output text 2>/dev/null || true)"
    https_listener_arn="$(aws elbv2 describe-listeners --region "${aws_region}"       --load-balancer-arn "${alb_arn}" --query 'Listeners[?Port==`443`].ListenerArn | [0]'       --output text 2>/dev/null || true)"
    target_group_count="$(aws elbv2 describe-target-groups --region "${aws_region}"       --load-balancer-arn "${alb_arn}" --query 'length(TargetGroups)'       --output text 2>/dev/null || printf '0')"
    grafana_rule_count="$(host_rule_count "${aws_region}" "${https_listener_arn}" "${GRAFANA_HOSTNAME}")"
    prometheus_rule_count="$(host_rule_count "${aws_region}" "${https_listener_arn}" "${PROMETHEUS_HOSTNAME}")"

    if [[ -n "${grafana_address}" && "${grafana_address}" == "${prometheus_address}"       && "${grafana_address}" == "${alb_dns}"       && "${alb_state}" == "active"       && "${alb_scheme}" == "internal"       && "${alb_vpc_id}" == "${expected_vpc_id}"       && "${stack_tag}" == "${EXPECTED_INGRESS_STACK}"       && "${cluster_tag}" == "${EXPECTED_EKS_CLUSTER_NAME}"       && "${listener_ports}" =~ (^|[[:space:]])80($|[[:space:]])       && "${listener_ports}" =~ (^|[[:space:]])443($|[[:space:]])       && "${target_group_count}" == "2"       && "${grafana_rule_count}" =~ ^[1-9][0-9]*$       && "${prometheus_rule_count}" =~ ^[1-9][0-9]*$ ]]; then
      log "Management ALB Guard 통과: dns=${alb_dns}, scheme=${alb_scheme}, vpc=${alb_vpc_id}, targetGroups=2"
      return
    fi

    log "Management ALB 대기 중: grafana=${grafana_address:-empty}, prometheus=${prometheus_address:-empty}, alb=${alb_dns:-not-found}, state=${alb_state:-not-found}, scheme=${alb_scheme:-unknown}, vpc=${alb_vpc_id:-unknown}, stack=${stack_tag:-unknown}, cluster=${cluster_tag:-unknown}, listeners=${listener_ports:-none}, targetGroups=${target_group_count:-0}, hostRules=${grafana_rule_count:-0}/${prometheus_rule_count:-0}"
    sleep 10
  done

  diagnose_management_alb "${aws_region}"
  fail "Management Ingress/ALB Guard 확인 시간이 초과됐습니다."
}

verify_management_target_health() {
  local aws_region="$1"
  local alb_arn
  local target_group_arns
  local target_group_arn
  local target_count
  local unhealthy_count
  local all_healthy
  local deadline

  alb_arn="$(aws elbv2 describe-load-balancers --region "${aws_region}"     --names "${MANAGEMENT_ALB_NAME}" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  deadline=$(($(date +%s) + 900))

  while (( $(date +%s) < deadline )); do
    target_group_arns="$(aws elbv2 describe-target-groups --region "${aws_region}"       --load-balancer-arn "${alb_arn}" --query 'TargetGroups[].TargetGroupArn' --output text)"
    all_healthy=true

    if [[ "$(wc -w <<< "${target_group_arns}")" -ne 2 ]]; then
      all_healthy=false
    else
      for target_group_arn in ${target_group_arns}; do
        target_count="$(aws elbv2 describe-target-health --region "${aws_region}"           --target-group-arn "${target_group_arn}"           --query 'length(TargetHealthDescriptions)' --output text)"
        # shellcheck disable=SC2016 # JMESPath backtick은 AWS CLI 숫자 리터럴이다.
        unhealthy_count="$(aws elbv2 describe-target-health --region "${aws_region}"           --target-group-arn "${target_group_arn}"           --query 'length(TargetHealthDescriptions[?TargetHealth.State!=`healthy`])' --output text)"

        if (( target_count == 0 || unhealthy_count > 0 )); then
          all_healthy=false
        fi
      done
    fi

    if [[ "${all_healthy}" == true ]]; then
      log "Grafana/Prometheus Target Group 2개 모두 healthy"
      return
    fi

    log "Management Target healthy 대기 중"
    sleep 10
  done

  for target_group_arn in ${target_group_arns:-}; do
    aws elbv2 describe-target-health --region "${aws_region}"       --target-group-arn "${target_group_arn}"       --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}'       --output table >&2 || true
  done
  diagnose_management_alb "${aws_region}"
  fail "Grafana/Prometheus Target이 제한 시간 내 healthy가 되지 않았습니다."
}

apply_management_dns() {
  local changed_count
  local unexpected_count

  [[ -f "${MANAGEMENT_DNS_DIR}/backend.hcl" ]]     || fail "Management DNS backend.hcl 파일이 없습니다: ${MANAGEMENT_DNS_DIR}/backend.hcl"
  [[ -f "${MANAGEMENT_DNS_DIR}/terraform.tfvars" ]]     || fail "Management DNS terraform.tfvars 파일이 없습니다: ${MANAGEMENT_DNS_DIR}/terraform.tfvars"

  terraform -chdir="${MANAGEMENT_DNS_DIR}" init     -backend-config=backend.hcl -input=false >/dev/null

  TEMP_DNS_PLAN="$(mktemp /tmp/petflow-management-dns.XXXXXX)"
  terraform -chdir="${MANAGEMENT_DNS_DIR}" plan -input=false -out="${TEMP_DNS_PLAN}"

  changed_count="$(terraform -chdir="${MANAGEMENT_DNS_DIR}" show -json "${TEMP_DNS_PLAN}"     | jq '[.resource_changes[] | select(.mode == "managed" and (.change.actions != ["no-op"]))] | length')"
  unexpected_count="$(terraform -chdir="${MANAGEMENT_DNS_DIR}" show -json "${TEMP_DNS_PLAN}"     | jq '[.resource_changes[]
      | select(.mode == "managed" and (.change.actions != ["no-op"]))
      | select(
          ((.address != "aws_route53_record.grafana") and (.address != "aws_route53_record.prometheus"))
          or ((.change.actions != ["create"]) and (.change.actions != ["update"]))
        )
    ] | length')"

  if (( changed_count == 0 )); then
    log "Management DNS는 이미 현재 Internal ALB와 일치합니다."
  elif (( changed_count <= 2 && unexpected_count == 0 )); then
    log "Management DNS Guard 통과: Route53 Alias create/update ${changed_count}건"
    terraform -chdir="${MANAGEMENT_DNS_DIR}" apply -input=false "${TEMP_DNS_PLAN}"
  else
    terraform -chdir="${MANAGEMENT_DNS_DIR}" show "${TEMP_DNS_PLAN}" >&2
    fail "Management DNS Plan에 예상하지 않은 변경이 있습니다. Apply하지 않습니다."
  fi

  terraform -chdir="${MANAGEMENT_DNS_DIR}" plan -input=false -detailed-exitcode
  log "Management DNS 사후 Plan No changes 확인 완료"
}

all_addresses_private() {
  local hostname="$1"
  local addresses

  addresses="$(getent ahostsv4 "${hostname}" 2>/dev/null | awk '{print $1}' | sort -u)"
  [[ -n "${addresses}" ]] || return 1
  awk 'BEGIN {ok=1} !/^10\./ {ok=0} END {exit !ok}' <<< "${addresses}"
}

verify_management_https() {
  local deadline
  local grafana_http
  local prometheus_http
  local grafana_health
  local prometheus_health

  deadline=$(($(date +%s) + 600))
  while (( $(date +%s) < deadline )); do
    grafana_http="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15       "http://${GRAFANA_HOSTNAME}/" 2>/dev/null || true)"
    prometheus_http="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15       "http://${PROMETHEUS_HOSTNAME}/" 2>/dev/null || true)"
    grafana_health="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15       "https://${GRAFANA_HOSTNAME}/api/health" 2>/dev/null || true)"
    prometheus_health="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15       "https://${PROMETHEUS_HOSTNAME}/-/healthy" 2>/dev/null || true)"

    if all_addresses_private "${GRAFANA_HOSTNAME}"       && all_addresses_private "${PROMETHEUS_HOSTNAME}"       && [[ "${grafana_http}" == "301" && "${prometheus_http}" == "301"         && "${grafana_health}" == "200" && "${prometheus_health}" == "200" ]]; then
      log "Management DNS/HTTPS 검증 완료: privateDNS=true, HTTP=301/301, health=200/200"
      return
    fi

    log "Management DNS/HTTPS 대기 중: HTTP=${grafana_http:-000}/${prometheus_http:-000}, health=${grafana_health:-000}/${prometheus_health:-000}"
    sleep 10
  done

  getent ahostsv4 "${GRAFANA_HOSTNAME}" >&2 || true
  getent ahostsv4 "${PROMETHEUS_HOSTNAME}" >&2 || true
  curl -sS -I --max-time 15 "https://${GRAFANA_HOSTNAME}/api/health" >&2 || true
  curl -sS -I --max-time 15 "https://${PROMETHEUS_HOSTNAME}/-/healthy" >&2 || true
  fail "Management Private DNS/HTTPS 검증 시간이 초과됐습니다. Tailscale 10.0.0.0/20 Route를 확인해주세요."
}

print_summary() {
  local aws_region="$1"
  local alb_arn
  local target_group_arn
  local zone_id

  log "========== Management Access 최종 상태 =========="
  aws elbv2 describe-load-balancers --region "${aws_region}" --names "${MANAGEMENT_ALB_NAME}"     --query 'LoadBalancers[0].{Name:LoadBalancerName,DNS:DNSName,Scheme:Scheme,VpcId:VpcId,State:State.Code}'     --output table
  alb_arn="$(aws elbv2 describe-load-balancers --region "${aws_region}"     --names "${MANAGEMENT_ALB_NAME}" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  for target_group_arn in $(aws elbv2 describe-target-groups --region "${aws_region}"     --load-balancer-arn "${alb_arn}" --query 'TargetGroups[].TargetGroupArn' --output text); do
    aws elbv2 describe-target-health --region "${aws_region}"       --target-group-arn "${target_group_arn}"       --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State}'       --output table
  done

  if [[ "${APPLY_MANAGEMENT_DNS}" == true ]]; then
    zone_id="$(terraform -chdir="${MANAGEMENT_DNS_DIR}" output -raw route53_zone_id)"
    aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}"       --query "ResourceRecordSets[?(Name=='${GRAFANA_HOSTNAME}.' || Name=='${PROMETHEUS_HOSTNAME}.') && Type=='A'].{Name:Name,Alias:AliasTarget.DNSName}"       --output table
  fi
  log "Grafana: https://${GRAFANA_HOSTNAME}"
  log "Prometheus: https://${PROMETHEUS_HOSTNAME}"
  log "===================================================="
}

[[ "${PETFLOW_INTERNAL_ORCHESTRATOR:-false}" == "true" ]]   || fail "직접 실행하지 말고 AWS_PROFILE=<profile> ./tapply.sh를 사용하세요."

for command_name in aws terraform kubectl jq curl getent; do
  require_command "${command_name}"
done

case "${APPLY_MANAGEMENT_DNS}" in
  true|false) ;;
  *) fail "APPLY_MANAGEMENT_DNS는 true 또는 false여야 합니다." ;;
esac

aws_region="${AWS_REGION:-}"
[[ -n "${aws_region}" ]] || fail "AWS_REGION이 설정되지 않았습니다."
expected_vpc_id="$(terraform -chdir="${TERRAFORM_DIR}" output -raw vpc_id)"
[[ -n "${expected_vpc_id}" ]] || fail "Terraform vpc_id output을 조회하지 못했습니다."

wait_for_management_alb "${aws_region}" "${expected_vpc_id}"
verify_management_target_health "${aws_region}"

if [[ "${APPLY_MANAGEMENT_DNS}" == true ]]; then
  apply_management_dns
  verify_management_https
else
  log "APPLY_MANAGEMENT_DNS=false이므로 Alias Apply와 HTTPS 검증을 생략했습니다."
fi

print_summary "${aws_region}"
