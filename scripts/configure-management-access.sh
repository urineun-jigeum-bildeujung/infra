#!/usr/bin/env bash
# Argo CD·Jenkins가 공유하는 Tailscale 전용 Internal ALB와 DNS/HTTPS를 검증·구성한다.
# Terraform은 frontend SG와 Route53을, AWS Load Balancer Controller는 ALB/TG/backend SG를 소유한다.
# shellcheck disable=SC2016 # 작은따옴표 안 backtick은 AWS CLI JMESPath 리터럴이다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform/environments/dev"
DNS_DIR="${ROOT_DIR}/terraform/environments/dev-management-dns"
KUBECONFIG_CONTEXT="petflow-dev"
MANAGEMENT_ALB_NAME="petflow-dev-management"
MANAGEMENT_STACK="petflow-dev-management"
EXPECTED_CLUSTER_NAME="petflow-eks"
EXPECTED_FRONTEND_SG_NAME="petflow-dev-management-alb"
ARGO_NAMESPACE="argocd"
ARGO_INGRESS="argocd-server"
ARGO_SERVICE="argocd-server"
ARGO_HOSTNAME="argocd.leechs.shop"
JENKINS_NAMESPACE="jenkins"
JENKINS_INGRESS="jenkins"
JENKINS_SERVICE="jenkins"
JENKINS_HOSTNAME="jenkins.leechs.shop"
APPLY_MANAGEMENT_DNS="${APPLY_MANAGEMENT_DNS:-true}"
TEMP_DNS_PLAN=""
MANAGEMENT_ALB_ARN=""
MANAGEMENT_ALB_DNS=""
ARGO_TARGET_GROUP_ARN=""
JENKINS_TARGET_GROUP_ARN=""

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
  command -v "$1" >/dev/null 2>&1 || fail "$1 명령이 필요합니다."
}

target_group_for_host() {
  local aws_region="$1"
  local listener_arn="$2"
  local hostname="$3"

  aws elbv2 describe-rules --region "${aws_region}" --listener-arn "${listener_arn}" \
    --output json 2>/dev/null \
    | jq -r --arg hostname "${hostname}" '
        [.Rules[]
          | select(any(.Conditions[]?;
              .Field == "host-header" and ((.Values // []) | index($hostname) != null)))
          | .Actions[]?
          | select(.Type == "forward")
          | (.TargetGroupArn // .ForwardConfig.TargetGroups[0].TargetGroupArn)]
        | first // empty' \
    || true
}

certificate_covers_host() {
  local aws_region="$1"
  local listener_arn="$2"
  local hostname="$3"
  local certificate_arn
  local certificate_status
  local subject_name
  local base_domain="${hostname#*.}"

  for certificate_arn in $(aws elbv2 describe-listener-certificates \
    --region "${aws_region}" --listener-arn "${listener_arn}" \
    --query 'Certificates[].CertificateArn' --output text 2>/dev/null || true); do
    certificate_status="$(aws acm describe-certificate --region "${aws_region}" \
      --certificate-arn "${certificate_arn}" --query 'Certificate.Status' --output text 2>/dev/null || true)"
    [[ "${certificate_status}" == "ISSUED" ]] || continue

    for subject_name in $(aws acm describe-certificate --region "${aws_region}" \
      --certificate-arn "${certificate_arn}" \
      --query 'Certificate.SubjectAlternativeNames' --output text 2>/dev/null || true); do
      if [[ "${subject_name}" == "${hostname}" || "${subject_name}" == "*.${base_domain}" ]]; then
        return 0
      fi
    done
  done

  return 1
}

ingress_contract_matches() {
  local namespace="$1"
  local ingress_name="$2"
  local hostname="$3"
  local backend_protocol="$4"
  local health_path="$5"
  local ingress_json

  ingress_json="$(kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${namespace}" \
    get ingress "${ingress_name}" -o json 2>/dev/null)" || return 1

  jq -e \
    --arg hostname "${hostname}" \
    --arg backend_protocol "${backend_protocol}" \
    --arg health_path "${health_path}" \
    --arg group "${MANAGEMENT_STACK}" \
    --arg alb_name "${MANAGEMENT_ALB_NAME}" \
    --arg sg_name "${EXPECTED_FRONTEND_SG_NAME}" '
      .spec.ingressClassName == "alb"
      and any(.spec.rules[]?; .host == $hostname)
      and .metadata.annotations["alb.ingress.kubernetes.io/group.name"] == $group
      and .metadata.annotations["alb.ingress.kubernetes.io/load-balancer-name"] == $alb_name
      and .metadata.annotations["alb.ingress.kubernetes.io/scheme"] == "internal"
      and .metadata.annotations["alb.ingress.kubernetes.io/target-type"] == "ip"
      and .metadata.annotations["alb.ingress.kubernetes.io/listen-ports"] == "[{\"HTTPS\":443}]"
      and .metadata.annotations["alb.ingress.kubernetes.io/security-groups"] == $sg_name
      and .metadata.annotations["alb.ingress.kubernetes.io/manage-backend-security-group-rules"] == "true"
      and .metadata.annotations["alb.ingress.kubernetes.io/backend-protocol"] == $backend_protocol
      and .metadata.annotations["alb.ingress.kubernetes.io/healthcheck-protocol"] == $backend_protocol
      and .metadata.annotations["alb.ingress.kubernetes.io/healthcheck-path"] == $health_path
      and .metadata.annotations["alb.ingress.kubernetes.io/success-codes"] == "200"' \
    <<< "${ingress_json}" >/dev/null
}

ready_endpoint_count() {
  local namespace="$1"
  local service_name="$2"

  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${namespace}" \
    get endpointslice -l "kubernetes.io/service-name=${service_name}" -o json 2>/dev/null \
    | jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length' \
    || printf '0\n'
}

targets_match_ready_endpoints() {
  local aws_region="$1"
  local namespace="$2"
  local service_name="$3"
  local target_group_arn="$4"
  local endpoints_json
  local endpoint_count
  local target_id
  local target_ids
  local -a target_array

  endpoints_json="$(kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${namespace}" \
    get endpointslice -l "kubernetes.io/service-name=${service_name}" -o json 2>/dev/null)" || return 1
  target_ids="$(aws elbv2 describe-target-health --region "${aws_region}" \
    --target-group-arn "${target_group_arn}" \
    --query 'TargetHealthDescriptions[].Target.Id' --output text 2>/dev/null || true)"
  [[ -n "${target_ids}" && "${target_ids}" != "None" ]] || return 1

  endpoint_count="$(jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length' \
    <<< "${endpoints_json}")"
  read -r -a target_array <<< "${target_ids}"
  [[ "${endpoint_count}" =~ ^[1-9][0-9]*$ && "${#target_array[@]}" -eq "${endpoint_count}" ]] \
    || return 1

  for target_id in "${target_array[@]}"; do
    jq -e --arg target_id "${target_id}" '
      any(.items[].endpoints[]?;
        .conditions.ready == true and ((.addresses // []) | index($target_id) != null))' \
      <<< "${endpoints_json}" >/dev/null || return 1
  done
}

frontend_security_group_contract_matches() {
  local aws_region="$1"
  local frontend_sg_id="$2"
  local router_sg_id="$3"
  local rules_json

  rules_json="$(aws ec2 describe-security-group-rules --region "${aws_region}" \
    --filters "Name=group-id,Values=${frontend_sg_id}" --output json 2>/dev/null)" || return 1

  jq -e --arg frontend_sg_id "${frontend_sg_id}" --arg router_sg_id "${router_sg_id}" '
    [.SecurityGroupRules[] | select(.IsEgress == false)] as $ingress
    | ($ingress | length) == 1
      and $ingress[0].GroupId == $frontend_sg_id
      and $ingress[0].IpProtocol == "tcp"
      and $ingress[0].FromPort == 443
      and $ingress[0].ToPort == 443
      and $ingress[0].ReferencedGroupInfo.GroupId == $router_sg_id
      and ($ingress[0].CidrIpv4 == null)
      and ($ingress[0].CidrIpv6 == null)
      and ($ingress[0].PrefixListId == null)' \
    <<< "${rules_json}" >/dev/null
}

target_group_contract_matches() {
  local aws_region="$1"
  local target_group_arn="$2"
  local expected_protocol="$3"
  local expected_health_path="$4"
  local target_group_json

  target_group_json="$(aws elbv2 describe-target-groups --region "${aws_region}" \
    --target-group-arns "${target_group_arn}" --output json 2>/dev/null)" || return 1

  jq -e --arg protocol "${expected_protocol}" --arg path "${expected_health_path}" '
    (.TargetGroups | length) == 1
    and .TargetGroups[0].TargetType == "ip"
    and .TargetGroups[0].Protocol == $protocol
    and .TargetGroups[0].Port == 8080
    and .TargetGroups[0].HealthCheckProtocol == $protocol
    and .TargetGroups[0].HealthCheckPath == $path
    and .TargetGroups[0].Matcher.HttpCode == "200"' \
    <<< "${target_group_json}" >/dev/null
}

targets_are_healthy() {
  local aws_region="$1"
  local target_group_arn="$2"
  local target_count
  local unhealthy_count

  target_count="$(aws elbv2 describe-target-health --region "${aws_region}" \
    --target-group-arn "${target_group_arn}" \
    --query 'length(TargetHealthDescriptions)' --output text 2>/dev/null || printf '0')"
  unhealthy_count="$(aws elbv2 describe-target-health --region "${aws_region}" \
    --target-group-arn "${target_group_arn}" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State!=`healthy`])' --output text 2>/dev/null || printf '1')"

  [[ "${target_count}" =~ ^[1-9][0-9]*$ && "${unhealthy_count}" == "0" ]]
}

diagnose_management_access() {
  local aws_region="$1"

  log "Management Ingress/ALB 진단 정보를 출력합니다."
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${ARGO_NAMESPACE}" \
    get ingress,service,endpointslice -o wide >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${JENKINS_NAMESPACE}" \
    get ingress,service,endpointslice -o wide >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${ARGO_NAMESPACE}" \
    describe ingress "${ARGO_INGRESS}" >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${JENKINS_NAMESPACE}" \
    describe ingress "${JENKINS_INGRESS}" >&2 || true
  aws elbv2 describe-load-balancers --region "${aws_region}" \
    --names "${MANAGEMENT_ALB_NAME}" --output table >&2 || true
  kubectl --context "${KUBECONFIG_CONTEXT}" --namespace kube-system \
    logs deployment/aws-load-balancer-controller --tail=200 >&2 || true
}

wait_for_management_alb() {
  local aws_region="$1"
  local expected_vpc_id="$2"
  local frontend_sg_id="$3"
  local deadline
  local alb_json
  local alb_arn
  local alb_dns
  local alb_state
  local alb_scheme
  local alb_vpc_id
  local alb_type
  local alb_sgs
  local stack_tag
  local cluster_tag
  local listener_arn
  local listener_count
  local argo_address
  local jenkins_address
  local argo_endpoints
  local jenkins_endpoints

  deadline=$(($(date +%s) + 1200))
  while (( $(date +%s) < deadline )); do
    argo_address="$(kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${ARGO_NAMESPACE}" \
      get ingress "${ARGO_INGRESS}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    jenkins_address="$(kubectl --context "${KUBECONFIG_CONTEXT}" --namespace "${JENKINS_NAMESPACE}" \
      get ingress "${JENKINS_INGRESS}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    alb_json="$(aws elbv2 describe-load-balancers --region "${aws_region}" \
      --names "${MANAGEMENT_ALB_NAME}" --output json 2>/dev/null || true)"
    alb_arn="$(jq -r '.LoadBalancers[0].LoadBalancerArn // empty' <<< "${alb_json}" 2>/dev/null || true)"
    alb_dns="$(jq -r '.LoadBalancers[0].DNSName // empty' <<< "${alb_json}" 2>/dev/null || true)"
    alb_state="$(jq -r '.LoadBalancers[0].State.Code // empty' <<< "${alb_json}" 2>/dev/null || true)"
    alb_scheme="$(jq -r '.LoadBalancers[0].Scheme // empty' <<< "${alb_json}" 2>/dev/null || true)"
    alb_vpc_id="$(jq -r '.LoadBalancers[0].VpcId // empty' <<< "${alb_json}" 2>/dev/null || true)"
    alb_type="$(jq -r '.LoadBalancers[0].Type // empty' <<< "${alb_json}" 2>/dev/null || true)"
    alb_sgs="$(jq -r '.LoadBalancers[0].SecurityGroups[]? // empty' <<< "${alb_json}" 2>/dev/null || true)"
    stack_tag="$(aws elbv2 describe-tags --region "${aws_region}" --resource-arns "${alb_arn}" \
      --query 'TagDescriptions[0].Tags[?Key==`ingress.k8s.aws/stack`].Value | [0]' \
      --output text 2>/dev/null || true)"
    cluster_tag="$(aws elbv2 describe-tags --region "${aws_region}" --resource-arns "${alb_arn}" \
      --query 'TagDescriptions[0].Tags[?Key==`elbv2.k8s.aws/cluster`].Value | [0]' \
      --output text 2>/dev/null || true)"
    listener_count="$(aws elbv2 describe-listeners --region "${aws_region}" \
      --load-balancer-arn "${alb_arn}" --query 'length(Listeners)' --output text 2>/dev/null || printf '0')"
    listener_arn="$(aws elbv2 describe-listeners --region "${aws_region}" \
      --load-balancer-arn "${alb_arn}" \
      --query 'Listeners[?Port==`443` && Protocol==`HTTPS`].ListenerArn | [0]' \
      --output text 2>/dev/null || true)"
    [[ "${listener_arn}" != "None" ]] || listener_arn=""
    ARGO_TARGET_GROUP_ARN="$(target_group_for_host "${aws_region}" "${listener_arn}" "${ARGO_HOSTNAME}")"
    JENKINS_TARGET_GROUP_ARN="$(target_group_for_host "${aws_region}" "${listener_arn}" "${JENKINS_HOSTNAME}")"
    argo_endpoints="$(ready_endpoint_count "${ARGO_NAMESPACE}" "${ARGO_SERVICE}")"
    jenkins_endpoints="$(ready_endpoint_count "${JENKINS_NAMESPACE}" "${JENKINS_SERVICE}")"

    if ingress_contract_matches "${ARGO_NAMESPACE}" "${ARGO_INGRESS}" "${ARGO_HOSTNAME}" HTTPS /healthz \
      && ingress_contract_matches "${JENKINS_NAMESPACE}" "${JENKINS_INGRESS}" "${JENKINS_HOSTNAME}" HTTP /login \
      && [[ -n "${alb_arn}" && "${alb_state}" == "active" && "${alb_scheme}" == "internal" \
        && "${alb_type}" == "application" && "${alb_vpc_id}" == "${expected_vpc_id}" \
        && "${stack_tag}" == "${MANAGEMENT_STACK}" && "${cluster_tag}" == "${EXPECTED_CLUSTER_NAME}" \
        && "${argo_address}" == "${alb_dns}" && "${jenkins_address}" == "${alb_dns}" \
        && "${listener_count}" == "1" && -n "${listener_arn}" \
        && "${alb_sgs}" =~ (^|[[:space:]])${frontend_sg_id}($|[[:space:]]) \
        && "${argo_endpoints}" =~ ^[1-9][0-9]*$ && "${jenkins_endpoints}" =~ ^[1-9][0-9]*$ \
        && -n "${ARGO_TARGET_GROUP_ARN}" && -n "${JENKINS_TARGET_GROUP_ARN}" ]] \
      && certificate_covers_host "${aws_region}" "${listener_arn}" "${ARGO_HOSTNAME}" \
      && certificate_covers_host "${aws_region}" "${listener_arn}" "${JENKINS_HOSTNAME}" \
      && target_group_contract_matches "${aws_region}" "${ARGO_TARGET_GROUP_ARN}" HTTPS /healthz \
      && target_group_contract_matches "${aws_region}" "${JENKINS_TARGET_GROUP_ARN}" HTTP /login \
      && targets_are_healthy "${aws_region}" "${ARGO_TARGET_GROUP_ARN}" \
      && targets_are_healthy "${aws_region}" "${JENKINS_TARGET_GROUP_ARN}" \
      && targets_match_ready_endpoints "${aws_region}" "${ARGO_NAMESPACE}" "${ARGO_SERVICE}" "${ARGO_TARGET_GROUP_ARN}" \
      && targets_match_ready_endpoints "${aws_region}" "${JENKINS_NAMESPACE}" "${JENKINS_SERVICE}" "${JENKINS_TARGET_GROUP_ARN}"; then
      MANAGEMENT_ALB_ARN="${alb_arn}"
      MANAGEMENT_ALB_DNS="${alb_dns}"
      log "Management ALB Guard 통과: dns=${alb_dns}, scheme=internal, listener=443, Argo/Jenkins targets=healthy"
      return
    fi

    log "Management ALB 대기 중: argoIngress=${argo_address:-empty}, jenkinsIngress=${jenkins_address:-empty}, alb=${alb_dns:-not-found}, state=${alb_state:-not-found}, scheme=${alb_scheme:-unknown}, listener443=${listener_arn:+present}, argoTG=${ARGO_TARGET_GROUP_ARN:+present}, jenkinsTG=${JENKINS_TARGET_GROUP_ARN:+present}"
    sleep 10
  done

  diagnose_management_access "${aws_region}"
  fail "Management Internal ALB, Ingress 계약 또는 Target Health 확인 시간이 초과됐습니다."
}

apply_access_dns() {
  local changed_count
  local unexpected_count

  [[ -f "${DNS_DIR}/backend.hcl" ]] || fail "Management DNS backend.hcl 파일이 없습니다."
  [[ -f "${DNS_DIR}/terraform.tfvars" ]] || fail "Management DNS terraform.tfvars 파일이 없습니다."

  terraform -chdir="${DNS_DIR}" init -backend-config=backend.hcl -input=false >/dev/null
  TEMP_DNS_PLAN="$(mktemp /tmp/petflow-management-dns.XXXXXX)"
  terraform -chdir="${DNS_DIR}" plan -input=false -out="${TEMP_DNS_PLAN}"

  changed_count="$(terraform -chdir="${DNS_DIR}" show -json "${TEMP_DNS_PLAN}" \
    | jq '[.resource_changes[] | select(.mode == "managed" and (.change.actions != ["no-op"]))] | length')"
  unexpected_count="$(terraform -chdir="${DNS_DIR}" show -json "${TEMP_DNS_PLAN}" \
    | jq '[.resource_changes[]
      | select(.mode == "managed" and (.change.actions != ["no-op"]))
      | select(
          ((.address == "aws_route53_record.grafana"
              or .address == "aws_route53_record.argocd"
              or .address == "aws_route53_record.jenkins")
            and ((.change.actions == ["create"]) or (.change.actions == ["update"])))
          or ((.address == "aws_route53_record.prometheus")
            and (.change.actions == ["delete"]))
          | not)
    ] | length')"

  if (( changed_count == 0 )); then
    log "Management DNS State는 이미 현재 ALB와 일치합니다."
  elif (( changed_count <= 4 && unexpected_count == 0 )); then
    log "Management DNS Guard 통과: 허용된 Alias 변경 ${changed_count}건"
    terraform -chdir="${DNS_DIR}" apply -input=false "${TEMP_DNS_PLAN}"
  else
    terraform -chdir="${DNS_DIR}" show "${TEMP_DNS_PLAN}" >&2
    fail "Management DNS Plan에 예상하지 않은 변경이 있습니다. Apply하지 않습니다."
  fi

  terraform -chdir="${DNS_DIR}" plan -input=false -detailed-exitcode
  log "Management DNS 사후 Plan No changes 확인 완료"
}

verify_dns_https_and_tailscale_route() {
  local deadline
  local zone_id
  local argo_alias
  local jenkins_alias
  local argo_ip
  local jenkins_ip
  local argo_route
  local jenkins_route
  local argo_body
  local jenkins_body
  local argo_http
  local jenkins_http

  zone_id="$(terraform -chdir="${DNS_DIR}" output -raw route53_zone_id)"
  argo_body="$(mktemp /tmp/petflow-argocd-ui.XXXXXX)"
  jenkins_body="$(mktemp /tmp/petflow-jenkins-ui.XXXXXX)"
  deadline=$(($(date +%s) + 600))

  while (( $(date +%s) < deadline )); do
    argo_alias="$(aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" \
      --query "ResourceRecordSets[?Name=='${ARGO_HOSTNAME}.' && Type=='A'].AliasTarget.DNSName | [0]" \
      --output text 2>/dev/null || true)"
    jenkins_alias="$(aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" \
      --query "ResourceRecordSets[?Name=='${JENKINS_HOSTNAME}.' && Type=='A'].AliasTarget.DNSName | [0]" \
      --output text 2>/dev/null || true)"
    argo_ip="$(dig +short "${ARGO_HOSTNAME}" A | head -n 1)"
    jenkins_ip="$(dig +short "${JENKINS_HOSTNAME}" A | head -n 1)"
    argo_route="$(ip route get "${argo_ip}" 2>/dev/null || true)"
    jenkins_route="$(ip route get "${jenkins_ip}" 2>/dev/null || true)"
    argo_http="$(curl -sS -L --connect-timeout 5 --max-time 15 -o "${argo_body}" \
      -w '%{http_code}' "https://${ARGO_HOSTNAME}/" 2>/dev/null || true)"
    jenkins_http="$(curl -sS -L --connect-timeout 5 --max-time 15 -o "${jenkins_body}" \
      -w '%{http_code}' "https://${JENKINS_HOSTNAME}/login" 2>/dev/null || true)"

    if [[ "${argo_alias%.}" == "${MANAGEMENT_ALB_DNS%.}" \
      && "${jenkins_alias%.}" == "${MANAGEMENT_ALB_DNS%.}" \
      && -n "${argo_ip}" && -n "${jenkins_ip}" \
      && "${argo_route}" == *"dev tailscale0"* && "${jenkins_route}" == *"dev tailscale0"* \
      && "${argo_http}" == "200" && "${jenkins_http}" == "200" ]] \
      && grep -qi 'Argo CD' "${argo_body}" \
      && grep -qi 'Jenkins' "${jenkins_body}"; then
      rm -f "${argo_body}" "${jenkins_body}"
      log "Management DNS/TLS/UI 검증 완료: Argo CD=200, Jenkins=200, route=tailscale0"
      return
    fi

    log "Management DNS/HTTPS 대기 중: argoAlias=${argo_alias:-missing}, jenkinsAlias=${jenkins_alias:-missing}, argoHTTP=${argo_http:-000}, jenkinsHTTP=${jenkins_http:-000}, argoRoute=${argo_route:-unresolved}, jenkinsRoute=${jenkins_route:-unresolved}"
    sleep 10
  done

  rm -f "${argo_body}" "${jenkins_body}"
  dig +short "${ARGO_HOSTNAME}" A >&2 || true
  dig +short "${JENKINS_HOSTNAME}" A >&2 || true
  fail "Management DNS, Tailscale 경로, TLS 또는 로그인 화면 검증 시간이 초과됐습니다."
}

print_summary() {
  local aws_region="$1"

  log "========== Management Access 최종 상태 =========="
  log "Management ALB ARN: ${MANAGEMENT_ALB_ARN}"
  aws elbv2 describe-load-balancers --region "${aws_region}" --names "${MANAGEMENT_ALB_NAME}" \
    --query 'LoadBalancers[0].{Name:LoadBalancerName,DNS:DNSName,Scheme:Scheme,VpcId:VpcId,State:State.Code,SecurityGroups:SecurityGroups}' \
    --output table
  aws elbv2 describe-target-health --region "${aws_region}" --target-group-arn "${ARGO_TARGET_GROUP_ARN}" \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State}' --output table
  aws elbv2 describe-target-health --region "${aws_region}" --target-group-arn "${JENKINS_TARGET_GROUP_ARN}" \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State}' --output table
  log "Argo CD: https://${ARGO_HOSTNAME} (Tailscale 연결 필요)"
  log "Jenkins: https://${JENKINS_HOSTNAME} (Tailscale 연결 필요)"
  log "===================================================="
}

[[ "${PETFLOW_INTERNAL_ORCHESTRATOR:-false}" == "true" ]] \
  || fail "직접 실행하지 말고 AWS_PROFILE=<profile> ./tapply.sh를 사용하세요."
for command_name in aws terraform kubectl jq curl dig ip grep; do
  require_command "${command_name}"
done
case "${APPLY_MANAGEMENT_DNS}" in
  true|false) ;;
  *) fail "APPLY_MANAGEMENT_DNS는 true 또는 false여야 합니다." ;;
esac

aws_region="${AWS_REGION:-}"
[[ -n "${aws_region}" ]] || fail "AWS_REGION이 설정되지 않았습니다."
expected_vpc_id="$(terraform -chdir="${TERRAFORM_DIR}" output -raw vpc_id)"
frontend_sg_id="$(terraform -chdir="${TERRAFORM_DIR}" output -raw management_alb_security_group_id)"
frontend_sg_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw management_alb_security_group_name)"
router_sg_id="$(terraform -chdir="${TERRAFORM_DIR}" output -raw tailscale_router_security_group_id)"
[[ "${frontend_sg_name}" == "${EXPECTED_FRONTEND_SG_NAME}" ]] \
  || fail "Management ALB frontend SG 이름이 기대값과 다릅니다: ${frontend_sg_name:-missing}"
[[ -n "${router_sg_id}" ]] || fail "Tailscale Router SG output을 확인할 수 없습니다."
frontend_security_group_contract_matches "${aws_region}" "${frontend_sg_id}" "${router_sg_id}" \
  || fail "Management ALB SG는 Tailscale Router SG에서 오는 TCP/443 단일 인바운드 규칙이어야 합니다."

wait_for_management_alb "${aws_region}" "${expected_vpc_id}" "${frontend_sg_id}"

if [[ "${APPLY_MANAGEMENT_DNS}" == true ]]; then
  apply_access_dns
  verify_dns_https_and_tailscale_route
else
  log "APPLY_MANAGEMENT_DNS=false이므로 Alias Apply와 도메인 HTTPS 검증을 생략했습니다."
fi

print_summary "${aws_region}"
