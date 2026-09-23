#!/usr/bin/env bash
# Public Grafana ALB/DNS/HTTPS와 Private Prometheus 정책을 검증·구성하는 내부 스크립트다.
# 기존 dev-management-dns State는 DNS 소유권 연속성을 위해 그대로 사용한다.
# shellcheck disable=SC2016 # 작은따옴표 안 backtick은 AWS CLI JMESPath 리터럴이다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform/environments/dev"
OBSERVABILITY_DNS_DIR="${ROOT_DIR}/terraform/environments/dev-management-dns"
KUBECONFIG_CONTEXT="petflow-dev"
OBSERVABILITY_NAMESPACE="observability"
GRAFANA_INGRESS_NAME="grafana-public"
PUBLIC_ALB_NAME="petflow-dev-public"
LEGACY_MANAGEMENT_ALB_NAME="petflow-dev-management"
EXPECTED_INGRESS_STACK="petflow-public"
EXPECTED_EKS_CLUSTER_NAME="petflow-eks"
GRAFANA_HOSTNAME="grafana.leechs.shop"
PROMETHEUS_HOSTNAME="prometheus.leechs.shop"
APPLY_OBSERVABILITY_DNS="${APPLY_OBSERVABILITY_DNS:-true}"
TEMP_DNS_PLAN=""
GRAFANA_TARGET_GROUP_ARN=""

log() {
  printf '[observability-access] %s\n' "$*"
}

fail() {
  printf '[observability-access] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_DNS_PLAN}" && -f "${TEMP_DNS_PLAN}" ]]; then
    rm -f "${TEMP_DNS_PLAN}"
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 명령이 필요합니다."
}

verify_grafana_admin_secret() {
  local secret_json
  local encoded_user
  local encoded_password
  local admin_user
  local admin_password

  secret_json="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
    --namespace "${OBSERVABILITY_NAMESPACE}" \
    get secret kube-prometheus-stack-grafana -o json 2>/dev/null)" \
    || fail "Grafana 관리자 Kubernetes Secret을 조회하지 못했습니다."
  encoded_user="$(jq -r '.data["admin-user"] // empty' <<< "${secret_json}")"
  encoded_password="$(jq -r '.data["admin-password"] // empty' <<< "${secret_json}")"
  [[ -n "${encoded_user}" && -n "${encoded_password}" ]] \
    || fail "Grafana 관리자 Secret에 admin-user/admin-password 키가 없습니다."

  admin_user="$(base64 --decode <<< "${encoded_user}")"
  admin_password="$(base64 --decode <<< "${encoded_password}")"
  [[ -n "${admin_user}" && ${#admin_password} -ge 16 ]] \
    || fail "Grafana 관리자 계정 또는 비밀번호 정책을 충족하지 못했습니다."
  if [[ "${admin_user}" == "admin" && "${admin_password}" == "admin" ]]; then
    fail "Grafana 기본 admin/admin 조합은 허용하지 않습니다."
  fi

  unset admin_user admin_password encoded_user encoded_password secret_json
  log "Grafana 관리자 Secret Guard 통과: 값은 출력하지 않음"
}

prometheus_ingress_count() {
  local ingress_json

  if ! ingress_json="$(kubectl --context "${KUBECONFIG_CONTEXT}" get ingress -A -o json 2>/dev/null)"; then
    printf '%s\n' '-1'
    return
  fi

  jq --arg hostname "${PROMETHEUS_HOSTNAME}" \
    '[.items[] | select(any(.spec.rules[]?; .host == $hostname))] | length' \
    <<< "${ingress_json}"
}

grafana_target_group_arn() {
  local aws_region="$1"
  local listener_arn="$2"

  aws elbv2 describe-rules --region "${aws_region}" --listener-arn "${listener_arn}" \
    --output json 2>/dev/null \
    | jq -r --arg hostname "${GRAFANA_HOSTNAME}" '
        [.Rules[]
          | select(any(.Conditions[]?;
              .Field == "host-header" and ((.Values // []) | index($hostname) != null)))
          | .Actions[]?
          | select(.Type == "forward")
          | (.TargetGroupArn // .ForwardConfig.TargetGroups[0].TargetGroupArn)]
        | first // empty' \
    || true
}

certificate_covers_grafana() {
  local aws_region="$1"
  local listener_arn="$2"
  local certificate_arn
  local certificate_status
  local subject_name
  local base_domain="${GRAFANA_HOSTNAME#*.}"

  for certificate_arn in $(aws elbv2 describe-listener-certificates \
    --region "${aws_region}" --listener-arn "${listener_arn}" \
    --query 'Certificates[].CertificateArn' --output text 2>/dev/null || true); do
    certificate_status="$(aws acm describe-certificate --region "${aws_region}" \
      --certificate-arn "${certificate_arn}" --query 'Certificate.Status' --output text 2>/dev/null || true)"
    [[ "${certificate_status}" == "ISSUED" ]] || continue

    for subject_name in $(aws acm describe-certificate --region "${aws_region}" \
      --certificate-arn "${certificate_arn}" \
      --query 'Certificate.SubjectAlternativeNames' --output text 2>/dev/null || true); do
      if [[ "${subject_name}" == "${GRAFANA_HOSTNAME}" || "${subject_name}" == "*.${base_domain}" ]]; then
        return 0
      fi
    done
  done

  return 1
}

diagnose_observability_access() {
  local aws_region="$1"

  log "Grafana Public Ingress/ALB 진단 정보를 출력합니다."
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${OBSERVABILITY_NAMESPACE}" \
    get ingress,service,endpoints -o wide >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${OBSERVABILITY_NAMESPACE}" \
    describe ingress "${GRAFANA_INGRESS_NAME}" >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace kube-system \
    logs deployment/aws-load-balancer-controller --tail=200 >&2 || true
  aws elbv2 describe-load-balancers --region "${aws_region}" \
    --names "${PUBLIC_ALB_NAME}" --output table >&2 || true
}

wait_for_grafana_public_alb() {
  local aws_region="$1"
  local expected_vpc_id="$2"
  local deadline
  local ingress_address
  local ingress_group
  local ingress_scheme
  local ingress_alb_name
  local prometheus_ingresses
  local alb_arn
  local legacy_alb_arn
  local alb_dns
  local alb_state
  local alb_scheme
  local alb_vpc_id
  local stack_tag
  local cluster_tag
  local listener_ports
  local https_listener_arn
  local target_group_arn

  deadline=$(($(date +%s) + 1200))
  while (( $(date +%s) < deadline )); do
    ingress_address="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace "${OBSERVABILITY_NAMESPACE}" get ingress "${GRAFANA_INGRESS_NAME}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    ingress_group="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace "${OBSERVABILITY_NAMESPACE}" get ingress "${GRAFANA_INGRESS_NAME}" \
      -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/group\.name}' 2>/dev/null || true)"
    ingress_scheme="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace "${OBSERVABILITY_NAMESPACE}" get ingress "${GRAFANA_INGRESS_NAME}" \
      -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/scheme}' 2>/dev/null || true)"
    ingress_alb_name="$(kubectl --context "${KUBECONFIG_CONTEXT}" \
      --namespace "${OBSERVABILITY_NAMESPACE}" get ingress "${GRAFANA_INGRESS_NAME}" \
      -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/load-balancer-name}' 2>/dev/null || true)"
    prometheus_ingresses="$(prometheus_ingress_count)"

    alb_arn="$(aws elbv2 describe-load-balancers --region "${aws_region}" \
      --names "${PUBLIC_ALB_NAME}" --query 'LoadBalancers[0].LoadBalancerArn' \
      --output text 2>/dev/null || true)"
    legacy_alb_arn="$(aws elbv2 describe-load-balancers --region "${aws_region}" \
      --names "${LEGACY_MANAGEMENT_ALB_NAME}" --query 'LoadBalancers[0].LoadBalancerArn' \
      --output text 2>/dev/null || true)"
    alb_dns="$(aws elbv2 describe-load-balancers --region "${aws_region}" \
      --names "${PUBLIC_ALB_NAME}" --query 'LoadBalancers[0].DNSName' \
      --output text 2>/dev/null || true)"
    alb_state="$(aws elbv2 describe-load-balancers --region "${aws_region}" \
      --names "${PUBLIC_ALB_NAME}" --query 'LoadBalancers[0].State.Code' \
      --output text 2>/dev/null || true)"
    alb_scheme="$(aws elbv2 describe-load-balancers --region "${aws_region}" \
      --names "${PUBLIC_ALB_NAME}" --query 'LoadBalancers[0].Scheme' \
      --output text 2>/dev/null || true)"
    alb_vpc_id="$(aws elbv2 describe-load-balancers --region "${aws_region}" \
      --names "${PUBLIC_ALB_NAME}" --query 'LoadBalancers[0].VpcId' \
      --output text 2>/dev/null || true)"
    stack_tag="$(aws elbv2 describe-tags --region "${aws_region}" --resource-arns "${alb_arn}" \
      --query 'TagDescriptions[0].Tags[?Key==`ingress.k8s.aws/stack`].Value | [0]' \
      --output text 2>/dev/null || true)"
    cluster_tag="$(aws elbv2 describe-tags --region "${aws_region}" --resource-arns "${alb_arn}" \
      --query 'TagDescriptions[0].Tags[?Key==`elbv2.k8s.aws/cluster`].Value | [0]' \
      --output text 2>/dev/null || true)"
    listener_ports="$(aws elbv2 describe-listeners --region "${aws_region}" \
      --load-balancer-arn "${alb_arn}" --query 'Listeners[].Port' --output text 2>/dev/null || true)"
    https_listener_arn="$(aws elbv2 describe-listeners --region "${aws_region}" \
      --load-balancer-arn "${alb_arn}" --query 'Listeners[?Port==`443`].ListenerArn | [0]' \
      --output text 2>/dev/null || true)"
    target_group_arn="$(grafana_target_group_arn "${aws_region}" "${https_listener_arn}")"

    if [[ -n "${ingress_address}" && "${ingress_address}" == "${alb_dns}" \
      && "${ingress_group}" == "${EXPECTED_INGRESS_STACK}" \
      && "${ingress_scheme}" == "internet-facing" \
      && "${ingress_alb_name}" == "${PUBLIC_ALB_NAME}" \
      && "${prometheus_ingresses}" == "0" \
      && ( -z "${legacy_alb_arn}" || "${legacy_alb_arn}" == "None" ) \
      && "${alb_state}" == "active" && "${alb_scheme}" == "internet-facing" \
      && "${alb_vpc_id}" == "${expected_vpc_id}" \
      && "${stack_tag}" == "${EXPECTED_INGRESS_STACK}" \
      && "${cluster_tag}" == "${EXPECTED_EKS_CLUSTER_NAME}" \
      && "${listener_ports}" =~ (^|[[:space:]])80($|[[:space:]]) \
      && "${listener_ports}" =~ (^|[[:space:]])443($|[[:space:]]) \
      && -n "${target_group_arn}" ]] \
      && certificate_covers_grafana "${aws_region}" "${https_listener_arn}"; then
      log "Public ALB Guard 통과: dns=${alb_dns}, group=${ingress_group}, prometheusIngress=0"
      GRAFANA_TARGET_GROUP_ARN="${target_group_arn}"
      return
    fi

    log "Grafana Public ALB 대기 중: ingress=${ingress_address:-empty}, group=${ingress_group:-empty}, scheme=${ingress_scheme:-empty}/${alb_scheme:-empty}, explicitAlbName=${ingress_alb_name:-none}, prometheusIngress=${prometheus_ingresses:-unknown}, legacyAlb=${legacy_alb_arn:+present}, alb=${alb_dns:-not-found}, state=${alb_state:-not-found}, targetGroup=${target_group_arn:-not-found}"
    sleep 10
  done

  diagnose_observability_access "${aws_region}"
  fail "Grafana Public Ingress/ALB Guard 확인 시간이 초과됐습니다."
}

verify_grafana_target_health() {
  local aws_region="$1"
  local target_group_arn="$2"
  local deadline
  local target_count
  local unhealthy_count

  deadline=$(($(date +%s) + 900))
  while (( $(date +%s) < deadline )); do
    target_count="$(aws elbv2 describe-target-health --region "${aws_region}" \
      --target-group-arn "${target_group_arn}" \
      --query 'length(TargetHealthDescriptions)' --output text)"
    unhealthy_count="$(aws elbv2 describe-target-health --region "${aws_region}" \
      --target-group-arn "${target_group_arn}" \
      --query 'length(TargetHealthDescriptions[?TargetHealth.State!=`healthy`])' --output text)"

    if (( target_count > 0 && unhealthy_count == 0 )); then
      log "Grafana Target healthy 확인 완료: targets=${target_count}"
      return
    fi

    log "Grafana Target healthy 대기 중: targets=${target_count}, unhealthy=${unhealthy_count}"
    sleep 10
  done

  aws elbv2 describe-target-health --region "${aws_region}" \
    --target-group-arn "${target_group_arn}" \
    --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
    --output table >&2 || true
  fail "Grafana Target이 제한 시간 내 healthy가 되지 않았습니다."
}

apply_observability_dns() {
  local changed_count
  local unexpected_count

  [[ -f "${OBSERVABILITY_DNS_DIR}/backend.hcl" ]] \
    || fail "Observability DNS backend.hcl 파일이 없습니다: ${OBSERVABILITY_DNS_DIR}/backend.hcl"
  [[ -f "${OBSERVABILITY_DNS_DIR}/terraform.tfvars" ]] \
    || fail "Observability DNS terraform.tfvars 파일이 없습니다: ${OBSERVABILITY_DNS_DIR}/terraform.tfvars"

  terraform -chdir="${OBSERVABILITY_DNS_DIR}" init \
    -backend-config=backend.hcl -input=false >/dev/null
  TEMP_DNS_PLAN="$(mktemp /tmp/petflow-observability-dns.XXXXXX)"
  terraform -chdir="${OBSERVABILITY_DNS_DIR}" plan -input=false -out="${TEMP_DNS_PLAN}"

  changed_count="$(terraform -chdir="${OBSERVABILITY_DNS_DIR}" show -json "${TEMP_DNS_PLAN}" \
    | jq '[.resource_changes[] | select(.mode == "managed" and (.change.actions != ["no-op"]))] | length')"
  unexpected_count="$(terraform -chdir="${OBSERVABILITY_DNS_DIR}" show -json "${TEMP_DNS_PLAN}" \
    | jq '[.resource_changes[]
      | select(.mode == "managed" and (.change.actions != ["no-op"]))
      | select(
          ((.address == "aws_route53_record.grafana")
            and ((.change.actions == ["create"]) or (.change.actions == ["update"])))
          or ((.address == "aws_route53_record.prometheus")
            and (.change.actions == ["delete"]))
          | not)
    ] | length')"

  if (( changed_count == 0 )); then
    log "Observability DNS는 이미 공개 Grafana·비공개 Prometheus 정책과 일치합니다."
  elif (( changed_count <= 2 && unexpected_count == 0 )); then
    log "Observability DNS Guard 통과: 허용된 Grafana create/update 및 Prometheus delete ${changed_count}건"
    terraform -chdir="${OBSERVABILITY_DNS_DIR}" apply -input=false "${TEMP_DNS_PLAN}"
  else
    terraform -chdir="${OBSERVABILITY_DNS_DIR}" show "${TEMP_DNS_PLAN}" >&2
    fail "Observability DNS Plan에 예상하지 않은 변경이 있습니다. Apply하지 않습니다."
  fi

  terraform -chdir="${OBSERVABILITY_DNS_DIR}" plan -input=false -detailed-exitcode
  log "Observability DNS 사후 Plan No changes 확인 완료"
}

verify_public_grafana_private_prometheus() {
  local deadline
  local zone_id
  local alb_dns
  local grafana_alias
  local prometheus_record_count
  local grafana_http
  local grafana_health
  local grafana_login
  local grafana_api_user

  zone_id="$(terraform -chdir="${OBSERVABILITY_DNS_DIR}" output -raw route53_zone_id)"
  alb_dns="$(terraform -chdir="${OBSERVABILITY_DNS_DIR}" output -raw public_alb_dns_name)"
  deadline=$(($(date +%s) + 600))

  while (( $(date +%s) < deadline )); do
    grafana_alias="$(aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" \
      --query "ResourceRecordSets[?Name=='${GRAFANA_HOSTNAME}.' && Type=='A'].AliasTarget.DNSName | [0]" \
      --output text 2>/dev/null || true)"
    prometheus_record_count="$(aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" \
      --output json | jq --arg name "${PROMETHEUS_HOSTNAME}." \
      '[.ResourceRecordSets[] | select(.Name == $name)] | length')"
    grafana_http="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      "http://${GRAFANA_HOSTNAME}/" 2>/dev/null || true)"
    grafana_health="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      "https://${GRAFANA_HOSTNAME}/api/health" 2>/dev/null || true)"
    grafana_login="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      "https://${GRAFANA_HOSTNAME}/login" 2>/dev/null || true)"
    grafana_api_user="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      "https://${GRAFANA_HOSTNAME}/api/user" 2>/dev/null || true)"

    if [[ "${grafana_alias%.}" == "${alb_dns%.}" \
      && "${prometheus_record_count}" == "0" \
      && "${grafana_http}" == "301" && "${grafana_health}" == "200" \
      && "${grafana_login}" == "200" && "${grafana_api_user}" == "401" ]]; then
      log "접근 정책 검증 완료: Grafana HTTP=${grafana_http}, health=${grafana_health}, login=${grafana_login}, unauthenticatedAPI=${grafana_api_user}, PrometheusDNS=absent"
      return
    fi

    log "DNS/HTTPS 대기 중: grafanaAlias=${grafana_alias:-missing}, HTTP=${grafana_http:-000}, health=${grafana_health:-000}, login=${grafana_login:-000}, unauthenticatedAPI=${grafana_api_user:-000}, prometheusDNS=${prometheus_record_count:-unknown}"
    sleep 10
  done

  getent ahostsv4 "${GRAFANA_HOSTNAME}" >&2 || true
  curl -sS -I --max-time 15 "https://${GRAFANA_HOSTNAME}/login" >&2 || true
  fail "Grafana 공개 HTTPS 또는 Prometheus 비공개 정책 검증 시간이 초과됐습니다."
}

print_summary() {
  local aws_region="$1"
  local zone_id

  log "========== Observability Access 최종 상태 =========="
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${OBSERVABILITY_NAMESPACE}" \
    get ingress "${GRAFANA_INGRESS_NAME}" -o wide
  aws elbv2 describe-load-balancers --region "${aws_region}" --names "${PUBLIC_ALB_NAME}" \
    --query 'LoadBalancers[0].{Name:LoadBalancerName,DNS:DNSName,Scheme:Scheme,VpcId:VpcId,State:State.Code}' \
    --output table
  if [[ "${APPLY_OBSERVABILITY_DNS}" == true ]]; then
    zone_id="$(terraform -chdir="${OBSERVABILITY_DNS_DIR}" output -raw route53_zone_id)"
    aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" \
      --query "ResourceRecordSets[?(Name=='${GRAFANA_HOSTNAME}.' || Name=='${PROMETHEUS_HOSTNAME}.')].{Name:Name,Type:Type,Alias:AliasTarget.DNSName}" \
      --output table
  fi
  log "Grafana: https://${GRAFANA_HOSTNAME} (HTTPS + 로그인 필수)"
  log "Prometheus: kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090 (클러스터 내부 전용)"
  log "======================================================"
}

[[ "${PETFLOW_INTERNAL_ORCHESTRATOR:-false}" == "true" ]] \
  || fail "직접 실행하지 말고 AWS_PROFILE=<profile> ./tapply.sh를 사용하세요."
for command_name in aws terraform kubectl jq curl getent base64; do
  require_command "${command_name}"
done
case "${APPLY_OBSERVABILITY_DNS}" in
  true|false) ;;
  *) fail "APPLY_OBSERVABILITY_DNS는 true 또는 false여야 합니다." ;;
esac

aws_region="${AWS_REGION:-}"
[[ -n "${aws_region}" ]] || fail "AWS_REGION이 설정되지 않았습니다."
expected_vpc_id="$(terraform -chdir="${TERRAFORM_DIR}" output -raw vpc_id)"
[[ -n "${expected_vpc_id}" ]] || fail "Terraform vpc_id output을 조회하지 못했습니다."

verify_grafana_admin_secret
wait_for_grafana_public_alb "${aws_region}" "${expected_vpc_id}"
[[ -n "${GRAFANA_TARGET_GROUP_ARN}" ]] || fail "Grafana Target Group ARN을 확인하지 못했습니다."
verify_grafana_target_health "${aws_region}" "${GRAFANA_TARGET_GROUP_ARN}"

if [[ "${APPLY_OBSERVABILITY_DNS}" == true ]]; then
  apply_observability_dns
  verify_public_grafana_private_prometheus
else
  log "APPLY_OBSERVABILITY_DNS=false이므로 Alias Apply와 외부 HTTPS 검증을 생략했습니다."
fi

print_summary "${aws_region}"
