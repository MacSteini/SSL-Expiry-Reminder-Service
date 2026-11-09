#!/usr/bin/env python3
"""Isolated end-to-end tests: synthetic certificates and fake external commands."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "SSL_Expiry_Reminder.sh"
BASH = os.environ.get("TEST_BASH", "bash")

MOCK = r"""#!/usr/bin/env python3
import fcntl, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ["MOCK_ROOT"])
def read(name, default):
    path = root / name
    return json.loads(path.read_text()) if path.exists() else default
def write(name, value):
    (root / name).write_text(json.dumps(value))
if name == "flock":
    fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX)
elif name == "openssl":
    print(pathlib.Path(sys.argv[sys.argv.index("-in") + 1]).read_text(), end="")
elif name == "date":
    print(sys.argv[2] if "-d" in sys.argv else "1000000")
elif name == "sendmail":
    if (root / "fail-mail").exists():
        sys.exit(1)
    messages = read("messages", [])
    messages.append(sys.stdin.read())
    write("messages", messages)
elif name == "systemctl":
    timers = read("timers", {})
    unit = sys.argv[-1].removesuffix(".timer")
    if sys.argv[1] == "is-active":
        sys.exit(0 if unit in timers else 3)
    if sys.argv[1] == "stop":
        timers.pop(unit, None)
        write("timers", timers)
    else:
        sys.exit(2)
elif name == "systemd-run":
    args = sys.argv[1:]
    interval = next(a.split("=", 1)[1] for a in args if a.startswith("--on-active="))
    unit = next(a.split("=", 1)[1] for a in args if a.startswith("--unit="))
    if interval == "invalid":
        sys.exit(1)
    timers = read("timers", {})
    if unit in timers:
        sys.exit(1)
    timers[unit] = {"interval": interval, "domain": args[-2], "unit": args[-1]}
    write("timers", timers)
else:
    sys.exit(2)
"""


class FollowUps(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ssl-reminder-test-")
        self.root = Path(self.tmp.name)
        self.certs = self.root / "certs"
        self.certs.mkdir()
        self.state = self.root / "state"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = self.bin / "mock"
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for name in (
            "flock",
            "openssl",
            "date",
            "sendmail",
            "systemctl",
            "systemd-run",
        ):
            (self.bin / name).symlink_to(mock)
        self.script = self.root / "reminder.sh"
        self.text = SOURCE.read_text()
        for old, new in (
            ("/var/lib/ssl-expiry-reminder", str(self.state)),
            ("/etc/letsencrypt/live", str(self.certs)),
            ("/usr/local/bin/SSL_Expiry_Reminder.sh", str(self.script)),
        ):
            self.assertEqual(self.text.count(old), 1)
            self.text = self.text.replace(old, new)
        self.env = dict(
            os.environ,
            MOCK_ROOT=str(self.root),
            PATH=f"{self.bin}:{os.environ['PATH']}",
        )
        self.save()

    def tearDown(self):
        self.tmp.cleanup()

    def save(self):
        self.script.write_text(self.text)

    def config(self, old, new):
        self.assertIn(old, self.text)
        self.text = self.text.replace(old, new)
        self.save()

    def cert(self, domain, fingerprint="A", expires=1086400):
        folder = self.certs / domain
        folder.mkdir(exist_ok=True)
        (folder / "fullchain.pem").write_text(
            f"notAfter={expires}\nsha256 Fingerprint={fingerprint}\n"
        )

    def data(self, name, default):
        file = self.root / name
        return json.loads(file.read_text()) if file.exists() else default

    def run_script(self, *args, expected=0):
        result = subprocess.run(
            [BASH, str(self.script), *args],
            env=self.env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, expected, result.stderr)
        return result

    def timers(self):
        return self.data("timers", {})

    def messages(self):
        return self.data("messages", [])

    def fire(self, domain):
        timers = self.timers()
        unit, info = next(
            (unit, info) for unit, info in timers.items() if info["domain"] == domain
        )
        del timers[unit]
        (self.root / "timers").write_text(json.dumps(timers))
        self.run_script("--follow-up", domain, unit)
        return unit

    def test_independent_intervals_daily_scan_and_stale_callback(self):
        self.cert("yourdomain1.com")
        self.cert("other.example")
        self.run_script()
        self.assertEqual(len(self.messages()), 3)  # domain override adds a recipient
        self.assertEqual(
            {t["domain"]: t["interval"] for t in self.timers().values()},
            {"yourdomain1.com": "11h", "other.example": "24h"},
        )
        original = self.timers().copy()
        self.run_script()
        self.assertEqual(len(self.messages()), 3)
        self.assertEqual(self.timers(), original)
        stale = self.fire("yourdomain1.com")
        self.assertEqual(len(self.messages()), 5)
        self.assertEqual(len(self.timers()), 2)
        self.run_script("--follow-up", "yourdomain1.com", stale)
        self.assertEqual(len(self.messages()), 5)
        self.run_script()
        self.assertEqual(len(self.messages()), 5)

    def test_empty_master_and_empty_domain_override(self):
        self.config('MASTER_FOLLOW_UP_INTERVAL="24h"', 'MASTER_FOLLOW_UP_INTERVAL=""')
        self.config(
            'FOLLOW_UP_INTERVALS["yourdomain2.com"]="24h"',
            'FOLLOW_UP_INTERVALS["yourdomain2.com"]=""',
        )
        for domain in ("yourdomain1.com", "yourdomain2.com", "other.example"):
            self.cert(domain)
        self.run_script()
        self.assertEqual(
            {t["domain"]: t["interval"] for t in self.timers().values()},
            {"yourdomain1.com": "11h"},
        )
        count = len(self.messages())
        self.run_script()
        self.assertEqual(len(self.messages()), count)

    def test_disabling_and_changing_interval_cancels_existing_timer(self):
        self.cert("yourdomain1.com")
        self.run_script()
        old = next(iter(self.timers()))
        self.config(
            'FOLLOW_UP_INTERVALS["yourdomain1.com"]="11h"',
            'FOLLOW_UP_INTERVALS["yourdomain1.com"]=""',
        )
        self.run_script()
        self.assertEqual(self.timers(), {})
        self.run_script("--follow-up", "yourdomain1.com", old)
        self.assertEqual(len(self.messages()), 2)
        self.config(
            'FOLLOW_UP_INTERVALS["yourdomain1.com"]=""',
            'FOLLOW_UP_INTERVALS["yourdomain1.com"]="48h"',
        )
        self.run_script()
        self.assertEqual([t["interval"] for t in self.timers().values()], ["48h"])
        self.assertEqual(len(self.messages()), 2)

    def test_renewal_removal_and_recovery_of_missing_timer(self):
        self.cert("other.example")
        self.run_script()
        (self.root / "timers").write_text("{}")  # reboot loses transient timers
        self.run_script()
        self.assertEqual(len(self.messages()), 1)
        self.assertEqual(len(self.timers()), 1)
        self.cert("other.example", "NEW", 1000000 + 60 * 86400)
        self.run_script()
        self.assertEqual(self.timers(), {})
        self.cert("other.example", "NEW", 1086400)
        self.run_script()
        self.assertEqual(len(self.messages()), 2)
        (self.certs / "other.example" / "fullchain.pem").unlink()
        self.run_script()
        self.assertEqual(self.timers(), {})

    def test_simultaneous_scans_do_not_duplicate(self):
        self.cert("other.example")
        processes = [
            subprocess.Popen(
                [BASH, str(self.script)],
                env=self.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for _ in range(2)
        ]
        for process in processes:
            _, stderr = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(len(self.messages()), 1)
        self.assertEqual(len(self.timers()), 1)

    def test_failed_mail_and_interval_change_on_callback(self):
        self.cert("other.example")
        (self.root / "fail-mail").touch()
        self.run_script(expected=1)
        self.assertEqual(self.messages(), [])
        self.assertEqual(self.timers(), {})
        (self.root / "fail-mail").unlink()
        self.run_script()
        self.assertEqual(len(self.messages()), 1)
        old = next(iter(self.timers()))
        self.config(
            'MASTER_FOLLOW_UP_INTERVAL="24h"', 'MASTER_FOLLOW_UP_INTERVAL="48h"'
        )
        self.fire("other.example")
        self.assertEqual(len(self.messages()), 1)
        self.assertEqual([t["interval"] for t in self.timers().values()], ["48h"])
        self.run_script("--follow-up", "other.example", old)
        self.assertEqual(len(self.messages()), 1)

    def test_failed_schedule_is_reported_and_retried(self):
        self.config(
            'MASTER_FOLLOW_UP_INTERVAL="24h"', 'MASTER_FOLLOW_UP_INTERVAL="invalid"'
        )
        self.cert("other.example")
        self.run_script(expected=1)
        self.assertEqual(len(self.messages()), 1)
        self.assertEqual(self.timers(), {})
        self.config(
            'MASTER_FOLLOW_UP_INTERVAL="invalid"', 'MASTER_FOLLOW_UP_INTERVAL="24h"'
        )
        self.run_script()
        self.assertEqual(len(self.messages()), 1)
        self.assertEqual(len(self.timers()), 1)


if __name__ == "__main__":
    unittest.main()
