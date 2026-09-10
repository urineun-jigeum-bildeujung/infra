#!/usr/bin/env bash
# Dev 환경 Terraform 리소스 삭제 (프로젝트 루트에서 실행, --auto-approve)
#
# ⚠️ 확인 프롬프트 없이 즉시 destroy 되므로 매우 신중히 실행할 것.
#    실행 전 반드시 어느 계정 / 어느 리전인지 확인한다.
#
# 이 스크립트는 오직 terraform/environments/dev 만 대상으로 한다.
# Bootstrap 스택, Route53 Hosted Zone, DEV 애플리케이션 S3 모듈은 삭제 대상에서 제외한다.
# → DNS 위임과 tfstate / static / product-images / uploads / db-backups Bucket 은 그대로 유지된다.
# Terraform의 -target은 평상시 apply가 아닌, 영구 데이터 스토리지를 제외한
# DEV 인프라 정리 용도로만 제한해서 사용한다.
#
# 사용:
#   ./tdestroy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"

TEMP_KUBECONFIG=""

cleanup_temp_kubeconfig() {
  if [[ -n "${TEMP_KUBECONFIG}" && -f "${TEMP_KUBECONFIG}" ]]; then
    rm -f "${TEMP_KUBECONFIG}"
  fi
}

cleanup_kubernetes_load_balancers() {
  local cluster_name
  local aws_region
  local load_balancer_services
  local service_ref
  local namespace
  local service_name

  cluster_name="$(terraform output -raw eks_cluster_name 2>/dev/null || true)"
  aws_region="$(terraform output -raw aws_region 2>/dev/null || true)"

  if [[ -z "${cluster_name}" || -z "${aws_region}" ]]; then
    echo "[tdestroy] 활성 EKS output이 없어 Kubernetes LoadBalancer 사전 정리를 건너뜁니다."
    return
  fi

  if ! aws eks describe-cluster --name "${cluster_name}" --region "${aws_region}" >/dev/null 2>&1; then
    echo "[tdestroy] EKS Cluster가 없어 Kubernetes LoadBalancer 사전 정리를 건너뜁니다."
    return
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "[tdestroy] kubectl이 필요합니다. EKS의 LoadBalancer Service를 먼저 정리할 수 없습니다."
    exit 1
  fi

  TEMP_KUBECONFIG="$(mktemp /tmp/petflow-destroy-kubeconfig.XXXXXX)"
  aws eks update-kubeconfig --name "${cluster_name}" --region "${aws_region}" --kubeconfig "${TEMP_KUBECONFIG}" >/dev/null

  load_balancer_services="$(kubectl --kubeconfig "${TEMP_KUBECONFIG}" get services --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}')"

  if [[ -z "${load_balancer_services}" ]]; then
    echo "[tdestroy] 삭제할 Kubernetes LoadBalancer Service가 없습니다."
    return
  fi

  # Argo CD가 삭제한 Service를 다시 생성하지 못하도록 teardown 동안 동기화를 중지한다.
  kubectl --kubeconfig "${TEMP_KUBECONFIG}" scale statefulset argocd-application-controller \
    --namespace argocd --replicas=0 --timeout=60s >/dev/null 2>&1 || true

  while IFS= read -r service_ref; do
    namespace="${service_ref%%/*}"
    service_name="${service_ref#*/}"
    echo "[tdestroy] Kubernetes LoadBalancer Service 삭제: ${namespace}/${service_name}"
    kubectl --kubeconfig "${TEMP_KUBECONFIG}" delete service "${service_name}" \
      --namespace "${namespace}" --wait=true --timeout=5m
  done <<< "${load_balancer_services}"
}

trap cleanup_temp_kubeconfig EXIT

cd "${TERRAFORM_DIR}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[tdestroy] AWS 인증 정보를 확인해주세요."
  exit 1
fi

CALLER_INFO="$(aws sts get-caller-identity --output text --query 'Account')"
echo "[tdestroy] 대상 AWS Account: ${CALLER_INFO}"
echo "[tdestroy] 대상 스택       : terraform/environments/dev"
echo "[tdestroy] 보존 대상        : Route53 Hosted Zone, S3 (tfstate/static/product-images/uploads/db-backups)"
echo "[tdestroy] 3초 후 destroy 를 시작합니다. 취소하려면 지금 Ctrl+C 를 누르세요."
sleep 3
cleanup_kubernetes_load_balancers

terraform destroy --auto-approve \
  -target=module.workload_iam \
  -target=module.platform_iam \
  -target=module.eks \
  -target=module.ecr \
  -target=module.iam \
  -target=module.network

echo "[tdestroy] Route53 Hosted Zone과 애플리케이션 S3 Bucket 4개는 삭제 대상에서 제외했습니다."
