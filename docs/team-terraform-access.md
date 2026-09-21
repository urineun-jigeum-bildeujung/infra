# 팀 공용 Terraform 실행 권한

PetFlow DEV Terraform은 개인 IAM 사용자의 광범위한 권한에 의존하지 않고, Bootstrap 스택에서 영구 보존하는 `petflow-terraform-execution` Role로 실행한다. DEV `tdestroy.sh`의 대상 State와 분리되어 있으므로 인프라를 삭제해도 Role, Trust Policy, State Bucket 및 Lock 기반은 유지된다.

## 권한 구조

```text
ujibil1~ujibil5 IAM User
  └─ sts:AssumeRole만 허용
       └─ petflow-terraform-execution
            ├─ DEV 인프라 관리 권한
            ├─ Terraform State/.tflock 접근
            └─ 보호 Route53 Hosted Zone 삭제 거부
```

Trust Policy에는 승인된 IAM User ARN만 명시한다. `Principal: "*"`는 사용하지 않는다. 현재 Role의 인프라 관리 권한은 초기 운영 단계의 `AdministratorAccess`이며, 실제 API 사용 범위가 안정되면 프로젝트 최소 권한 Policy로 축소한다.

## 최초 Bootstrap 적용

이 작업은 기존 Bootstrap 관리자 프로필로 한 번만 수행한다. DEV 전체 Terraform과 State가 다르므로 DEV destroy/apply에 포함하지 않는다.

```bash
cd terraform/bootstrap/terraform-access
terraform init -backend-config=backend.hcl
terraform plan -out=terraform-access.tfplan
terraform apply terraform-access.tfplan
terraform output terraform_execution_role_arn
```

Bootstrap 입력의 `terraform_execution_user_names`에는 승인된 실제 IAM 사용자만 둔다. 사용자를 제거하면 다음 Bootstrap apply에서 해당 사용자의 Assume Policy attachment와 Trust 항목이 함께 제거된다.

## 팀원 AWS CLI 프로필

각 팀원은 기존 본인 프로필을 `source_profile`로 두고 공용 Role 프로필을 추가한다. 예를 들어 `ujibil2`는 `~/.aws/config`에 다음을 설정한다.

```ini
[profile petflow-terraform-ujibil2]
role_arn = arn:aws:iam::297165773875:role/petflow-terraform-execution
source_profile = ujibil2
role_session_name = ujibil2
region = ap-northeast-2
duration_seconds = 14400
```

프로필 이름과 `source_profile`, `role_session_name`만 자신의 사용자에 맞게 바꾼다. 장기 Access Key를 새로 복제하거나 공용 자격 증명을 공유하지 않는다.

```bash
aws sts get-caller-identity --profile petflow-terraform-ujibil2
```

정상 ARN 형식은 다음과 같다.

```text
arn:aws:sts::297165773875:assumed-role/petflow-terraform-execution/ujibil2
```

## Terraform 실행

공개 진입점은 Account, Region뿐 아니라 Caller ARN이 공용 Role 세션인지도 확인한다. IAM User 프로필을 직접 넣으면 AWS 권한이 있더라도 실행을 중단한다.

```bash
AWS_PROFILE=petflow-terraform-ujibil2 ./tinit.sh
AWS_PROFILE=petflow-terraform-ujibil2 ./tplan.sh
AWS_PROFILE=petflow-terraform-ujibil2 ./tapply.sh
AWS_PROFILE=petflow-terraform-ujibil2 ./tdestroy.sh
```

동일한 `AWS_PROFILE`과 Role 세션이 Terraform Backend, AWS CLI, EKS kubeconfig 및 하위 스크립트까지 상속된다. 공용 Role ARN은 DEV 코드에서 EKS Cluster Admin Access Entry와 CloudTrail/VPC Flow Log 버킷 보호 예외에 자동 포함된다.

## 검증 및 운영 주의사항

> 현재 AWS 계정에서는 `ujibil1~ujibil5`가 기존 `IAM` 그룹을 통해 직접 `AdministratorAccess`도 보유한다. 이번 작업은 Terraform 스크립트의 실행 주체를 공용 Role로 통일했으며, 기존 그룹 권한 제거는 다른 업무 영향 분석과 별도 승인을 거쳐 진행한다.

- `terraform/bootstrap/terraform-access` State와 `petflow-tfstate` Bucket은 DEV destroy 대상이 아니다.
- 실행 전 `aws sts get-caller-identity`에서 Account와 assumed-role ARN을 확인한다.
- `terraform plan`에서 예상하지 않은 삭제나 교체가 있으면 apply하지 않는다.
- 감사 로그 Bucket Policy의 추가 개인 ARN 입력은 비상 전환용이다. 평상시 `cloudtrail_admin_role_arns = []`를 유지한다.
- Role이 없거나 만료됐거나 직접 IAM User로 실행하면 스크립트 Guard가 Terraform 전에 중단한다.
- 승인 사용자 변경은 Bootstrap PR과 Plan 검토를 거쳐 적용한다.
