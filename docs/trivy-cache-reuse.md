# Trivy 캐시 EBS 재사용

`tapply.sh`는 GitOps bootstrap 전에 `scripts/prepare-trivy-cache.sh`를 실행한다.
기본 디스크는 마지막 클러스터에서 사용한 `vol-043a9d5ffcb1428cb`이며,
`trivy-system/data-trivy-server-0` PVC에 정적으로 연결한다. PV 삭제 정책은
`Retain`이다. `tdestroy.sh`의 기존 정리 대상에는 `trivy-system`이 포함되지 않는다.
EKS 삭제로 Kubernetes 객체가 없어져도 다음 apply에서 같은 EBS를 다시 연결한다.

Trivy Helm chart 0.36.0은 이 이름의 기존 PVC를 사용하므로 GitOps 및
gitops-value 변경은 필요하지 않다. chart 업그레이드로 StatefulSet/PVC 이름이나
스토리지 요구사항이 바뀌면 이 스크립트도 함께 수정해야 한다.

기존 PVC/PV가 있으면 연결 디스크와 소유 관계를 확인한 뒤 Retain만 적용한다.
디스크가 없거나, 다른 PV가 같은 디스크를 참조하거나, 태그/크기/타입이 다르거나,
디스크 AZ에 Ready 노드가 없으면 apply를 중단한다. 새 디스크를 자동 생성하지 않는다.
중단 후 같은 설정으로 재실행할 수 있다.

운영자가 다른 기존 Trivy 디스크로 교체하기로 결정한 경우에만 다음처럼 지정한다.
이미 연결된 PVC가 다른 디스크를 가리키면 자동 교체하지 않고 중단한다.

```bash
AWS_PROFILE=petflow-terraform-ujibil1 \
TRIVY_CACHE_VOLUME_ID=vol-043a9d5ffcb1428cb ./tapply.sh
```

2026-10-03 재사용 디스크의 연결과 Trivy 스캔 성공을 확인한 뒤, 오래된
`vol-0909e495b3bc35532`는 사용자의 요청으로 삭제했다. 현재 캐시 디스크는
`vol-043a9d5ffcb1428cb` 하나이며 스크립트는 다른 EBS를 자동 삭제하지 않는다.
이는 원본 캐시 디스크 보존이며 스냅샷 백업은 아니다. 캐시는 Trivy가 계속 갱신한다.
`tapply.sh --finish`는 배포 마무리 작업이므로 이 준비 단계를 실행하지 않는다.
