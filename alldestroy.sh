#!/usr/bin/env bash
# Kubernetes LB와 Persistent Storage 정리 후 Terraform 관리 DEV 인프라를 순서대로 삭제한다.
# 사용자 확인 입력 없이 즉시 실행되며 cleanup 실패 시 Terraform Destroy를 실행하지 않는다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo " Full Infrastructure Destroy"
echo "======================================"

echo "[1/2] Kubernetes LB/Persistent Storage Cleanup"
"${SCRIPT_DIR}/cleanup-k8s.sh"

echo "[2/2] Terraform Destroy"
"${SCRIPT_DIR}/tdestroy.sh"

echo "======================================"
echo " Full Infrastructure Destroy Completed"
echo "======================================"
