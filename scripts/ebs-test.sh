#!/usr/bin/env bash
# EBS CSI Driver -> gp3 StorageClass -> PVC -> Pod 마운트 경로를 검증한다.
#
# 사용:
#   AWS_PROFILE=goljugaenyang ./scripts/ebs-test.sh deploy
#   AWS_PROFILE=goljugaenyang ./scripts/ebs-test.sh status
#   AWS_PROFILE=goljugaenyang ./scripts/ebs-test.sh cleanup

set -euo pipefail

ACTION="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform/environments/dev"
MANIFEST_FILE="${ROOT_DIR}/kubernetes/tests/ebs-test.yaml"
NAMESPACE="ebs-test"
POD_NAME="ebs-test"
PVC_NAME="ebs-test"
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
    echo "[ebs-test] ${command_name} 명령을 찾을 수 없습니다."
    exit 1
  fi
done

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "[ebs-test] AWS 인증 정보를 확인해주세요."
  exit 1
fi

cluster_name="$(terraform -chdir="${TERRAFORM_DIR}" output -raw eks_cluster_name)"
aws_region="$(terraform -chdir="${TERRAFORM_DIR}" output -raw aws_region)"

TEMP_KUBECONFIG="$(mktemp /tmp/petflow-ebs-test-kubeconfig.XXXXXX)"
aws eks update-kubeconfig \
  --name "${cluster_name}" \
  --region "${aws_region}" \
  --kubeconfig "${TEMP_KUBECONFIG}" \
  --alias petflow-dev >/dev/null

deploy_test() {
  if ! kubectl --kubeconfig "${TEMP_KUBECONFIG}" get storageclass gp3 >/dev/null 2>&1; then
    echo "[ebs-test] gp3 StorageClass가 없습니다."
    echo "[ebs-test] GitOps의 platform/05-storageclass 동기화 상태를 확인해주세요."
    exit 1
  fi

  if ! kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    get deployment ebs-csi-controller \
    --namespace kube-system >/dev/null 2>&1; then
    echo "[ebs-test] EBS CSI Controller를 찾을 수 없습니다."
    exit 1
  fi

  kubectl --kubeconfig "${TEMP_KUBECONFIG}" apply -f "${MANIFEST_FILE}"

  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    wait \
    --for=condition=Ready \
    "pod/${POD_NAME}" \
    --namespace "${NAMESPACE}" \
    --timeout=5m

  pvc_status="$(
    kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
      get pvc "${PVC_NAME}" \
      --namespace "${NAMESPACE}" \
      --output jsonpath='{.status.phase}'
  )"

  if [[ "${pvc_status}" != "Bound" ]]; then
    echo "[ebs-test] PVC가 Bound 상태가 아닙니다: ${pvc_status}"
    exit 1
  fi

  test_result="$(
    kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
      exec "${POD_NAME}" \
      --namespace "${NAMESPACE}" \
      -- cat /data/result.txt
  )"

  if [[ "${test_result}" != "petflow EBS CSI test" ]]; then
    echo "[ebs-test] 볼륨 읽기/쓰기 검증에 실패했습니다."
    exit 1
  fi

  echo "[ebs-test] 성공: gp3 PVC Bound"
  echo "[ebs-test] 성공: EBS 볼륨 마운트 및 파일 읽기/쓰기 확인"
  echo "[ebs-test] 검증 후 반드시 '$0 cleanup'을 실행하세요."
}

show_status() {
  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    get storageclass gp3

  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    get pod,pvc \
    --namespace "${NAMESPACE}" \
    --output wide 2>/dev/null || true

  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    get pv 2>/dev/null || true
}

cleanup_test() {
  echo "[ebs-test] 테스트 Namespace와 PVC를 삭제합니다."

  kubectl --kubeconfig "${TEMP_KUBECONFIG}" \
    delete namespace "${NAMESPACE}" \
    --ignore-not-found \
    --wait=true \
    --timeout=10m

  echo "[ebs-test] 테스트 Pod, PVC 및 연결된 EBS 볼륨 정리 요청 완료"
}

case "${ACTION}" in
  deploy) deploy_test ;;
  status) show_status ;;
  cleanup) cleanup_test ;;
esac
