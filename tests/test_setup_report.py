"""Exercise setup.sh with stubbed network, installers and CLI; no real setup runs."""

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STUBS = r'''
curl() {
    case " $* " in
        *ipinfo.io*) printf '%s' "$TEST_IP_JSON"; return "${TEST_IP_EXIT:-0}" ;;
        *) printf '%s' "${TEST_METRICS-200 0.010 0.020 0.050 0.080}"; return "${TEST_PROBE_EXIT:-0}" ;;
    esac
}
readlink() { printf '%s\n' "${TEST_SYS_TZ-/var/db/timezone/zoneinfo/America/Los_Angeles}"; }
brew() { echo 'Unexpected package installation' >&2; return 99; }
tmux() { printf 'tmux test-version\n'; }
node() { printf 'v22.test\n'; }
claude() { printf '2.1.test (Claude Code)\n'; return "${TEST_CLI_EXIT:-0}"; }
setup_script="$1"
shift
source "$setup_script" "$@"
'''


class SetupReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="setup-report-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.report = self.directory / "report.txt"
        original = (ROOT / "setup.sh").read_text()
        assignment = "REPORT_PATH=/tmp/claude-remote-report.txt"
        self.assertEqual(original.count(assignment), 1)
        self.script = self.directory / "setup.sh"
        self.script.write_text(original.replace(assignment, "REPORT_PATH=" + str(self.report)))

    def run_setup(self, args=("--report",), data=None, **overrides):
        env = os.environ.copy()
        env["TEST_IP_JSON"] = json.dumps(data if data is not None else {
            "ip": "203.0.113.42", "org": "AS64500 Example Network",
            "timezone": "America/Los_Angeles", "city": "PrivateCity",
            "region": "PrivateRegion", "country": "US",
        })
        env.update(overrides)
        result = subprocess.run(["bash", "-c", STUBS, "setup-test", str(self.script), *args],
                                env=env, text=True, capture_output=True, timeout=15)
        self.assertNotIn("Unexpected package installation", result.stderr)
        return result

    def test_redaction_fields_plain_text_and_permissions(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = self.report.read_text()
        self.assertIn("Egress IP (redacted): 203.0.x.x", report)
        for value in ("AS64500 Example Network", "System time zone: America/Los_Angeles",
                      "IP time zone: America/Los_Angeles", "Time zone match: Match",
                      "HTTP status: 200", "DNS time (s): 0.010", "TCP connect time (s): 0.020",
                      "TLS handshake time (s): 0.050", "Total probe time (s): 0.080", "2.1.test"):
            self.assertIn(value, report)
        for value in ("203.0.113.42", "PrivateCity", "PrivateRegion", str(Path.home()), "\x1b"):
            self.assertNotIn(value, report)
        self.assertIn("203.0.113.42", result.stdout)
        self.assertIn(str(self.report), result.stdout)
        self.assertEqual(stat.S_IMODE(self.report.stat().st_mode), 0o600)

    def test_optional_report_and_help(self):
        self.assertEqual(self.run_setup(args=()).returncode, 0)
        self.assertFalse(self.report.exists())
        self.assertEqual(self.run_setup(args=("--help",)).returncode, 0)
        self.assertFalse(self.report.exists())
        self.assertEqual(self.run_setup(args=("--unknown",)).returncode, 2)

    def test_mismatch_and_missing_time_zone(self):
        for zone, expected in (("Asia/Shanghai", "Mismatch"), (None, "Unknown")):
            data = {"ip": "203.0.113.42", "org": "AS64500 Example Network"}
            if zone is not None:
                data["timezone"] = zone
            self.assertEqual(self.run_setup(data=data).returncode, 0)
            self.assertIn("Time zone match: " + expected, self.report.read_text())

    def test_missing_system_zone(self):
        self.assertEqual(self.run_setup(TEST_SYS_TZ="").returncode, 0)
        self.assertIn("Time zone match: Unknown", self.report.read_text())

    def test_null_or_malformed_json_is_not_a_timezone_match(self):
        for payload in ('{"ip": null, "org": null, "timezone": null}', 'not json'):
            self.assertEqual(self.run_setup(TEST_IP_JSON=payload).returncode, 0)
            report = self.report.read_text()
            self.assertIn("Time zone match: Unknown", report)
            self.assertIn("ASN / Organization: Unknown", report)

    def test_unavailable_network_and_cli(self):
        self.assertEqual(self.run_setup(TEST_IP_JSON="", TEST_IP_EXIT="6", TEST_METRICS="000 0 0 0 0",
                                        TEST_PROBE_EXIT="6", TEST_CLI_EXIT="1").returncode, 0)
        report = self.report.read_text()
        for value in ("Egress IP (redacted): Unknown", "ASN / Organization: Unknown",
                      "Time zone match: Unknown", "Probe status: Unavailable",
                      "Claude Code CLI version: Unavailable"):
            self.assertIn(value, report)

    def test_ipv6_and_invalid_ip_do_not_leak(self):
        for address, expected in (("2001:db8::1234", "[redacted IPv6]"), ("999.0.113.42", "Unknown"),
                                  ("invalid private value", "Unknown")):
            self.assertEqual(self.run_setup(data={"ip": address}).returncode, 0)
            report = self.report.read_text()
            self.assertNotIn(address, report)
            self.assertIn("Egress IP (redacted): " + expected, report)

    def test_existing_report_is_replaced_with_private_permissions(self):
        self.report.write_text("old report")
        self.report.chmod(0o644)
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertNotIn("old report", self.report.read_text())
        self.assertEqual(stat.S_IMODE(self.report.stat().st_mode), 0o600)

    def test_reject_symlink_and_directory_without_touching_target(self):
        target = self.directory / "keep.txt"
        target.write_text("keep me")
        self.report.symlink_to(target)
        self.assertEqual(self.run_setup().returncode, 1)
        self.assertEqual(target.read_text(), "keep me")
        self.assertTrue(self.report.is_symlink())
        self.report.unlink()
        self.report.mkdir()
        self.assertEqual(self.run_setup().returncode, 1)


if __name__ == "__main__":
    unittest.main()
