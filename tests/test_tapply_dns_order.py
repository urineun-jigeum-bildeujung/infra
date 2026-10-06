from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TapplyDnsOrderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "tapply.sh").read_text()

    def test_web_dns_helper_applies_dns_before_public_verification(self):
        start = self.source.index("reconcile_web_dns_and_verify() {")
        end = self.source.index("\n}\n", start)
        helper = self.source[start:end]

        self.assertLess(
            helper.index('apply_web_dns "${aws_region}"'),
            helper.index("verify_public_web"),
        )

    def test_full_apply_reconciles_web_dns_before_other_access_stages(self):
        start = self.source.index('log "[13/18] Web Ingress')
        end = self.source.index('\nelse\n  log "마무리만 실행:', start)
        full_apply = self.source[start:end]

        web_dns = full_apply.index('reconcile_web_dns_and_verify "${aws_region}"')
        management = full_apply.index("configure-management-access.sh")
        observability = full_apply.index("configure-observability-access.sh")

        self.assertLess(web_dns, management)
        self.assertLess(web_dns, observability)

    def test_finish_reconciles_web_dns_before_grafana(self):
        start = self.source.index('\nelse\n  log "마무리만 실행:')
        end = self.source.index('\nfi\nlog "Grafana 관리자 인증', start)
        finish = self.source[start:end]

        self.assertLess(
            finish.index('reconcile_web_dns_and_verify "${aws_region}"'),
            finish.index("configure-observability-access.sh"),
        )


if __name__ == "__main__":
    unittest.main()
