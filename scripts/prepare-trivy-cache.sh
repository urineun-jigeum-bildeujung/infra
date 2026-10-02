#!/usr/bin/env bash
# Preserve the existing cache across EKS recreation; never create/delete an EBS volume.
set -Eeuo pipefail

VOLUME_ID="${TRIVY_CACHE_VOLUME_ID:-vol-043a9d5ffcb1428cb}"
REGION=ap-northeast-2
NAMESPACE=trivy-system
PVC_NAME=data-trivy-server-0
PV_NAME=trivy-cache-retained
KUBE=(kubectl --context petflow-dev --request-timeout=30s)
die() { printf '[trivy-cache] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[trivy-cache] %s\n' "$*"; }
[[ $# == 0 ]] || die '인자를 받지 않습니다. TRIVY_CACHE_VOLUME_ID로 디스크를 지정하세요.'
[[ $VOLUME_ID =~ ^vol-[0-9a-f]+$ ]] || die '잘못된 EBS Volume ID'
for dependency in aws kubectl jq; do
  command -v "$dependency" >/dev/null || die "필수 도구 없음: $dependency"
done
account=$(aws sts get-caller-identity --query Account --output text)
[[ $account == 297165773875 ]] || die "AWS 계정 불일치: $account"
volume=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" --output json)
jq -e --arg id "$VOLUME_ID" '
  .Volumes | length == 1 and (.[0] |
    .VolumeId == $id and .VolumeType == "gp3" and .Size == 5 and
    (.State == "available" or .State == "in-use") and
    any(.Tags[]?; .Key == "kubernetes.io/created-for/pvc/namespace" and .Value == "trivy-system") and
    any(.Tags[]?; .Key == "kubernetes.io/created-for/pvc/name" and .Value == "data-trivy-server-0") and
    any(.Tags[]?; .Key == "KubernetesCluster" and .Value == "petflow-eks"))
' <<<"$volume" >/dev/null || die 'EBS 종류/크기/상태/Trivy 소유 태그 불일치'
zone=$(jq -r '.Volumes[0].AvailabilityZone' <<<"$volume")
nodes=$("${KUBE[@]}" get nodes -o json)
jq -e --arg zone "$zone" 'any(.items[];
  .metadata.labels["topology.kubernetes.io/zone"] == $zone and
  any(.status.conditions[]; .type == "Ready" and .status == "True"))' <<<"$nodes" >/dev/null \
  || die "디스크 AZ($zone)에 Ready 노드가 없습니다."

pvc=$("${KUBE[@]}" get pvc "$PVC_NAME" -n "$NAMESPACE" --ignore-not-found -o json)
if [[ -n $pvc ]]; then
  jq -e '.metadata.deletionTimestamp == null and .status.phase != "Lost"' <<<"$pvc" >/dev/null \
    || die '기존 Trivy PVC가 삭제 중이거나 Lost 상태입니다.'
  PV_NAME=$(jq -r '.spec.volumeName // empty' <<<"$pvc")
  [[ -n $PV_NAME ]] || die '기존 Trivy PVC가 아직 디스크를 선택하지 않았습니다. 연결 상태를 확인하세요.'
else
  [[ $(jq -r '.Volumes[0].State' <<<"$volume") == available ]] \
    || die '기존 PVC 없이 사용 중인 EBS를 재연결하지 않습니다.'
fi
pv=$("${KUBE[@]}" get pv "$PV_NAME" --ignore-not-found -o json)
all_pvs=$("${KUBE[@]}" get pv -o json)
jq -e --arg volume "$VOLUME_ID" --arg name "$PV_NAME" '
  all(.items[]; .spec.csi.volumeHandle != $volume or .metadata.name == $name)
' <<<"$all_pvs" >/dev/null || die '같은 디스크를 참조하는 다른 PV가 있습니다. 기존 연결을 확인하세요.'
if [[ -n $pv ]]; then
  pvc_uid=''
  if [[ -n $pvc ]]; then pvc_uid=$(jq -r '.metadata.uid' <<<"$pvc"); fi
  jq -e --arg volume "$VOLUME_ID" --arg uid "$pvc_uid" '
    .metadata.deletionTimestamp == null and
    .spec.csi.driver == "ebs.csi.aws.com" and .spec.csi.volumeHandle == $volume and
    .spec.storageClassName == "gp3" and .spec.claimRef.namespace == "trivy-system" and
    .spec.claimRef.name == "data-trivy-server-0" and
    ((.spec.claimRef.uid // "") == "" or .spec.claimRef.uid == $uid)
  ' <<<"$pv" >/dev/null || die '기존 PV의 디스크/소유 PVC가 다릅니다. 자동으로 교체하지 않습니다.'
  "${KUBE[@]}" patch pv "$PV_NAME" --type merge \
    -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
else
  [[ -z $pvc ]] || die '기존 PVC가 참조하는 PV가 없습니다.'
  # claimRef reserves this disk before creating the PVC, preventing dynamic provisioning.
  jq -n --arg volume "$VOLUME_ID" --arg zone "$zone" --arg name "$PV_NAME" '{
    apiVersion:"v1", kind:"PersistentVolume", metadata:{name:$name},
    spec:{capacity:{storage:"5Gi"}, accessModes:["ReadWriteOnce"], volumeMode:"Filesystem",
      persistentVolumeReclaimPolicy:"Retain", storageClassName:"gp3",
      claimRef:{namespace:"trivy-system",name:"data-trivy-server-0"},
      csi:{driver:"ebs.csi.aws.com",volumeHandle:$volume,fsType:"ext4"},
      nodeAffinity:{required:{nodeSelectorTerms:[{matchExpressions:[{
        key:"topology.kubernetes.io/zone",operator:"In",values:[$zone]
      }]}]}}}
  }' | "${KUBE[@]}" create -f - >/dev/null
fi
if [[ -z $pvc ]]; then
  "${KUBE[@]}" create namespace "$NAMESPACE" --dry-run=client -o json \
    | "${KUBE[@]}" apply -f - >/dev/null
  jq -n --arg pv "$PV_NAME" '{
    apiVersion:"v1",kind:"PersistentVolumeClaim",
    metadata:{name:"data-trivy-server-0",namespace:"trivy-system"},
    spec:{accessModes:["ReadWriteOnce"],volumeMode:"Filesystem",storageClassName:"gp3",
      volumeName:$pv,resources:{requests:{storage:"5Gi"}}}
  }' | "${KUBE[@]}" create -f - >/dev/null
fi
"${KUBE[@]}" wait -n "$NAMESPACE" "pvc/$PVC_NAME" \
  --for=jsonpath='{.status.phase}'=Bound --timeout=60s >/dev/null
log "$VOLUME_ID → $PV_NAME → $NAMESPACE/$PVC_NAME 준비 완료 (Retain, AZ=$zone)"
