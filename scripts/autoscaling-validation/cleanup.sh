#!/usr/bin/env bash
set -euo pipefail

TEST_NAMESPACE="autoscaling-validation"
TOPIC="autoscaling-validation-20260930"
USER="autoscaling-validation-20260930"

kubectl delete namespace "${TEST_NAMESPACE}" --ignore-not-found --wait=true
kubectl delete networkpolicy -n kafka allow-autoscaling-validation --ignore-not-found
kubectl delete kafkatopic -n kafka "${TOPIC}" --ignore-not-found --wait=true
kubectl delete kafkauser -n kafka "${USER}" --ignore-not-found --wait=true

echo "autoscaling validation resources removed"
