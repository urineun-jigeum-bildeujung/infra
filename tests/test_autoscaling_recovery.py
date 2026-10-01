"""Exercise Argo CD cache recovery without contacting Kubernetes."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CacheRecoveryTests(unittest.TestCase):
    def refresh(self, status):
        script = '''
source "$1"
log() { :; }
autoscaling_kubectl() {
  if [[ "$3" == get ]]; then
    cat "$FIXTURE"
  elif [[ "$3" == annotate && "$6" == argocd.argoproj.io/refresh=hard && "$7" == --overwrite ]]; then
    return 0
  else
    return 1
  fi
}
FIXTURE="$2"
autoscaling_refresh_completed_crd_sync keda
'''
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "application.json"
            fixture.write_text(json.dumps({"status": status}))
            return subprocess.run(["bash", "-c", script, "test",
                                   str(ROOT / "scripts/lib/autoscaling-guards.sh"), str(fixture)],
                                  universal_newlines=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def completed(self):
        return {"sync": {"status": "OutOfSync"}, "health": {"status": "Healthy"},
                "operationState": {"phase": "Succeeded"}, "resources": [
                    {"kind": "CustomResourceDefinition", "status": "OutOfSync"}]}

    def test_completed_crd_sync_requests_refresh(self):
        self.assertEqual(self.refresh(self.completed()).returncode, 0)

    def test_running_or_failed_sync_is_not_refreshed(self):
        for phase in ("Running", "Failed"):
            status = self.completed()
            status["operationState"]["phase"] = phase
            self.assertNotEqual(self.refresh(status).returncode, 0)

    def test_workload_drift_or_error_is_not_refreshed(self):
        status = self.completed()
        status["resources"].append({"kind": "Deployment", "status": "OutOfSync"})
        self.assertNotEqual(self.refresh(status).returncode, 0)
        status = self.completed()
        status["conditions"] = [{"type": "ComparisonError"}]
        self.assertNotEqual(self.refresh(status).returncode, 0)

    def test_synced_application_needs_no_refresh(self):
        status = self.completed()
        status["sync"]["status"] = "Synced"
        self.assertNotEqual(self.refresh(status).returncode, 0)


if __name__ == "__main__":
    unittest.main()
