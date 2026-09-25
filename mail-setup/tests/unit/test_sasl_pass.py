"""Unit tests for bin/sasl-pass (getmail's password_command)."""
import os, subprocess, sys, tempfile, unittest

sys.dont_write_bytecode = True     # keep bin/ and tests/ free of __pycache__
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SASL_PASS = os.path.join(ROOT, "bin", "sasl-pass")


def run(*args):
    return subprocess.run([sys.executable, SASL_PASS] + list(args),
                          capture_output=True, text=True)


class SaslPassTest(unittest.TestCase):

    def setUp(self):
        fd, self.pw = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write("# postfix sasl_passwd\n\n[smtp.example.org]:587  me@example.org:s3:cr3t\n"
                    "[other]:465 you@example.org:x\n")

    def test_prints_password(self):
        r = run("--file", self.pw, "me@example.org")
        self.assertEqual((r.returncode, r.stdout), (0, "s3:cr3t\n"))

    def test_second_entry(self):
        self.assertEqual(run("--file", self.pw, "you@example.org").stdout, "x\n")

    def test_unknown_login(self):
        r = run("--file", self.pw, "nobody@example.org")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stdout, "")
        self.assertIn("no password for nobody@example.org", r.stderr)

    def test_unreadable_file(self):
        r = run("--file", self.pw + ".missing", "me@example.org")
        self.assertEqual(r.returncode, 2)
        self.assertIn("cannot read", r.stderr)

    def test_login_required(self):
        self.assertNotEqual(run("--file", self.pw).returncode, 0)


if __name__ == "__main__":
    unittest.main()
