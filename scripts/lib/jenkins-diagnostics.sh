#!/usr/bin/env bash

# Jenkins 기동 실패를 Secret 값 없이 분류하고 필요한 로그 줄만 남긴다.
# 이 파일은 tapply.sh에서 source하며, 함수는 진단 실패 자체로 원래 오류를 덮지 않도록
# 항상 출력 가능한 결과를 반환한다.

jenkins_classify_failure() {
  local text="${1:-}"

  if grep -Eiq 'mirror\.|jenkins-plugin-cli|download(ed|ing)? .*plugin|unable to download|failed to download' <<<"${text}"; then
    if grep -Eiq 'network is unreachable|unknownhost|could not resolve|temporary failure in name resolution|connection refused|connect timed out|read timed out|timeout|timed out' <<<"${text}"; then
      printf 'PLUGIN_DOWNLOAD_NETWORK\n'
      return 0
    fi
    if grep -Eiq 'HTTP(/[0-9.]+)?[[:space:]]+[45][0-9]{2}|status(code)?[=: ]+[45][0-9]{2}|response code:[[:space:]]*[45][0-9]{2}' <<<"${text}"; then
      printf 'PLUGIN_DOWNLOAD_HTTP\n'
      return 0
    fi
    printf 'PLUGIN_DOWNLOAD\n'
    return 0
  fi

  if grep -Eiq 'ErrImagePull|ImagePullBackOff|Failed to pull image|pull access denied' <<<"${text}"; then
    printf 'IMAGE_PULL\n'
  elif grep -Eiq 'PersistentVolumeClaim.*(not found|pending)|pod has unbound immediate PersistentVolumeClaims|FailedMount|Unable to attach or mount volumes' <<<"${text}"; then
    printf 'PVC_OR_VOLUME\n'
  elif grep -Eiq 'FailedScheduling|Insufficient (cpu|memory)|didn.t match.*selector|untolerated taint' <<<"${text}"; then
    printf 'SCHEDULING\n'
  elif grep -Eiq 'ConfigurationAsCode|JCasC|UnknownAttributesException|Invalid configuration elements|Failed to apply configuration' <<<"${text}"; then
    printf 'JCASC\n'
  else
    printf 'UNKNOWN\n'
  fi
}

jenkins_safe_log_excerpt() {
  sed -E \
    -e 's#(Authorization:)[^[:space:]]+#\1[REDACTED]#Ig' \
    -e 's#((password|passwd|token|secret|credential)[=:])[[:graph:]]+#\1[REDACTED]#Ig' \
    -e 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[REDACTED]@#g' \
    | grep -Ei \
      'mirror\.|jenkins-plugin-cli|plugin.*(download|fail)|network is unreachable|unknownhost|could not resolve|name resolution|connection refused|timed out|timeout|HTTP(/[0-9.]+)?[[:space:]]+[45][0-9]{2}|status(code)?[=: ]+[45][0-9]{2}|ErrImagePull|ImagePullBackOff|Failed to pull image|PersistentVolumeClaim|FailedMount|attach or mount|FailedScheduling|Insufficient (cpu|memory)|selector|taint|ConfigurationAsCode|JCasC|UnknownAttributesException|Invalid configuration|SEVERE|ERROR|Exception' \
    | tail -n 60 || true
}
