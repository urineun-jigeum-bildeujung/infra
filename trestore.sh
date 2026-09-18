#!/usr/bin/env bash
# 이전 전체 복구 명령과의 호환을 위한 래퍼다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[DEPRECATED] trestore.sh는 폐기 예정입니다. tapply.sh를 사용하세요." >&2
exec "${SCRIPT_DIR}/tapply.sh" "$@"
