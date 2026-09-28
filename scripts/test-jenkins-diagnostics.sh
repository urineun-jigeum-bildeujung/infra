#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/jenkins-diagnostics.sh
source "${SCRIPT_DIR}/lib/jenkins-diagnostics.sh"

assert_classification() {
  local expected="$1"
  local fixture="$2"
  local actual

  actual="$(jenkins_classify_failure "${fixture}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'expected=%s actual=%s fixture=%s\n' "${expected}" "${actual}" "${fixture}" >&2
    exit 1
  fi
}

assert_classification PLUGIN_DOWNLOAD_NETWORK \
  'Failed to download plugin from mirror.ossplanet.net: Network is unreachable'
assert_classification PLUGIN_DOWNLOAD_HTTP \
  'jenkins-plugin-cli unable to download git plugin: HTTP 503'
assert_classification IMAGE_PULL \
  'Back-off pulling image: ImagePullBackOff'
assert_classification PVC_OR_VOLUME \
  'pod has unbound immediate PersistentVolumeClaims'
assert_classification SCHEDULING \
  'FailedScheduling: 0/4 nodes are available: Insufficient memory'
assert_classification JCASC \
  'ConfigurationAsCode: Invalid configuration elements for type Jenkins'
assert_classification UNKNOWN \
  'container is waiting for an unspecified reason'

redacted="$(printf '%s\n' \
  'ERROR token=should-not-appear Authorization:Bearer-secret https://user:pass@example.invalid' \
  | jenkins_safe_log_excerpt)"
[[ "${redacted}" != *'should-not-appear'* ]]
[[ "${redacted}" != *'Bearer-secret'* ]]
[[ "${redacted}" != *'user:pass'* ]]

printf 'jenkins diagnostics tests: PASS\n'
