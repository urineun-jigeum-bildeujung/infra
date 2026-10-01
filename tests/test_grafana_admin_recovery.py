"""Verify authentication repair does not expose or replace existing credentials."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "grafana_admin", Path(__file__).resolve().parents[1] / "scripts/reconcile-grafana-admin.py")
admin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admin)


class AdminRecoveryTests(unittest.TestCase):
    def test_stable_admin_secret_name_is_used_by_default(self):
        self.assertEqual(admin.ADMIN_SECRET_NAME, "grafana-admin-credentials")

    def test_password_policy_accepts_ten_characters_and_rejects_nine(self):
        self.assertTrue(admin.credentials_are_valid("admin", "0123456789"))
        self.assertFalse(admin.credentials_are_valid("admin", "012345678"))
        self.assertFalse(admin.credentials_are_valid("admin", "0123456789\n"))

    def test_valid_authentication_does_not_reset_password(self):
        with patch.object(admin, "status", return_value=200), patch.object(admin, "run") as run:
            admin.reconcile("http://localhost", "admin", "existing-password")
        run.assert_not_called()

    def test_401_reconciles_existing_secret_through_stdin_and_verifies(self):
        with patch.object(admin, "status", side_effect=[401, 200]), patch.object(admin, "run") as run:
            admin.reconcile("http://localhost", "admin", "existing-password")
        args, input_data = run.call_args[0]
        self.assertNotIn("existing-password", " ".join(args))
        self.assertIn("--password-from-stdin", args)
        self.assertEqual(input_data, "existing-password\n")

    def test_server_errors_and_unknown_admin_do_not_reset_password(self):
        for code, user in ((500, "admin"), (401, "other-admin")):
            with patch.object(admin, "status", return_value=code), patch.object(admin, "run") as run:
                with self.assertRaises(RuntimeError):
                    admin.reconcile("http://localhost", user, "existing-password")
            run.assert_not_called()

    def test_failed_verification_blocks_completion(self):
        with patch.object(admin, "status", return_value=401), patch.object(admin, "run"), patch.object(admin.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "동기화 후 인증 실패"):
                admin.reconcile("http://localhost", "admin", "existing-password")

    def test_running_process_authentication_cache_is_retried(self):
        with patch.object(admin, "status", side_effect=[401, 401, 200]), \
                patch.object(admin, "run") as run, patch.object(admin.time, "sleep") as sleep:
            admin.reconcile("http://localhost", "admin", "existing-password")
        self.assertEqual(run.call_count, 1)
        sleep.assert_called_once_with(2)
