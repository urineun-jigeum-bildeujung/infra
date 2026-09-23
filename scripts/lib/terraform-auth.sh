#!/usr/bin/env bash
# PetFlow Terraform 공개 진입점에서 사용하는 공용 AWS 실행 Role Guard.
# 이 파일은 source 전용이며 단독 실행하지 않는다.

PETFLOW_TERRAFORM_ACCOUNT_ID="${PETFLOW_TERRAFORM_ACCOUNT_ID:-297165773875}"
PETFLOW_TERRAFORM_REGION="${PETFLOW_TERRAFORM_REGION:-ap-northeast-2}"
PETFLOW_TERRAFORM_ROLE_NAME="${PETFLOW_TERRAFORM_ROLE_NAME:-petflow-terraform-execution}"

petflow_validate_terraform_identity() {
  local label="${1:-terraform-auth}"
  local requested_region identity caller_account caller_arn expected_prefix

  [[ -n "${AWS_PROFILE:-}" ]] || {
    printf '[%s] ERROR: AWS_PROFILE에 공용 Terraform Role 프로필을 지정해주세요.\n' "${label}" >&2
    printf '[%s] 예: AWS_PROFILE=petflow-terraform-ujibil2 ./tplan.sh\n' "${label}" >&2
    return 1
  }

  requested_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region --profile "${AWS_PROFILE}" 2>/dev/null || true)}}"
  [[ "${requested_region}" == "${PETFLOW_TERRAFORM_REGION}" ]] || {
    printf '[%s] ERROR: 잘못된 AWS Region입니다: %s (예상: %s)\n' \
      "${label}" "${requested_region:-unset}" "${PETFLOW_TERRAFORM_REGION}" >&2
    return 1
  }

  identity="$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null)" || {
    printf '[%s] ERROR: AWS 인증 정보를 확인하지 못했습니다.\n' "${label}" >&2
    return 1
  }
  read -r caller_account caller_arn <<<"${identity}"

  [[ "${caller_account}" == "${PETFLOW_TERRAFORM_ACCOUNT_ID}" ]] || {
    printf '[%s] ERROR: 잘못된 AWS Account입니다: %s (예상: %s)\n' \
      "${label}" "${caller_account:-unknown}" "${PETFLOW_TERRAFORM_ACCOUNT_ID}" >&2
    return 1
  }

  expected_prefix="arn:aws:sts::${PETFLOW_TERRAFORM_ACCOUNT_ID}:assumed-role/${PETFLOW_TERRAFORM_ROLE_NAME}/"
  [[ "${caller_arn}" == "${expected_prefix}"* && "${caller_arn}" != "${expected_prefix}" ]] || {
    printf '[%s] ERROR: 공용 Terraform 실행 Role 세션이 아닙니다: %s\n' \
      "${label}" "${caller_arn:-unknown}" >&2
    printf '[%s] 예상 ARN: %s<session-name>\n' "${label}" "${expected_prefix}" >&2
    return 1
  }

  export AWS_REGION="${requested_region}"
  export PETFLOW_CALLER_ACCOUNT="${caller_account}"
  export PETFLOW_CALLER_ARN="${caller_arn}"

  printf '[%s] AWS Account Guard 통과: %s\n' "${label}" "${caller_account}"
  printf '[%s] AWS Caller Role Guard 통과: %s\n' "${label}" "${caller_arn}"
  printf '[%s] AWS Region Guard 통과: %s\n' "${label}" "${requested_region}"
}
