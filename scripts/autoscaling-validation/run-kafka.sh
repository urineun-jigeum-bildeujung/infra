#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_MANIFEST="${ROOT_DIR}/kubernetes/tests/autoscaling-validation/kafka-base.yaml"
WORKLOAD_MANIFEST="${ROOT_DIR}/kubernetes/tests/autoscaling-validation/kafka-workload.yaml"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-petflow-dev}"
TEST_NAMESPACE="autoscaling-validation"
TEST_USER="autoscaling-validation-20260930"

for command in kubectl jq; do
  command -v "${command}" >/dev/null
done

actual_context="$(kubectl config current-context)"
if [[ "${actual_context}" != "${EXPECTED_CONTEXT}" ]]; then
  echo "오류: 현재 컨텍스트는 ${actual_context}이며 예상 컨텍스트는 ${EXPECTED_CONTEXT}입니다" >&2
  exit 1
fi

authorization="$(kubectl get kafka -n kafka pet-subscription-kafka \
  -o jsonpath='{.spec.kafka.authorization}')"
if [[ -z "${authorization}" ]]; then
  echo "경고: Kafka authorization이 비활성 상태입니다."
  echo "이 환경에서는 전용 SCRAM 사용자의 권한을 broker ACL로 제한할 수 없습니다."
fi

kubectl apply -f "${BASE_MANIFEST}"
kubectl wait -n kafka --for=condition=Ready \
  kafkatopic/autoscaling-validation-20260930 --timeout=120s
kubectl wait -n kafka --for=condition=Ready \
  kafkauser/autoscaling-validation-20260930 --timeout=120s

# 자격증명을 출력하지 않고 테스트 namespace 내부 Secret을 구성한다.
jq -s '.[0] as $user | .[1] as $ca |
  {apiVersion:"v1",kind:"Secret",
   metadata:{name:"kafka-credentials",namespace:"autoscaling-validation",
     labels:{"app.kubernetes.io/part-of":"autoscaling-validation"}},
   type:"Opaque",
   data:{username:("autoscaling-validation-20260930"|@base64),
     password:$user.data.password,"ca.crt":$ca.data["ca.crt"],
     "ca.p12":$ca.data["ca.p12"],"ca.password":$ca.data["ca.password"]}}' \
  <(kubectl get secret -n kafka "${TEST_USER}" -o json) \
  <(kubectl get secret -n kafka pet-subscription-kafka-cluster-ca-cert -o json) |
  kubectl apply -f -

kubectl delete job -n "${TEST_NAMESPACE}" produce-300 \
  --ignore-not-found --wait=true
kubectl apply -f "${WORKLOAD_MANIFEST}"

echo "관측: kubectl get pods,hpa,scaledobject -n ${TEST_NAMESPACE} -w"
echo "정리: ${ROOT_DIR}/scripts/autoscaling-validation/cleanup.sh"
