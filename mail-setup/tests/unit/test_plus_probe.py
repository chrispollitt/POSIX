"""Unit tests for tests/live/check-plus-addressing.py (the opt-in live probe).

Run against the in-process fake SMTP/POP3 servers over plain connections
(--no-tls --no-auth), so nothing leaves the machine.
"""
import io, os, sys, tempfile, unittest, contextlib
import importlib.util
from importlib.machinery import SourceFileLoader
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tests", "lib"))
from fakeservers import FakePOP3, FakeSMTP           # noqa: E402

PROBE = os.path.join(ROOT, "tests", "live", "check-plus-addressing.py")
TOKEN = "tok123"


def load():
    loader = SourceFileLoader("plus_probe", PROBE)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("plus_probe", loader))
    loader.exec_module(mod)
    return mod


def probe_msg(extra_headers=""):
    return ("From: cwp+chris@u-l.ca\r\n%sSubject: plus-addressing probe %s\r\n\r\nbody\r\n"
            % (extra_headers, TOKEN)).encode()


class ProbeTest(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.pw = os.path.join(self.tmp, "sasl_passwd")
        with open(self.pw, "w") as f:
            f.write("[smtp.example.org]:587 cwp@u-l.ca:pa:ss\n")

    def run_probe(self, smtp, pop, *extra):
        argv = ["probe", "--pwfile", self.pw, "--user", "cwp@u-l.ca", "--tag", "chris",
                "--token", TOKEN, "--wait", "0", "--no-tls", "--no-auth",
                "--smtp-host", "127.0.0.1", "--smtp-port", str(smtp.port),
                "--pop-host", "127.0.0.1", "--pop-port", str(pop.port)] + list(extra)
        out, err = io.StringIO(), io.StringIO()
        mod = load()
        with mock.patch.object(sys, "argv", argv), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                mod.main()
                code = 0
            except SystemExit as e:
                code = e.code
        return code, out.getvalue(), err.getvalue()

    def test_all_good(self):
        with FakeSMTP() as smtp, FakePOP3([probe_msg("To: cwp+chris@u-l.ca\r\n")],
                                          user="cwp@u-l.ca", password="pa:ss") as pop:
            code, out, err = self.run_probe(smtp, pop)
            self.assertEqual(code, 0, out + err)
            self.assertEqual(smtp.messages[0][0], "cwp+chris@u-l.ca")      # envelope sender
            self.assertEqual(smtp.messages[0][1], ["cwp+chris@u-l.ca"])
            self.assertIn("PASS  1.", out); self.assertIn("PASS  2.", out)
            self.assertIn("PASS  3. a header names the tagged address: To", out)
            self.assertEqual(pop.deleted, {1})                              # probe cleaned up

    def test_keep_leaves_the_probe(self):
        with FakeSMTP() as smtp, FakePOP3([probe_msg("Delivered-To: cwp+chris@u-l.ca\r\n")],
                                          user="cwp@u-l.ca", password="pa:ss") as pop:
            code, out, _ = self.run_probe(smtp, pop, "--keep")
            self.assertEqual(code, 0)
            self.assertIn("header names the tagged address: Delivered-To", out)
            self.assertEqual(pop.deleted, set())

    def test_delivered_but_no_header_names_the_tag(self):
        with FakeSMTP() as smtp, FakePOP3([probe_msg("To: cwp@u-l.ca\r\n")],
                                          user="cwp@u-l.ca", password="pa:ss") as pop:
            code, out, _ = self.run_probe(smtp, pop)
            self.assertEqual(code, 1)
            self.assertIn("PASS  2.", out)
            self.assertIn("FAIL  3.", out)

    def test_never_delivered(self):
        with FakeSMTP() as smtp, FakePOP3([], user="cwp@u-l.ca", password="pa:ss") as pop:
            code, out, _ = self.run_probe(smtp, pop)
            self.assertEqual(code, 1)
            self.assertIn("FAIL  2.", out)

    def test_bad_arguments(self):
        with FakeSMTP() as smtp, FakePOP3([], user="cwp@u-l.ca", password="pa:ss") as pop:
            code, _, err = self.run_probe(smtp, pop, "--base", "cwp+x@u-l.ca")
            self.assertEqual(code, 2)
            self.assertIn("--base must be a plain address", err)


class RelayFieldTest(unittest.TestCase):
    def test_relay_field(self):
        mod = load()
        fd, p = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write("Username: me@x.org\r\nIncoming Server: in.x.org\r\nSMTP Port: 465\r\n")
        self.assertEqual(mod.relay_field(p, "Username"), "me@x.org")
        self.assertEqual(mod.relay_field(p, "Incoming Server"), "in.x.org")
        self.assertEqual(mod.relay_field(p, "Nope"), "")


if __name__ == "__main__":
    unittest.main()
