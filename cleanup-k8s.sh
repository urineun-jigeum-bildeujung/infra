#!/usr/bin/env bash
# DEV Terraform Destroy 전에 Kubernetes가 생성한 외부 AWS 연계 리소스를 정리한다.
# EKS Private API에 접근 가능한 Tailscale 클라이언트에서 실행해야 한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform/environments/dev"
EXPECTED_AWS_ACCOUNT_ID="297165773875"
EXPECTED_AWS_REGION="ap-northeast-2"
EXPECTED_EKS_CLUSTER_NAME="petflow-eks"
PERSISTENT_NAMESPACES=(redis kafka)
TEMP_KUBECONFIG=""
EKS_DESCRIBE_ERROR=""
KUBECTL=()
TRACKED_PVS=()
TRACKED_EBS_VOLUMES=()

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

array_contains() {
  local expected="$1"
  local item

  shift
  for item in "$@"; do
    if [[ "${item}" == "${expected}" ]]; then
      return 0
    fi
  done

  return 1
}

namespace_exists() {
  local namespace="$1"
  local namespace_resource

  if ! namespace_resource="$("${KUBECTL[@]}" get namespace "${namespace}" \
    --ignore-not-found -o name)"; then
    echo "[cleanup-k8s] Namespace 존재 여부를 확인하지 못했습니다: ${namespace}" >&2
    exit 1
  fi

  [[ -n "${namespace_resource}" ]]
}

track_persistent_storage() {
  local namespace
  local pvc_rows
  local pvc_name
  local pv_name
  local pv_details
  local csi_driver
  local volume_handle
  local reclaim_policy

  for namespace in "${PERSISTENT_NAMESPACES[@]}"; do
    if ! namespace_exists "${namespace}"; then
      echo "[cleanup-k8s] ${namespace} Namespace가 없어 PVC 추적을 건너뜁니다."
      continue
    fi

    pvc_rows="$("${KUBECTL[@]}" get pvc --namespace "${namespace}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.volumeName}{"\n"}{end}')"

    if [[ -z "${pvc_rows}" ]]; then
      echo "[cleanup-k8s] ${namespace} Namespace에 추적할 PVC가 없습니다."
      continue
    fi

    while IFS=$'\t' read -r pvc_name pv_name; do
      [[ -z "${pvc_name}" ]] && continue
      echo "[cleanup-k8s] PVC 추적: ${namespace}/${pvc_name}"

      if [[ -z "${pv_name}" ]]; then
        echo "[cleanup-k8s] PVC가 아직 PV에 Bound되지 않았습니다: ${namespace}/${pvc_name}"
        continue
      fi

      if array_contains "${pv_name}" "${TRACKED_PVS[@]}"; then
        continue
      fi

      if ! pv_details="$("${KUBECTL[@]}" get pv "${pv_name}" \
        -o jsonpath='{.spec.csi.driver}{"\t"}{.spec.csi.volumeHandle}{"\t"}{.spec.persistentVolumeReclaimPolicy}{"\n"}')"; then
        echo "[cleanup-k8s] PVC가 참조하는 PV를 조회하지 못했습니다: ${pv_name}" >&2
        return 1
      fi

      IFS=$'\t' read -r csi_driver volume_handle reclaim_policy <<< "${pv_details}"
      TRACKED_PVS+=("${pv_name}")
      echo "[cleanup-k8s] PV 추적: ${pv_name}, reclaimPolicy=${reclaim_policy:-unknown}"

      if [[ "${csi_driver}" != "ebs.csi.aws.com" ]]; then
        echo "[cleanup-k8s] EBS CSI PV가 아니므로 AWS Volume 추적은 생략합니다: ${pv_name}"
        continue
      fi

      if [[ ! "${volume_handle}" =~ ^vol-[0-9a-f]+$ ]]; then
        echo "[cleanup-k8s] EBS Volume ID 형식이 올바르지 않습니다: ${volume_handle}" >&2
        return 1
      fi

      if ! array_contains "${volume_handle}" "${TRACKED_EBS_VOLUMES[@]}"; then
        TRACKED_EBS_VOLUMES+=("${volume_handle}")
        echo "[cleanup-k8s] EBS Volume 추적: ${volume_handle} (${namespace}/${pvc_name})"
      fi
    done <<< "${pvc_rows}"
  done
}

delete_strimzi_resources() {
  local crd_name
  local resource_name
  local crd_resource

  if ! namespace_exists kafka; then
    echo "[cleanup-k8s] kafka Namespace가 없어 Strimzi Resource 정리를 건너뜁니다."
    return
  fi

  while IFS=$'\t' read -r crd_name resource_name; do
    if ! crd_resource="$("${KUBECTL[@]}" get crd "${crd_name}" \
      --ignore-not-found -o name)"; then
      echo "[cleanup-k8s] Strimzi CRD 존재 여부를 확인하지 못했습니다: ${crd_name}" >&2
      return 1
    fi

    if [[ -n "${crd_resource}" ]]; then
      echo "[cleanup-k8s] Strimzi Resource 삭제: ${resource_name}"
      "${KUBECTL[@]}" delete "${resource_name}" --all --namespace kafka \
        --ignore-not-found --wait=true --timeout=10m
    else
      echo "[cleanup-k8s] ${crd_name} CRD가 없어 건너뜁니다."
    fi
  done <<'STRIMZI_RESOURCES'
kafkatopics.kafka.strimzi.io	kafkatopic
kafkas.kafka.strimzi.io	kafka
kafkanodepools.kafka.strimzi.io	kafkanodepool
STRIMZI_RESOURCES
}

delete_persistent_workloads() {
  local namespace

  delete_strimzi_resources

  for namespace in "${PERSISTENT_NAMESPACES[@]}"; do
    if ! namespace_exists "${namespace}"; then
      echo "[cleanup-k8s] ${namespace} Namespace가 없어 Workload 정리를 건너뜁니다."
      continue
    fi

    echo "[cleanup-k8s] ${namespace} Namespace Workload/Service 삭제"
    "${KUBECTL[@]}" delete all --all --namespace "${namespace}" \
      --ignore-not-found --wait=true --timeout=10m
  done
}

delete_persistent_volume_claims() {
  local namespace
  local pvc_names
  local remaining_pvcs

  for namespace in "${PERSISTENT_NAMESPACES[@]}"; do
    if ! namespace_exists "${namespace}"; then
      echo "[cleanup-k8s] ${namespace} Namespace가 없어 PVC 정리를 건너뜁니다."
      continue
    fi

    pvc_names="$("${KUBECTL[@]}" get pvc --namespace "${namespace}" -o name)"
    if [[ -z "${pvc_names}" ]]; then
      echo "[cleanup-k8s] ${namespace} Namespace에 삭제할 PVC가 없습니다."
      continue
    fi

    echo "[cleanup-k8s] ${namespace} Namespace PVC 삭제"
    "${KUBECTL[@]}" delete pvc --all --namespace "${namespace}" \
      --ignore-not-found --wait=true --timeout=10m

    remaining_pvcs="$("${KUBECTL[@]}" get pvc --namespace "${namespace}" -o name)"
    if [[ -n "${remaining_pvcs}" ]]; then
      echo "[cleanup-k8s] ${namespace} Namespace에 PVC가 남아 있습니다." >&2
      echo "${remaining_pvcs}" >&2
      return 1
    fi
  done
}

verify_persistent_storage_cleanup() {
  local pv_name
  local volume_id
  local attempt
  local phase
  local volume_state
  local deleted
  local pv_resource

  for pv_name in "${TRACKED_PVS[@]}"; do
    deleted=false

    for attempt in {1..60}; do
      if ! pv_resource="$("${KUBECTL[@]}" get pv "${pv_name}" \
        --ignore-not-found -o name)"; then
        echo "[cleanup-k8s] PV 상태를 확인하지 못했습니다: ${pv_name}" >&2
        return 1
      fi

      if [[ -z "${pv_resource}" ]]; then
        echo "[cleanup-k8s] PV 삭제 확인: ${pv_name}"
        deleted=true
        break
      fi

      phase="$("${KUBECTL[@]}" get pv "${pv_name}" -o jsonpath='{.status.phase}')"
      echo "[cleanup-k8s] PV 삭제 대기 중: ${pv_name}, phase=${phase:-unknown}"
      sleep 5
    done

    if [[ "${deleted}" != true ]]; then
      echo "[cleanup-k8s] PV 삭제 대기 시간이 초과됐습니다: ${pv_name}" >&2
      echo "[cleanup-k8s] reclaimPolicy와 PV finalizer를 확인해주세요." >&2
      return 1
    fi
  done

  for volume_id in "${TRACKED_EBS_VOLUMES[@]}"; do
    deleted=false

    for attempt in {1..60}; do
      if volume_state="$(aws ec2 describe-volumes --region "${aws_region}" \
        --volume-ids "${volume_id}" --query 'Volumes[0].State' --output text 2>&1)"; then
        echo "[cleanup-k8s] EBS Volume 삭제 대기 중: ${volume_id}, state=${volume_state}"
      elif [[ "${volume_state}" == *"InvalidVolume.NotFound"* ]]; then
        echo "[cleanup-k8s] EBS Volume 삭제 확인: ${volume_id}"
        deleted=true
        break
      else
        echo "[cleanup-k8s] EBS Volume 상태를 확인하지 못했습니다: ${volume_id}" >&2
        echo "${volume_state}" >&2
        return 1
      fi

      sleep 5
    done

    if [[ "${deleted}" != true ]]; then
      echo "[cleanup-k8s] Kubernetes PVC에서 생성된 EBS Volume이 남아 있습니다: ${volume_id}" >&2
      aws ec2 describe-volumes --region "${aws_region}" --volume-ids "${volume_id}" \
        --query 'Volumes[0].{State:State,Attachments:Attachments,Tags:Tags}' --output json >&2 || true
      echo "[cleanup-k8s] 자동 강제 삭제하지 않습니다. 소유 Tag와 Attachment를 확인해주세요." >&2
      return 1
    fi
  done

  echo "[cleanup-k8s] 추적한 PVC/PV/EBS 정리 확인 완료"
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

if [[ -z "${cluster_name}" ]]; then
  echo "[cleanup-k8s] 활성 EKS output이 없어 정리할 Kubernetes 리소스가 없습니다."
  exit 0
fi

if [[ -z "${aws_region}" || -z "${vpc_id}" ]]; then
  echo "[cleanup-k8s] 활성 EKS의 Region 또는 VPC output을 확인하지 못했습니다." >&2
  exit 1
fi

if [[ "${cluster_name}" != "${EXPECTED_EKS_CLUSTER_NAME}" ]]; then
  echo "[cleanup-k8s] 잘못된 EKS Cluster입니다: ${cluster_name}" >&2
  echo "[cleanup-k8s] 예상 Cluster: ${EXPECTED_EKS_CLUSTER_NAME}" >&2
  exit 1
fi

if [[ "${aws_region}" != "${EXPECTED_AWS_REGION}" ]]; then
  echo "[cleanup-k8s] 잘못된 AWS Region입니다: ${aws_region}" >&2
  echo "[cleanup-k8s] 예상 Region: ${EXPECTED_AWS_REGION}" >&2
  exit 1
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

echo "[1/7] Kubernetes API 연결 확인"

TEMP_KUBECONFIG="$(mktemp /tmp/petflow-cleanup-kubeconfig.XXXXXX)"
aws eks update-kubeconfig --name "${cluster_name}" --region "${aws_region}" --kubeconfig "${TEMP_KUBECONFIG}" >/dev/null
KUBECTL=(kubectl --kubeconfig "${TEMP_KUBECONFIG}")

if ! "${KUBECTL[@]}" get --raw=/readyz --request-timeout=10s >/dev/null 2>&1; then
  echo "[cleanup-k8s] Kubernetes API에 접근할 수 없습니다." >&2
  echo "[cleanup-k8s] EKS Private Endpoint와 Tailscale 연결 상태를 확인해주세요." >&2
  exit 1
fi

echo "[cleanup-k8s] Kubernetes API 연결 확인 완료"

echo "[2/7] Argo CD 동기화 중지"
if "${KUBECTL[@]}" get statefulset argocd-application-controller --namespace argocd >/dev/null 2>&1; then
  "${KUBECTL[@]}" scale statefulset argocd-application-controller --namespace argocd --replicas=0 --timeout=60s
  echo "[cleanup-k8s] Argo CD Application Controller 중지 완료"
else
  echo "[cleanup-k8s] 실행 중인 Argo CD Application Controller가 없습니다."
fi

echo "[3/7] Ingress 확인 및 삭제"
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

echo "[4/7] LoadBalancer Service 확인 및 삭제"
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

echo "[5/7] Redis/Kafka PVC 추적 및 Workload 정리"
track_persistent_storage
delete_persistent_workloads

echo "[6/7] Redis/Kafka PVC 삭제"
delete_persistent_volume_claims

echo "[7/7] Redis/Kafka PV/EBS 삭제 확인"
verify_persistent_storage_cleanup

echo "======================================"
echo " Kubernetes Cleanup Completed"
echo "======================================"
