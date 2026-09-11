#!/usr/bin/env bash
# DEV Terraform Destroy 전에 Kubernetes가 생성한 외부 AWS 연계 리소스를 정리한다.
# EKS Private API에 접근 가능한 Tailscale 클라이언트에서 실행해야 한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"
EXPECTED_AWS_ACCOUNT_ID="297165773875"
TEMP_KUBECONFIG=""
EKS_DESCRIBE_ERROR=""
KUBECTL=()

cleanup_temp_files() {
  if [[ -n "${TEMP_KUBECONFIG}" && -f "${TEMP_KUBECONFIG}" ]]; then
    rm -f "${TEMP_KUBECONFIG}"
  fi

  if [[ -n "${EKS_DESCRIBE_ERROR}" && -f "${EKS_DESCRIBE_ERROR}" ]]; then
    rm -f "${EKS_DESCRIBE_ERROR}"
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "[cleanup-k8s] ${command_name} 명령이 필요합니다." >&2
    exit 1
  fi
}

verify_no_aws_load_balancers() {
  local vpc_id="$1"
  local aws_region="$2"
  local attempt
  local v2_count
  local classic_count

  for attempt in {1..60}; do
    v2_count="$(aws elbv2 describe-load-balancers --region "${aws_region}" --query "length(LoadBalancers[?VpcId=='${vpc_id}'])" --output text)"
    classic_count="$(aws elb describe-load-balancers --region "${aws_region}" --query "length(LoadBalancerDescriptions[?VPCId=='${vpc_id}'])" --output text)"

    if ((v2_count == 0 && classic_count == 0)); then
      echo "[cleanup-k8s] AWS 외부 Load Balancer 정리 확인 완료"
      return
    fi

    if ((attempt == 60)); then
      echo "[cleanup-k8s] AWS Load Balancer 삭제 대기 시간이 초과됐습니다." >&2
      echo "[cleanup-k8s] ALB/NLB: ${v2_count}, Classic ELB: ${classic_count}" >&2
      exit 1
    fi

    echo "[cleanup-k8s] AWS Load Balancer 삭제 대기 중... ALB/NLB=${v2_count}, Classic ELB=${classic_count}"
    sleep 10
  done
}

trap cleanup_temp_files EXIT

echo "======================================"
echo " Kubernetes Cleanup"
echo "======================================"

require_command aws
require_command terraform
require_command kubectl

if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "[cleanup-k8s] Terraform 디렉터리를 찾을 수 없습니다: ${TERRAFORM_DIR}" >&2
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[cleanup-k8s] AWS 인증 정보를 확인해주세요." >&2
  exit 1
fi

caller_account="$(aws sts get-caller-identity --query Account --output text)"
if [[ "${caller_account}" != "${EXPECTED_AWS_ACCOUNT_ID}" ]]; then
  echo "[cleanup-k8s] 잘못된 AWS Account입니다: ${caller_account}" >&2
  echo "[cleanup-k8s] 예상 Account: ${EXPECTED_AWS_ACCOUNT_ID}" >&2
  exit 1
fi

cd "${TERRAFORM_DIR}"

cluster_name="$(terraform output -raw eks_cluster_name 2>/dev/null || true)"
aws_region="$(terraform output -raw aws_region 2>/dev/null || true)"
vpc_id="$(terraform output -raw vpc_id 2>/dev/null || true)"

if [[ -z "${cluster_name}" || -z "${aws_region}" ]]; then
  echo "[cleanup-k8s] 활성 EKS output이 없어 정리할 Kubernetes 리소스가 없습니다."
  exit 0
fi

EKS_DESCRIBE_ERROR="$(mktemp /tmp/petflow-eks-describe.XXXXXX)"
if ! aws eks describe-cluster --name "${cluster_name}" --region "${aws_region}" >/dev/null 2>"${EKS_DESCRIBE_ERROR}"; then
  if grep -q "ResourceNotFoundException" "${EKS_DESCRIBE_ERROR}"; then
    echo "[cleanup-k8s] EKS Cluster가 이미 없어 정리할 Kubernetes 리소스가 없습니다."
    exit 0
  fi

  echo "[cleanup-k8s] EKS Cluster 상태를 확인하지 못했습니다." >&2
  cat "${EKS_DESCRIBE_ERROR}" >&2
  exit 1
fi

echo "[1/4] Kubernetes API 연결 확인"

TEMP_KUBECONFIG="$(mktemp /tmp/petflow-cleanup-kubeconfig.XXXXXX)"
aws eks update-kubeconfig --name "${cluster_name}" --region "${aws_region}" --kubeconfig "${TEMP_KUBECONFIG}" >/dev/null
KUBECTL=(kubectl --kubeconfig "${TEMP_KUBECONFIG}")

if ! "${KUBECTL[@]}" get --raw=/readyz --request-timeout=10s >/dev/null 2>&1; then
  echo "[cleanup-k8s] Kubernetes API에 접근할 수 없습니다." >&2
  echo "[cleanup-k8s] EKS Private Endpoint와 Tailscale 연결 상태를 확인해주세요." >&2
  exit 1
fi

echo "[cleanup-k8s] Kubernetes API 연결 확인 완료"

echo "[2/4] Argo CD 동기화 중지"
if "${KUBECTL[@]}" get statefulset argocd-application-controller --namespace argocd >/dev/null 2>&1; then
  "${KUBECTL[@]}" scale statefulset argocd-application-controller --namespace argocd --replicas=0 --timeout=60s
  echo "[cleanup-k8s] Argo CD Application Controller 중지 완료"
else
  echo "[cleanup-k8s] 실행 중인 Argo CD Application Controller가 없습니다."
fi

echo "[3/4] Ingress 확인 및 삭제"
ingress_refs="$("${KUBECTL[@]}" get ingresses --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}')"

if [[ -z "${ingress_refs}" ]]; then
  echo "[cleanup-k8s] 삭제할 Ingress가 없습니다."
else
  while IFS= read -r ingress_ref; do
    [[ -z "${ingress_ref}" ]] && continue
    namespace="${ingress_ref%%/*}"
    ingress_name="${ingress_ref#*/}"
    echo "[cleanup-k8s] Ingress 삭제: ${namespace}/${ingress_name}"
    "${KUBECTL[@]}" delete ingress "${ingress_name}" --namespace "${namespace}" --wait=true --timeout=10m
  done <<< "${ingress_refs}"
fi

echo "[4/4] LoadBalancer Service 확인 및 삭제"
load_balancer_service_refs="$("${KUBECTL[@]}" get services --all-namespaces -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}')"

if [[ -z "${load_balancer_service_refs}" ]]; then
  echo "[cleanup-k8s] 삭제할 LoadBalancer Service가 없습니다."
else
  while IFS= read -r service_ref; do
    [[ -z "${service_ref}" ]] && continue
    namespace="${service_ref%%/*}"
    service_name="${service_ref#*/}"
    echo "[cleanup-k8s] LoadBalancer Service 삭제: ${namespace}/${service_name}"
    "${KUBECTL[@]}" delete service "${service_name}" --namespace "${namespace}" --wait=true --timeout=10m
  done <<< "${load_balancer_service_refs}"
fi

if [[ -n "${vpc_id}" ]]; then
  verify_no_aws_load_balancers "${vpc_id}" "${aws_region}"
fi

echo "======================================"
echo " Kubernetes Cleanup Completed"
echo "======================================"
