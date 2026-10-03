import copy
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def fixture():
    def resource(kind, name):
        return dict(kind=kind, name=name, namespace="jenkins", status="Synced")

    return {
        "application": {"status": {
            "sync": {"status": "Synced"}, "health": {"status": "Progressing"},
            "operationState": {"phase": "Succeeded"},
            "resources": [resource("PersistentVolumeClaim", "sever-ci-gradle-cache"),
                          resource("PersistentVolumeClaim", "jenkins"),
                          resource("StatefulSet", "jenkins"), resource("Ingress", "jenkins"),
                          resource("ConfigMap", "jenkins"), resource("Service", "jenkins")]}},
        "storageclass": {"metadata": {"name": "gp3"}, "volumeBindingMode": "WaitForFirstConsumer"},
        "pvcs": {"items": [
            {"metadata": {"name": "sever-ci-gradle-cache", "namespace": "jenkins"},
             "spec": {"storageClassName": "gp3"}, "status": {"phase": "Pending"}},
            {"metadata": {"name": "jenkins", "namespace": "jenkins"},
             "status": {"phase": "Bound"}}]},
        "statefulsets": {"items": [{"metadata": {
            "name": "jenkins", "namespace": "jenkins", "generation": 1},
            "spec": {"replicas": 1}, "status": {"observedGeneration": 1,
            "readyReplicas": 1, "updatedReplicas": 1, "currentRevision": "a", "updateRevision": "a"}}]},
        "ingresses": {"items": [{"metadata": {"name": "jenkins", "namespace": "jenkins"},
            "status": {"loadBalancer": {"ingress": [{"hostname": "internal.example"}]}}}]},
    }


class JenkinsReadinessTests(unittest.TestCase):
    def accepted(self, value):
        result = subprocess.run([
            "bash", "-c", 'source "$1"; jenkins_cache_only_progressing',
            "test", str(ROOT / "scripts/lib/jenkins-readiness.sh")],
            input=json.dumps(value), universal_newlines=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.stderr, "")
        return result.returncode == 0

    def test_unused_cache_is_allowed_without_argocd_per_resource_health(self):
        self.assertTrue(self.accepted(fixture()))

    def test_other_failures_are_not_hidden(self):
        cases = []
        def changed(mutator):
            value = copy.deepcopy(fixture())
            mutator(value)
            cases.append(value)
        changed(lambda v: v["application"]["status"]["sync"].update(status="OutOfSync"))
        changed(lambda v: v["application"]["status"].update(conditions=[{"type": "ComparisonError"}]))
        changed(lambda v: v["application"].update(operation={"sync": {}}))
        changed(lambda v: v["pvcs"]["items"][1]["status"].update(phase="Pending"))
        changed(lambda v: v["pvcs"]["items"][0]["metadata"].update(
            annotations={"volume.kubernetes.io/selected-node": "node"}))
        changed(lambda v: v["pvcs"]["items"][0]["status"].update(conditions=[{"type": "Resizing"}]))
        changed(lambda v: v["storageclass"].update(volumeBindingMode="Immediate"))
        changed(lambda v: v["statefulsets"]["items"][0]["status"].update(readyReplicas=0))
        changed(lambda v: v["statefulsets"]["items"][0]["status"].update(updateRevision="b"))
        changed(lambda v: v["ingresses"]["items"][0]["status"].update(loadBalancer={}))
        changed(lambda v: v["application"]["status"]["resources"].append(
            dict(kind="Job", name="failing-job", namespace="jenkins", status="Synced")))
        changed(lambda v: v["application"]["status"]["resources"][3].update(health={"status": "Degraded"}))
        changed(lambda v: v["application"]["status"]["resources"].pop(0))
        for index, value in enumerate(cases):
            with self.subTest(case=index):
                self.assertFalse(self.accepted(value))

    def test_resume_skips_provisioning_and_requires_ready_marker(self):
        source = (ROOT / "tapply.sh").read_text()
        start = source.index('if [[ "${FINISH_ONLY}" == false ]]; then')
        end = source.index('log "[11/18]', start)
        # Exercise the real branch with external commands replaced by read-only
        # fixtures. An accidental call to provisioning/bootstrap fails this test.
        script = r'''
set -Eeuo pipefail
FINISH_ONLY=false
FROM_JENKINS=true
SCRIPT_DIR=/unused
TERRAFORM_DIR=/unused
GITOPS_DIR=/unused
EXPECTED_AWS_REGION=ap-northeast-2
KUBECONFIG_CONTEXT=petflow-dev
log() { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
terraform() {
  [[ "$2" == output ]] || return 1
  case "$4" in
    eks_cluster_name) printf petflow-eks ;;
    aws_region) printf ap-northeast-2 ;;
    *) return 1 ;;
  esac
}
aws() { [[ "$1 $2" == 'eks update-kubeconfig' ]]; }
kubectl() {
  if [[ "$1 $2" == 'config use-context' ]]; then return 0; fi
  [[ "$*" == *'get configmap stateful-recovery'* ]] || return 1
  printf '%s' "$MARKER_PHASE"
}
bash() {
  [[ "$1" == /unused/scripts/stateful-restore.sh ]] || return 1
  printf 'CHECK_EXISTING_STORES\n'
}
wait_for_eks_readyz() { :; }
wait_for_keda() { printf 'CHECK_KEDA\n'; }
wait_for_karpenter() { printf 'CHECK_KARPENTER\n'; }
wait_for_service_gitops_sync() { printf 'CHECK_SERVICES\n'; }
wait_for_autoscaling_targets() { printf 'CHECK_AUTOSCALING\n'; }
'''
        # Close the enclosing FINISH_ONLY branch at the extraction boundary.
        script += source[start:end] + '\nfi\n'
        for phase in ("ready", "restoring"):
            result = subprocess.run(["bash", "-c", script],
                env=dict(os.environ, MARKER_PHASE=phase), universal_newlines=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if phase == "ready":
                self.assertEqual(result.returncode, 0, result.stderr)
                for check in ("CHECK_EXISTING_STORES", "CHECK_KEDA", "CHECK_KARPENTER",
                              "CHECK_SERVICES", "CHECK_AUTOSCALING"):
                    self.assertIn(check, result.stdout)
                self.assertNotIn("[1/18]", result.stdout)
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("CHECK_EXISTING_STORES", result.stdout)


if __name__ == "__main__":
    unittest.main()
