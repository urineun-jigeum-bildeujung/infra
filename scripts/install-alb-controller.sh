#!/usr/bin/env bash
# Terraform이 준비한 Pod Identity를 사용해 AWS Load Balancer Controller를 설치/업그레이드한다.
#
# 사용:
#   AWS_PROFILE=ujibil2 ./scripts/install-alb-controller.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform/environments/dev"
VALUES_FILE="${ROOT_DIR}/kubernetes/alb-controller/values-dev.yaml"
CHART_VERSION="${ALB_CONTROLLER_CHART_VERSION:-3.5.0}"
RELEASE_NAME="aws-load-balancer-controller"
NAMESPACE="kube-system"
SERVICE_ACCOUNT="aws-load-balancer-controller"
TEMP_KUBECONFIG=""
HELM_CONFLICT_ARGS=()

cleanup() {
  if [[ -n "${TEMP_KUBECONFIG}" && -f "${TEMP_KUBECONFIG}" ]]; then
    rm -f "${TEMP_KUBECONFIG}"
  fi
}
trap cleanup EXIT

for command_name in aws terraform kubectl helm; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "[alb-controller] ${command_name} 명령을 찾을 수 없습니다."
    exit 1
  fi
done

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[alb-controller] AWS 인증 정보를 확인해주세요."
  exit 1
fi

cluster_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw eks_cluster_name)"
aws_region="$(terraform -chdir="${TERRAFORM_DIR}" output -raw aws_region)"
vpc_id="$(terraform -chdir="${TERRAFORM_DIR}" output -raw vpc_id)"

association_count="$(
  aws eks list-pod-identity-associations \
    --cluster-name "${cluster_name}" \
    --region "${aws_region}" \
    --query "length(associations[?namespace=='${NAMESPACE}' && serviceAccount=='${SERVICE_ACCOUNT}'])" \
    --output text
)"

if [[ "${association_count}" != "1" ]]; then
  echo "[alb-controller] ${NAMESPACE}/${SERVICE_ACCOUNT} Pod Identity Association이 정확히 1개여야 합니다."
  echo "                 먼저 Terraform platform_iam을 apply해주세요. 현재 개수: ${association_count}"
  exit 1
fi

TEMP_KUBECONFIG="$(mktemp /tmp/petflow-alb-controller-kubeconfig.XXXXXX)"
aws eks update-kubeconfig \
  --name "${cluster_name}" \
  --region "${aws_region}" \
  --kubeconfig "${TEMP_KUBECONFIG}" \
  --alias petflow-dev >/dev/null

helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
helm repo update eks >/dev/null

# Helm 4의 server-side apply는 kubectl scale 등으로 필드 소유자가 바뀌면 충돌할 수 있다.
# 지원되는 버전에서는 Git에 선언한 Helm 값을 기준으로 소유권을 되찾는다.
if helm upgrade --help | grep -q -- "--force-conflicts"; then
  HELM_CONFLICT_ARGS+=(--force-conflicts)
fi

# helm upgrade는 CRD를 갱신하지 않으므로 고정된 Chart 버전의 CRD를 먼저 적용한다.
helm show crds eks/aws-load-balancer-controller --version "${CHART_VERSION}" \
  | kubectl --kubeconfig "${TEMP_KUBECONFIG}" apply -f -

helm upgrade --install "${RELEASE_NAME}" eks/aws-load-balancer-controller \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --values "${VALUES_FILE}" \
  --set "clusterName=${cluster_name}" \
  --set "region=${aws_region}" \
  --set "vpcId=${vpc_id}" \
  --wait \
  --timeout 10m \
  "${HELM_CONFLICT_ARGS[@]}" \
  --kubeconfig "${TEMP_KUBECONFIG}"

kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
  rollout status deployment/aws-load-balancer-controller \
  --namespace "${NAMESPACE}" \
  --timeout=5m

kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
  get deployment,pods \
  --namespace "${NAMESPACE}" \
  --selector app.kubernetes.io/name=aws-load-balancer-controller
