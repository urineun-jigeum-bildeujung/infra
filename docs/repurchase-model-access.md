# 재구매 Job의 S3 모델 읽기

## 코드와 적용 범위

`terraform/modules/platform-iam/repurchase-model-reader.tf`는 기존 recommendation과
같은 Pod Identity 신뢰 정책을 사용한다. 역할은
`petflow-dev-repurchase-model-reader`이며, `petflow-dev-ml-artifacts`의
`repurchase/` 하위 목록 조회와 객체 읽기만 허용한다. 업로드/삭제 권한은 없다.
연결 대상은 EKS `petflow-eks`, namespace `repurchase`, ServiceAccount
`generic-service`다. 서비스 계정에 IRSA ARN annotation이나 AWS access key를 넣지 않는다.

서비스 계정은 GitOps의 `platform/60-cnpg-cluster/manifests/repurchase-serviceaccount.yaml`
에서 준비한다. `repurchase` value는 `serviceAccount.create: false`로 동일 계정의
이중 관리를 피한다. 기본 이름을 바꾸면 Job과 Pod Identity 연결도 같이 수정해야 한다.

현재 `values/dev/services/repurchase`는 ApplicationSet에서 감지되어
`dev-repurchase` Application이 S3 프록시와 NetworkPolicy를 관리한다.
`deployment.enabled: false`, `cronJobs: []`로 예측 배치의 상시/정기 실행은 비활성 상태다.
수동 검증 파일은 `gitops/operations/repurchase-contract-check.yaml`에 있으며,
ArgoCD 자동 동기화 경로 밖에 두어 수동 실행한다. 이 Job은 모델 다운로드/예측을 하지 않는다.

## 적용 순서

1. Terraform DEV에서 plan을 검토하고 IAM 역할/정책/Pod Identity 연결을 적용한다.
   이번 권한 추가 외의 변경이 함께 계획되면 해당 변경도 검토한다.
2. GitOps platform의 서비스 계정과 NetworkPolicy를 동기화한다.
3. S3 다운로드용 네트워크를 준비한다. 기존 generic-service 차트를
   `--namespace repurchase`, release `dev-repurchase`, `repurchase/values.yaml`로
   렌더링하면 Python용 S3 프록시와 정책이 생성된다. 현재 GitOps에서 활성화되어
   있으므로 `dev-repurchase` Application의 Synced/Healthy 상태를 확인한다.
   `cronJobs: []`는 유지하고 실제 배치 이미지/명령을 확정한 후 별도로 실행한다.
4. 아래 계정/라벨/프록시 환경변수를 사용한 **새** 수동 Job을 생성한다.
   이미 완료된 Job/Pod는 Pod Identity 연결을 추가해도 다시 실행되지 않는다.

## 수동 Job의 연결 계약

```yaml
spec:
  template:
    metadata:
      labels:
        app.kubernetes.io/name: generic-service
        app.kubernetes.io/instance: dev-repurchase
    spec:
      serviceAccountName: generic-service
      containers:
        - name: batch
          # image/command/args는 검증할 실제 배치 설정을 사용한다.
          env:
            - name: AWS_REGION
              value: ap-northeast-2
            - name: AWS_DEFAULT_REGION
              value: ap-northeast-2
            - name: HTTP_PROXY
              value: http://generic-service-egress.repurchase.svc.cluster.local:3128
            - name: HTTPS_PROXY
              value: http://generic-service-egress.repurchase.svc.cluster.local:3128
            - name: NO_PROXY
              value: localhost,127.0.0.1,::1,.svc,.svc.cluster.local,169.254.170.23
```

일반 Helm CronJob에는 차트가 위 계정/라벨/프록시 환경변수를 넣는다. 수동 작성한
Job과 initContainer에는 직접 넣어야 한다. 자격증명 조회는 프록시를 우회하고,
S3 HTTPS만 허용된 도메인의 프록시로 연결한다. 수동 Job은 위 서비스 라벨 대신
`spec.template.metadata.labels.role: repurchase-shadow`를 사용할 수도 있다.
Job 자체의 metadata.labels만 설정하면 Pod에 전달되지 않으므로 주의한다.
두 경우 모두 `serviceAccountName: generic-service`와 프록시 환경변수가 필요하다.
이 value의 네트워크는 IPv4 노드용이다.

## NetworkPolicy 연결 범위

현재 `shadow_batch_runtime.py`는 주문 DB와 회원 DB에서 입력을 읽고 재구매 DB에
결과를 쓴다. 서버/웹 코드에는 이 Job을 직접 호출하는 경로가 확인되지 않아
배치 Pod로 들어오는 API 포트는 열지 않는다. Redis/Kafka 연결도 현재 코드에 없다.

| 경로 | 허용 범위 / 수신 측 확인 |
| --- | --- |
| 배치 → DNS | kube-system의 kube-dns, UDP/TCP 53; 현재 DNS 수신 정책 없음 |
| 배치 → DB | database의 petflow-db, TCP 5432; DB 정책에서도 두 종류의 Pod 라벨 허용 |
| 배치 → 자격증명 | 169.254.170.23/32, TCP 80, 프록시 우회 |
| 배치 → S3 프록시 | 동일 namespace의 egress-proxy/dev-repurchase, TCP 3128; 프록시 수신 정책도 두 종류 라벨 허용 |
| 프록시 → S3 | 차트의 외부 HTTPS 정책 및 Squid의 정확한 버킷 도메인 제한 |

DB 송신 정책은 petflow-db의 primary와 replica를 허용한다. 읽기용 입력 DSN이
`petflow-db-ro`를 사용해도 연결되고, 결과 쓰기 DSN은 `petflow-db-rw`를 사용한다.
포트 허용은 DB 인증/권한 부여를 대신하지 않는다. 실제 예측에는
`REPURCHASE_ORDER_DATABASE_DSN`, `REPURCHASE_MEMBER_DATABASE_DSN`,
`REPURCHASE_RESULT_DATABASE_DSN`을 Secret으로 별도 제공해야 한다.

169.254.170.23은 임의의 노드/Pod 주소가 아니라 AWS가 지정한 Pod Identity Agent의
고정 IPv4 주소다. 이 `/32`는 그대로 두며 `NO_PROXY`에서도 같은 주소를 사용한다.
IPv6 자격증명 경로로 전환할 때는 `[fd00:ec2::23]`에 맞춘 정책/환경변수 검토가 필요하다.
참고: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html

정적 테스트는 Helm 렌더링과 송신/수신 정책을 함께 검사한다. 실제 CNI 집행과
Pod Identity 자격증명 발급, S3 다운로드는 클러스터 적용 후 새 Job에서 검증한다.

## 모델 다운로드와 예측은 별도

Pod Identity는 지원되는 AWS SDK/CLI의 기본 자격증명 체인으로 사용한다.
리전별 S3 주소 `petflow-dev-ml-artifacts.s3.ap-northeast-2.amazonaws.com`를 사용한다.
프록시에서는 다른 버킷/도메인으로의 연결을 허용하지 않는다.

S3 권한만 추가한다고 `contract-check`가 예측 배치로 바뀌지는 않는다.
현재 `shadow-run --model-directory`는 로컬 모델 디렉터리를 읽는다. 실제 모델의
버전별 S3 경로를 확정하고, 배치 코드 또는 initContainer로 파일을 내려받아
공유 볼륨에 넣은 다음 해당 경로를 넘겨야 한다. 이미지에 boto3/AWS CLI 등
다운로드 도구가 있는지도 확인한다. 임의의 최신 모델을 선택하지 않는다.

적용 후에는 새 Job에서 모델 경로의 목록 조회와 지정 모델 객체 다운로드를 확인한다.
다른 서비스 prefix의 읽기 및 업로드/삭제가 정책에 허용되지 않는지도 검토한다.
DB Secret/SHADOW 실행 인자/모델 artifact ID 검증은 별도로 준비한다.
