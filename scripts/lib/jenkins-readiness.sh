#!/usr/bin/env bash

# Accept only an unused WFFC cache; assess the other Application resources live
# because Argo CD 3.5 can omit per-resource health from Application.status.
jenkins_cache_only_progressing() {
  jq -e '
    def live($items; $r): [$items[] | select(.metadata.name == $r.name and
      .metadata.namespace == $r.namespace)] | if length == 1 then .[0] else null end;
    . as $s |
    .application as $a |
    $a.status.sync.status == "Synced" and
    $a.status.health.status == "Progressing" and
    ($a.status.conditions // [] | length) == 0 and
    $a.operation == null and $a.status.operationState.phase == "Succeeded" and
    $s.storageclass.metadata.name == "gp3" and
    $s.storageclass.volumeBindingMode == "WaitForFirstConsumer" and
    any($a.status.resources[]?; .kind == "PersistentVolumeClaim" and
      .namespace == "jenkins" and .name == "sever-ci-gradle-cache") and
    any($a.status.resources[]?; .kind == "StatefulSet" and .name == "jenkins") and
    all($a.status.resources[];
      . as $r | .status == "Synced" and (.requiresPruning // false | not) and
      .namespace == "jenkins" and
      if .kind == "PersistentVolumeClaim" then
        live($s.pvcs.items; $r) as $p | $p != null and $p.metadata.deletionTimestamp == null and
        if .name == "sever-ci-gradle-cache" then
          $p.status.phase == "Pending" and $p.spec.storageClassName == "gp3" and
          ($p.spec.volumeName // "") == "" and
          $p.metadata.annotations["volume.kubernetes.io/selected-node"] == null and
          ($p.status.conditions // [] | length) == 0 and
          ((.health.status // "Progressing") == "Progressing")
        else $p.status.phase == "Bound" and ((.health.status // "Healthy") == "Healthy") end
      elif .kind == "StatefulSet" then
        live($s.statefulsets.items; $r) as $t | $t != null and
        $t.metadata.deletionTimestamp == null and
        $t.status.observedGeneration >= $t.metadata.generation and
        $t.spec.replicas > 0 and $t.status.readyReplicas == $t.spec.replicas and
        $t.status.updatedReplicas == $t.spec.replicas and
        $t.status.currentRevision == $t.status.updateRevision and
        ((.health.status // "Healthy") == "Healthy")
      elif .kind == "Ingress" then
        live($s.ingresses.items; $r) as $i | $i != null and
        $i.metadata.deletionTimestamp == null and
        any($i.status.loadBalancer.ingress[]?; (.hostname // .ip // "") != "") and
        ((.health.status // "Healthy") == "Healthy")
      else
        (["ConfigMap","Service","ServiceAccount","Role","RoleBinding"] | index($r.kind)) != null and
        ((.health.status // "Healthy") == "Healthy")
      end)
  ' >/dev/null
}

jenkins_unused_cache_ready() {
  local application pvcs statefulsets ingresses storageclass
  local -a command=(kubectl --context "${KUBECONFIG_CONTEXT}" --request-timeout=20s)
  application=$("${command[@]}" -n argocd get application jenkins -o json) || return 1
  pvcs=$("${command[@]}" -n jenkins get pvc -o json) || return 1
  statefulsets=$("${command[@]}" -n jenkins get statefulset -o json) || return 1
  ingresses=$("${command[@]}" -n jenkins get ingress -o json) || return 1
  storageclass=$("${command[@]}" get storageclass gp3 -o json) || return 1
  jq -n --argjson application "$application" --argjson pvcs "$pvcs" \
    --argjson statefulsets "$statefulsets" --argjson ingresses "$ingresses" \
    --argjson storageclass "$storageclass" \
    '{application:$application,pvcs:$pvcs,statefulsets:$statefulsets,ingresses:$ingresses,storageclass:$storageclass}' \
    | jenkins_cache_only_progressing
}
