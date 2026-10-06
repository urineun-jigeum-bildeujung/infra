# 초기 GitOps 배포 실패 복구

`tapply.sh`는 Argo CD 설치 후 GitOps의 namespace 매니페스트와 AppProject를
먼저 적용하고, 별도로 `web` namespace를 준비한 다음 root-app을 배포한다.
서비스보다 먼저 생성되는 ExternalSecret/RBAC 및 platform-root의 참조 대상을 확보한다.

Karpenter 준비 이후에는 서비스 Application 동기화와 Web의 `juso-credentials`
ExternalSecret Ready를 확인한 뒤 HPA/PDB 검사로 넘어간다.
repo-server가 준비된 상태에서 서비스 또는 external-secrets-config의 종료된
동기화가 manifest 생성 타임아웃/연결 실패로 남아 있으면 재동기화를 요청한다.
기존 syncOptions를 유지하고 CreateNamespace를 포함하며 prune은 실행하지 않는다.
한 루프에 하나씩, 같은 Application은 최소 60초 간격으로 최대 2회 요청한다.
각 요청의 내부 재시도는 최대 2회다. 진행 중인 동기화나 다른 설정 오류는 건드리지 않는다.
전체 준비 제한 시간을 초과하면 apply를 중단하고 Application 상태를 출력한다.

이 처리는 일시적인 repo-server 장애 후 배포가 실패 상태에 머무르는 문제를 복구한다.
repo-server의 초기 부하 및 liveness 실패 자체를 없애는 변경은 아니다.
자원 요청량/차트 렌더링 동시성 조정은 GitOps Argo CD Helm values에서 별도로 검토한다.

Grafana 관리자 Secret 기본값은 GitOps와 같은 `grafana-admin-credentials`다.
`GRAFANA_ADMIN_SECRET_NAME`으로 변경할 수 있으며 값은 로그에 출력하지 않는다.
관리자 비밀번호 최소 길이는 upstream #75와 같은 10자리다.
`GRAFANA_ADMIN_PASSWORD_MIN_LENGTH`로 변경할 수 있다.
빈 계정/비밀번호와 기본 admin/admin 및 개행 문자는 차단하며, Grafana 계정 복구 단계에서
실제 로그인 성공을 확인한다. 이 변경은 AWS Secret의 비밀번호를 변경하지 않는다.
Grafana 단계에서 실패했다면 `./tapply.sh --finish`로 Web DNS/HTTPS를 먼저 복구한 뒤
Grafana ALB/DNS/HTTPS 검증을 다시 실행한다. 이 경로는 전체 Terraform apply와 데이터 복원을 반복하지 않는다.
기존 복원 완료 확인과 현재 데이터 검증은 유지한다.

## 최신 코드와 추천 IAM 정합성

로컬 dev는 `ff84b5a`까지 갱신했으며 PR #76의 `3055405`를 포함한다.
추천 IAM·S3 정의는 upstream 버전을 사용하고, 임시로 추가했던 별도
`recommendation.tf`와 변수는 제거했다. 기존 Terraform state의 `[0]` 주소도
upstream의 인덱스 없는 주소로 이동했으며 실제 AWS 리소스는 재생성하지 않았다.
추천 정책의 권한 범위는 upstream의 `recommendation/*` 읽기 전용과 동일하다.
기존 정책의 AWS 설명문은 변경할 수 없으므로 description 차이만 lifecycle에서
무시한다. policy 본문과 실제 권한 변경은 계속 Terraform으로 관리한다.
