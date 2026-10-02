"""Check the replacement Bash implementation with synthetic credentials."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parent / "shell"))
from harness import run


class AdminRecoveryTests(unittest.TestCase):
    def test_preserved_credentials_follow_upstream_ten_character_policy(self):
        for user, password, valid in [("admin", "synthetic1", True),
                                      ("admin", "short", False),
                                      ("admin", "admin", False),
                                      ("admin", "synthetic1\n", False),
                                      ("", "synthetic1", False)]:
            result, _ = run('grafana_validate_credentials user password normalized',
                            {"user": user, "password": password})
            self.assertEqual(result.returncode == 0, valid, result.stderr)

    def reconcile(self, codes, user="admin"):
        body = '''GRAFANA_USER="USER"; GRAFANA_PASSWORD_FILE="$CASE_DIR/password"
grafana_status() { local code; code=$(head -1 codes); tail -n +2 codes >remaining; mv remaining codes; printf %s "$code"; }
sleep() { :; }
grafana_kube() { printf '%s\\n' "$*" >>calls; cat >stdin; }
grafana_reconcile'''.replace('"USER"', '"' + user + '"')
        return run(body, {"codes": '\n'.join(str(c) for c in codes) + '\n', "password": 'existing-password'}, ["scripts/reconcile-grafana-admin.sh"])

    def test_valid_authentication_does_not_reset_password(self):
        result, files = self.reconcile([200])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("calls", files)

    def test_401_reconciles_existing_secret_through_stdin_and_verifies(self):
        result, files = self.reconcile([401, 200])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("existing-password", files["calls"] + result.stdout + result.stderr)
        self.assertIn("--password-from-stdin", files["calls"])
        self.assertEqual(files["stdin"], "existing-password\n")

    def test_server_errors_and_unknown_admin_do_not_reset_password(self):
        for codes, user in [([500], "admin"), ([401], "other-admin")]:
            result, files = self.reconcile(codes, user)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("calls", files)

    def test_failed_verification_blocks_completion(self):
        result, _ = self.reconcile([401] * 16)
        self.assertNotEqual(result.returncode, 0)

    def test_running_process_authentication_cache_is_retried(self):
        result, files = self.reconcile([401, 401, 200])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(files["calls"].splitlines()), 1)
