# EKS 모듈: 쿠버네티스 컨트롤 플레인 및 워커 노드 관련 리소스를 정의한다.
#
# 관리 대상:
#   - EKS Cluster
#   - Managed Node Group
#   - OIDC Provider
#   - EKS Access 관련 리소스 (aws-auth 등)
#
# Add-on / Karpenter 관련 구성은 추후 필요 시 별도 모듈로 분리할 수 있다.
# 실제 리소스 정의는 feat/eks 브랜치에서 추가한다.
