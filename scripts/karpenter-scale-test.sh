#!/usr/bin/env bash
# Pending Pod를 생성하여 Karpenter Worker Node 프로비저닝을 검증한다.
#
# 사용:
#   AWS_PROFILE=goljugaenyang ./scripts/karpenter-scale-test.sh deploy
#   AWS_PROFILE=goljugaenyang ./scripts/karpenter-scale-test.sh status
#   AWS_PROFILE=goljugaenyang ./scripts/karpenter-scale-test.sh cleanup

set -euo pipefail

ACTION="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform/environments/dev"
MANIFEST_FILE="${ROOT_DIR}/kubernetes/tests/karpenter-scale-test.yaml"
NAMESPACE="karpenter-scale-test"
DEPLOYMENT_NAME="karpenter-scale-test"
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
    echo "[karpenter-test] ${command_name} 명령을 찾을 수 없습니다."
    exit 1
  fi
done

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[karpenter-test] AWS 인증 정보를 확인해주세요."
  exit 1
fi

cluster_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw eks_cluster_name)"
aws_region="$(terraform -chdir="${TERRAFORM_DIR}" output -raw aws_region)"

TEMP_KUBECONFIG="$(mktemp /tmp/petflow-karpenter-test-kubeconfig.XXXXXX)"
aws eks update-kubeconfig \
  --name "${cluster_name}" \
  --region "${aws_region}" \
  --kubeconfig "${TEMP_KUBECONFIG}" \
  --alias petflow-dev >/dev/null

check_karpenter() {
  if ! kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    get crd nodepools.karpenter.sh >/dev/null 2>&1; then
    echo "[karpenter-test] Karpenter NodePool CRD가 없습니다."
    echo "[karpenter-test] GitOps의 Karpenter 설치 상태를 확인해주세요."
    exit 1
  fi

  if ! kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1; then
    echo "[karpenter-test] EC2NodeClass CRD가 없습니다."
    exit 1
  fi

  nodepool_count="$(
    kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
      get nodepool \
      --no-headers 2>/dev/null |
      wc -l
  )"

  if [[ "${nodepool_count}" -eq 0 ]]; then
    echo "[karpenter-test] 사용할 수 있는 NodePool이 없습니다."
    exit 1
  fi
}

deploy_test() {
  check_karpenter

  before_nodes="$(
    kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
      get nodes \
      --no-headers |
      wc -l
  )"

  echo "[karpenter-test] 테스트 전 노드 수: ${before_nodes}"

  kubectl --kubeconfig "${TEMP_KUBECONFIG}" apply -f "${MANIFEST_FILE}"

  echo "[karpenter-test] Karpenter 노드 프로비저닝을 기다립니다."

  if ! kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    rollout status \
    "deployment/${DEPLOYMENT_NAME}" \
    --namespace "${NAMESPACE}" \
    --timeout=10m; then
    echo "[karpenter-test] 제한 시간 안에 테스트 Pod가 준비되지 않았습니다."

    kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
      get pods \
      --namespace "${NAMESPACE}" \
      --output wide || true

    kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
      get events \
      --namespace "${NAMESPACE}" \
      --sort-by='.lastTimestamp' || true

    exit 1
  fi

  after_nodes="$(
    kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
      get nodes \
      --no-headers |
      wc -l
  )"

  echo "[karpenter-test] 테스트 후 노드 수: ${after_nodes}"

  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    get nodes \
    --label-columns karpenter.sh/nodepool,node.kubernetes.io/instance-type

  if [[ "${after_nodes}" -le "${before_nodes}" ]]; then
    echo "[karpenter-test] Pod는 실행됐지만 신규 노드 증설은 확인되지 않았습니다."
    echo "[karpenter-test] 기존 노드의 여유 자원에 배치됐을 수 있습니다."
    exit 1
  fi

  echo "[karpenter-test] 성공: Karpenter 신규 노드 프로비저닝 확인"
  echo "[karpenter-test] 검증 후 반드시 '$0 cleanup'을 실행하세요."
}

show_status() {
  check_karpenter

  kubectl --kubeconfig "${TEMP_KUBECONFIG}" get nodepool
  kubectl --kubeconfig "${TEMP_KUBECONFIG}" get ec2nodeclass
  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    get nodes \
    --label-columns karpenter.sh/nodepool,node.kubernetes.io/instance-type

  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    get pods \
    --namespace "${NAMESPACE}" \
    --output wide 2>/dev/null || true
}

cleanup_test() {
  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    delete namespace "${NAMESPACE}" \
    --ignore-not-found \
    --wait=true \
    --timeout=10m

  echo "[karpenter-test] 테스트 워크로드 삭제 완료"
  echo "[karpenter-test] Karpenter의 consolidation 정책에 따라 노드 삭제에는 시간이 걸릴 수 있습니다."
}

case "${ACTION}" in
  deploy) deploy_test ;;
  status) show_status ;;
  cleanup) cleanup_test ;;
esac
