# ALB / HTTPS End-to-End 검증

## 목적

실제 Frontend/Backend 배포 전에 다음 전체 경로를 nginx로 검증한다.

~~~text
Client → Route53 → ALB(HTTPS/ACM) → Ingress → Service → nginx Pod
~~~

테스트 주소는 **https://test.leechs.shop**이다. 테스트 ALB는 실행 중 비용이
발생하므로 검증 직후 반드시 정리한다.

## 선행 조건

- EKS Cluster와 Managed Node Group 정상
- kube-system/aws-load-balancer-controller Deployment 정상
- 같은 이름의 ServiceAccount와 EKS Pod Identity Association 연결
- Public Subnet 2개에 kubernetes.io/role/elb=1 태그
- leechs.shop, *.leechs.shop ACM 인증서가 ISSUED
- Terraform DEV Backend 초기화 및 output 조회 가능

Controller가 없으면 먼저 설치한다.

~~~bash
AWS_PROFILE=ujibil2 ./scripts/install-alb-controller.sh
~~~

## 테스트 배포

~~~bash
AWS_PROFILE=ujibil2 ./scripts/https-test.sh deploy
~~~

스크립트는 다음을 자동으로 수행한다.

1. nginx Deployment/ClusterIP Service/ALB Ingress 배포
2. Internet-facing ALB와 HTTP 80/HTTPS 443 Listener 생성 대기
3. Target Group이 healthy가 될 때까지 대기
4. test.leechs.shop Route53 A Alias 생성
5. HTTPS 200 및 HTTP 301/302 Redirect 확인

상태만 다시 확인하려면 다음을 실행한다.

~~~bash
AWS_PROFILE=ujibil2 ./scripts/https-test.sh status
~~~

## 테스트 정리

~~~bash
AWS_PROFILE=ujibil2 ./scripts/https-test.sh cleanup
~~~

정리 대상:

- test.leechs.shop A Alias
- https-test Namespace
- nginx Deployment/Service
- ALB Ingress와 Controller가 생성한 ALB/Target Group/Security Group

유지 대상:

- Route53 Hosted Zone과 ACM Validation Record
- ACM 인증서
- AWS Load Balancer Controller IAM/Pod Identity
- AWS Load Balancer Controller Helm Release

## 2026-09-10 실제 검증 결과

- EKS Node 2개 Ready
- Controller Helm Chart 3.5.0, DEV Pod 1개 Running
- ALB: internet-facing, 서울 리전 2b/2d
- Listener 80: HTTPS Redirect
- Listener 443: ACM 인증서 연결
- nginx Target 2개: healthy
- https://test.leechs.shop: HTTP/2 200
- http://test.leechs.shop: 301 → HTTPS
- 검증 후 테스트 Alias, Namespace, ALB 삭제 확인
