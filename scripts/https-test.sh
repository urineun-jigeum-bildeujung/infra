#!/usr/bin/env bash
# test.leechs.shop의 DNS -> TLS -> ALB -> Ingress -> Service -> Pod 경로를 검증한다.
#
# 사용:
#   AWS_PROFILE=ujibil2 ./scripts/https-test.sh deploy
#   AWS_PROFILE=ujibil2 ./scripts/https-test.sh status
#   AWS_PROFILE=ujibil2 ./scripts/https-test.sh cleanup

set -euo pipefail

ACTION="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform/environments/dev"
MANIFEST_FILE="${ROOT_DIR}/kubernetes/tests/https-test.yaml"
NAMESPACE="https-test"
INGRESS_NAME="https-test"
ALB_NAME="petflow-dev-https-test"
HOST_NAME="test.leechs.shop"
TEMP_KUBECONFIG=""

cleanup_temp_kubeconfig() {
  if [[ -n "${TEMP_KUBECONFIG}" && -f "${TEMP_KUBECONFIG}" ]]; then
    rm -f "${TEMP_KUBECONFIG}"
  fi
}
trap cleanup_temp_kubeconfig EXIT

usage() {
  echo "사용: AWS_PROFILE=<profile> $0 {deploy|status|cleanup}"
}

if [[ ! "${ACTION}" =~ ^(deploy|status|cleanup)$ ]]; then
  usage
  exit 1
fi

for command_name in aws terraform kubectl; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "[https-test] ${command_name} 명령을 찾을 수 없습니다."
    exit 1
  fi
done

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[https-test] AWS 인증 정보를 확인해주세요."
  exit 1
fi

cluster_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw eks_cluster_name)"
aws_region="$(terraform -chdir="${TERRAFORM_DIR}" output -raw aws_region)"
route53_zone_id="$(terraform -chdir="${TERRAFORM_DIR}" output -raw route53_zone_id)"
acm_certificate_arn="$(terraform -chdir="${TERRAFORM_DIR}" output -raw acm_certificate_arn)"

TEMP_KUBECONFIG="$(mktemp /tmp/petflow-https-test-kubeconfig.XXXXXX)"
aws eks update-kubeconfig \
  --name "${cluster_name}" \
  --region "${aws_region}" \
  --kubeconfig "${TEMP_KUBECONFIG}" \
  --alias petflow-dev >/dev/null

get_ingress_dns_name() {
  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    get ingress "${INGRESS_NAME}" \
    --namespace "${NAMESPACE}" \
    --output jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
    2>/dev/null || true
}

get_alb_arn() {
  aws elbv2 describe-load-balancers \
    --names "${ALB_NAME}" \
    --region "${aws_region}" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || true
}

upsert_alias() {
  local alb_dns_name="$1"
  local alb_zone_id="$2"
  local change_batch
  local change_id

  change_batch="$(printf '{"Comment":"Temporary HTTPS end-to-end test","Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"A","AliasTarget":{"HostedZoneId":"%s","DNSName":"%s","EvaluateTargetHealth":true}}}]}' "${HOST_NAME}" "${alb_zone_id}" "${alb_dns_name}")"
  change_id="$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${route53_zone_id}" \
    --change-batch "${change_batch}" \
    --query 'ChangeInfo.Id' \
    --output text)"
  aws route53 wait resource-record-sets-changed --id "${change_id}"
}

delete_alias_if_present() {
  local alias_dns_name
  local alias_zone_id
  local change_batch
  local change_id

  alias_dns_name="$(aws route53 list-resource-record-sets \
    --hosted-zone-id "${route53_zone_id}" \
    --query "ResourceRecordSets[?Name=='${HOST_NAME}.' && Type=='A'] | [0].AliasTarget.DNSName" \
    --output text)"

  if [[ -z "${alias_dns_name}" || "${alias_dns_name}" == "None" ]]; then
    echo "[https-test] 삭제할 ${HOST_NAME} Alias가 없습니다."
    return
  fi
  if [[ "${alias_dns_name}" != *"${ALB_NAME}"* ]]; then
    echo "[https-test] ${HOST_NAME}이 테스트 ALB가 아닌 다른 대상으로 연결되어 있어 삭제하지 않습니다."
    echo "             현재 대상: ${alias_dns_name}"
    exit 1
  fi

  alias_zone_id="$(aws route53 list-resource-record-sets \
    --hosted-zone-id "${route53_zone_id}" \
    --query "ResourceRecordSets[?Name=='${HOST_NAME}.' && Type=='A'] | [0].AliasTarget.HostedZoneId" \
    --output text)"
  change_batch="$(printf '{"Comment":"Remove temporary HTTPS end-to-end test","Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":"%s","Type":"A","AliasTarget":{"HostedZoneId":"%s","DNSName":"%s","EvaluateTargetHealth":true}}}]}' "${HOST_NAME}" "${alias_zone_id}" "${alias_dns_name}")"
  change_id="$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${route53_zone_id}" \
    --change-batch "${change_batch}" \
    --query 'ChangeInfo.Id' \
    --output text)"
  aws route53 wait resource-record-sets-changed --id "${change_id}"
  echo "[https-test] ${HOST_NAME} Alias 삭제 완료"
}

deploy_test() {
  local alb_dns_name=""
  local alb_arn
  local alb_zone_id
  local target_group_arns
  local https_status=""
  local http_status=""

  if ! kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    wait --for=condition=Available deployment/aws-load-balancer-controller \
    --namespace kube-system --timeout=60s >/dev/null; then
    echo "[https-test] AWS Load Balancer Controller가 준비되지 않았습니다."
    exit 1
  fi

  sed "s|__ACM_CERTIFICATE_ARN__|${acm_certificate_arn}|g" "${MANIFEST_FILE}" \
    | kubectl --kubeconfig "${TEMP_KUBECONFIG}" apply -f -
  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    rollout status deployment/https-test --namespace "${NAMESPACE}" --timeout=5m

  for _ in $(seq 1 60); do
    alb_dns_name="$(get_ingress_dns_name)"
    if [[ -n "${alb_dns_name}" ]]; then
      break
    fi
    sleep 10
  done

  if [[ -z "${alb_dns_name}" ]]; then
    echo "[https-test] 10분 안에 Ingress ALB 주소가 생성되지 않았습니다."
    kubectl --kubeconfig "${TEMP_KUBECONFIG}" describe ingress "${INGRESS_NAME}" --namespace "${NAMESPACE}"
    exit 1
  fi

  alb_arn="$(get_alb_arn)"
  if [[ -z "${alb_arn}" || "${alb_arn}" == "None" ]]; then
    echo "[https-test] ALB ARN을 찾지 못했습니다: ${alb_dns_name}"
    exit 1
  fi

  aws elbv2 wait load-balancer-available \
    --load-balancer-arns "${alb_arn}" \
    --region "${aws_region}"
  alb_zone_id="$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "${alb_arn}" \
    --region "${aws_region}" \
    --query 'LoadBalancers[0].CanonicalHostedZoneId' \
    --output text)"

  target_group_arns="$(aws elbv2 describe-target-groups \
    --load-balancer-arn "${alb_arn}" \
    --region "${aws_region}" \
    --query 'TargetGroups[].TargetGroupArn' \
    --output text)"
  for target_group_arn in ${target_group_arns}; do
    aws elbv2 wait target-in-service \
      --target-group-arn "${target_group_arn}" \
      --region "${aws_region}"
  done

  upsert_alias "${alb_dns_name}" "${alb_zone_id}"

  if ! command -v curl >/dev/null 2>&1; then
    echo "[https-test] curl 명령을 찾을 수 없습니다."
    exit 1
  fi

  for _ in $(seq 1 30); do
    https_status="$(curl --connect-timeout 10 --max-time 30 --silent --output /dev/null --write-out '%{http_code}' "https://${HOST_NAME}" || true)"
    http_status="$(curl --connect-timeout 10 --max-time 30 --silent --output /dev/null --write-out '%{http_code}' "http://${HOST_NAME}" || true)"
    if [[ "${https_status}" == "200" && "${http_status}" =~ ^30[12]$ ]]; then
      break
    fi
    sleep 10
  done

  if [[ "${https_status}" != "200" || ! "${http_status}" =~ ^30[12]$ ]]; then
    echo "[https-test] 검증 실패: HTTPS=${https_status}, HTTP=${http_status}"
    exit 1
  fi

  echo "[https-test] 성공: https://${HOST_NAME} -> HTTP ${https_status}"
  echo "[https-test] 성공: http://${HOST_NAME} -> HTTP ${http_status} HTTPS Redirect"
  echo "[https-test] 비용 방지를 위해 검증 후 반드시 '$0 cleanup'을 실행하세요."
}

show_status() {
  kubectl --kubeconfig "${TEMP_KUBECONFIG}" get deployment aws-load-balancer-controller --namespace kube-system
  kubectl --kubeconfig "${TEMP_KUBECONFIG}" get pod,service,ingress --namespace "${NAMESPACE}" 2>/dev/null || true
  aws route53 list-resource-record-sets \
    --hosted-zone-id "${route53_zone_id}" \
    --query "ResourceRecordSets[?Name=='${HOST_NAME}.']" \
    --output json
}

cleanup_test() {
  local alb_arn

  alb_arn="$(get_alb_arn)"
  echo "[https-test] Route53 Alias 정리 중..."
  delete_alias_if_present
  echo "[https-test] Namespace/Ingress 삭제 중... ALB finalizer 처리에 수 분 걸릴 수 있습니다."
  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    delete namespace "${NAMESPACE}" --ignore-not-found --wait=true --timeout=10m

  if [[ -n "${alb_arn}" && "${alb_arn}" != "None" ]]; then
    echo "[https-test] AWS ALB 완전 삭제 확인 중..."
    aws elbv2 wait load-balancers-deleted \
      --load-balancer-arns "${alb_arn}" \
      --region "${aws_region}"
  fi
  echo "[https-test] 임시 nginx, Ingress, ALB, Route53 Alias 정리 완료"
}

case "${ACTION}" in
  deploy) deploy_test ;;
  status) show_status ;;
  cleanup) cleanup_test ;;
esac
