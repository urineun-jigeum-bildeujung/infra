"""Check bounded recovery using synthetic Argo CD state, without AWS/Kubernetes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GitOpsRecoveryTests(unittest.TestCase):
    def recover(self, message=None, phase="Error", operation=None, server_ready=True):
        application = {
            "metadata": {"name": "dev-web"},
            "spec": {"project": "services", "syncPolicy": {
                "syncOptions": ["RespectIgnoreDifferences=true", "ServerSideApply=true"]}},
            "status": {"sync": {"status": "OutOfSync"}, "operationState": {
                "phase": phase, "message": message or
                "ComparisonError: failed to generate manifest for source 1: "
                "rpc error: code = DeadlineExceeded desc = context deadline exceeded"}},
            "operation": operation,
        }
        script = r'''
set -Eeuo pipefail
source "$1"
log() { :; }
gitops_kubectl() {
  if [[ "$1 $2" == 'get deployment' ]]; then
    printf '%s' "$SERVER"
  elif [[ "$1 $2" == 'get application' ]]; then
    printf '%s' "$APPLICATION"
  elif [[ "$1" == patch ]]; then
    printf '%s\n' "$9" >> "$CAPTURE"
  else return 1
  fi
}
for attempt in 1 2 3; do
  GITOPS_RECOVERY_LAST_ATTEMPT[dev-web]=0
  gitops_retry_repo_failure "$APPLICATIONS"
done
'''
        server = {"spec": {"replicas": 1}, "metadata": {"generation": 1},
                  "status": {"observedGeneration": 1,
                             "availableReplicas": 1 if server_ready else 0}}
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / "patches"
            env = dict(os.environ, APPLICATION=json.dumps(application),
                       APPLICATIONS=json.dumps({"items": [application]}),
                       SERVER=json.dumps(server), CAPTURE=str(capture))
            result = subprocess.run(["bash", "-c", script, "test",
                                     str(ROOT / "scripts/lib/gitops-recovery.sh")],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    universal_newlines=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return [json.loads(line) for line in capture.read_text().splitlines()] if capture.exists() else []

    def test_repo_timeout_retries_are_bounded_and_preserve_options(self):
        patches = self.recover()
        self.assertEqual(len(patches), 2)
        for patch in patches:
            sync = patch["operation"]["sync"]
            self.assertFalse(sync["prune"])
            self.assertEqual(set(sync["syncOptions"]), {
                "CreateNamespace=true", "RespectIgnoreDifferences=true", "ServerSideApply=true"})

    def test_configuration_failure_is_not_retried(self):
        self.assertEqual(self.recover(message="secret missing"), [])

    def test_active_sync_is_not_overwritten(self):
        self.assertEqual(self.recover(phase="Running"), [])
        self.assertEqual(self.recover(operation={"sync": {}}), [])

    def test_unavailable_repo_server_is_not_reloaded(self):
        self.assertEqual(self.recover(server_ready=False), [])


if __name__ == "__main__":
    unittest.main()
