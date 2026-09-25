"""Unit tests for bin/pop-pull.

pop-pull is loaded as a module and its POP3_SSL is swapped for a plain POP3
connection to tests/lib/fakeservers.FakePOP3, so the real protocol code runs
without TLS.  (tests/e2e/test_pull_e2e.py covers the TLS path.)  Delivery goes
to a fake MDA that appends to a file.
"""
import io, os, sys, poplib, tempfile, textwrap, unittest, contextlib
import importlib.util
from importlib.machinery import SourceFileLoader
from unittest import mock

sys.dont_write_bytecode = True     # keep bin/ and tests/ free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tests", "lib"))
from fakeservers import FakePOP3                     # noqa: E402

POP_PULL = os.path.join(ROOT, "bin", "pop-pull")


def load():
    """bin/pop-pull as a fresh module (it has no .py suffix, hence the loader)."""
    loader = SourceFileLoader("pop_pull", POP_PULL)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("pop_pull", loader))
    loader.exec_module(mod)
    return mod


def msg(n, extra=""):
    return ("From: a@example.org\r\nSubject: test %d\r\n\r\nbody %d\r\n%s" % (n, n, extra)).encode()


class PopPullTest(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.mbox = os.path.join(self.tmp, "mbox")
        self.argsf = os.path.join(self.tmp, "mda-args")
        self.mda = self.script("mda", """
            import os, sys
            with open(os.environ["FAKE_MBOX"], "ab") as f:
                f.write(b"From fake\\n" + sys.stdin.buffer.read())
            with open(os.environ["FAKE_ARGS"], "a") as f:
                f.write(" ".join(sys.argv[1:]) + "\\n")
            """)
        self.pw = os.path.join(self.tmp, "sasl_passwd")
        with open(self.pw, "w") as f:
            f.write("# comment\n\n[pop.example.org]:587  me@example.org:pa:ss\n")
        self.env = mock.patch.dict(os.environ, {"FAKE_MBOX": self.mbox,
                                                "FAKE_ARGS": self.argsf})
        self.env.start()
        self.mod = load()
        self.mod.CFG = os.path.join(self.tmp, "mailpull.conf")
        self.mod.SEEN = os.path.join(self.tmp, "state", "mailpull.seen")

    def tearDown(self):
        self.env.stop()

    def script(self, name, body):
        p = os.path.join(self.tmp, name)
        with open(p, "w") as f:
            f.write("#!%s\n%s" % (sys.executable, textwrap.dedent(body)))
        os.chmod(p, 0o755)
        return p

    def config(self, keep=True, mda=None):
        with open(self.mod.CFG, "w") as f:
            f.write(textwrap.dedent("""\
                [mailpull]
                server     = pop.example.org
                port       = 995
                user       = me@example.org
                local_user = chris
                keep       = %s
                verify     = true
                cafile     =
                mda        = %s
                pwfile     = %s
                """ % ("true" if keep else "false", mda or self.mda, self.pw)))

    def run_pull(self, server, *argv):
        """-> (exit code, stdout, stderr)"""
        def connect(host, port, context=None, timeout=None):
            self.assertEqual((host, port), ("pop.example.org", 995))
            return poplib.POP3("127.0.0.1", server.port, timeout=5)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(self.mod.poplib, "POP3_SSL", connect), \
             mock.patch.object(sys, "argv", ["pop-pull"] + list(argv)), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                self.mod.main()
                code = 0
            except SystemExit as e:
                code = e.code
        return code, out.getvalue(), err.getvalue()

    def delivered(self):
        if not os.path.exists(self.mbox):
            return b""
        with open(self.mbox, "rb") as f:
            return f.read()

    # ------------------------------------------------------------------
    def test_keep_mode_delivers_then_remembers(self):
        self.config(keep=True)
        with FakePOP3([msg(1), msg(2)], user="me@example.org", password="pa:ss") as s:
            code, out, _ = self.run_pull(s, "-v")
            self.assertEqual(code, 0)
            self.assertIn("2 new message(s) -> /var/mail/chris", out)
            box = self.delivered()
            self.assertIn(b"Subject: test 1", box)
            self.assertIn(b"Subject: test 2", box)
            with open(self.argsf) as f:
                self.assertEqual(f.read().split("\n")[0], "-oi -- chris")
            with open(self.mod.SEEN) as f:
                self.assertEqual(f.read().split(), ["uid-1", "uid-2"])
            self.assertEqual(s.deleted, set())

            code, out, _ = self.run_pull(s)        # nothing new second time
            self.assertEqual(code, 1)
            self.assertIn("no new mail", out)
            self.assertEqual(self.delivered(), box)

            s.messages.append(msg(3)); s.uids.append("uid-3")
            code, out, _ = self.run_pull(s)        # only the new one
            self.assertEqual(code, 0)
            self.assertIn("1 new message(s)", out)
            self.assertEqual(self.delivered().count(b"Subject: test"), 3)

    def test_delete_mode_deletes_and_keeps_no_state(self):
        self.config(keep=False)
        with FakePOP3([msg(1), msg(2)], user="me@example.org", password="pa:ss") as s:
            code, _, _ = self.run_pull(s)
            self.assertEqual(code, 0)
            self.assertEqual(s.deleted, {1, 2})
        self.assertFalse(os.path.exists(self.mod.SEEN))

    def test_dry_run_touches_nothing(self):
        self.config(keep=True)
        with FakePOP3([msg(1)], user="me@example.org", password="pa:ss") as s:
            code, out, _ = self.run_pull(s, "-n", "-v")
            self.assertEqual(code, 0)
            self.assertIn("[dry-run] msg 1 uid uid-1", out)
            self.assertIn("1 new message(s) would go to /var/mail/chris", out)
            self.assertEqual(s.deleted, set())
        self.assertEqual(self.delivered(), b"")
        self.assertFalse(os.path.exists(self.mod.SEEN))

    def test_dot_stuffed_lines_survive(self):
        self.config()
        with FakePOP3([msg(1, ".leading dot\r\n..two dots\r\n")],
                      user="me@example.org", password="pa:ss") as s:
            self.assertEqual(self.run_pull(s)[0], 0)
        box = self.delivered()
        self.assertIn(b"\r\n.leading dot\r\n", box)
        self.assertIn(b"\r\n..two dots\r\n", box)

    def test_bad_password_is_an_error(self):
        self.config()
        with FakePOP3([msg(1)], user="me@example.org", password="other") as s:
            code, _, err = self.run_pull(s)
        self.assertEqual(code, 2)
        self.assertIn("pop-pull:", err)
        self.assertEqual(self.delivered(), b"")

    def test_failed_delivery_is_not_marked_seen(self):
        bad = self.script("badmda", "import sys; sys.stdin.read(); sys.exit(75)\n")
        self.config(keep=True, mda=bad)
        with FakePOP3([msg(1)], user="me@example.org", password="pa:ss") as s:
            code, _, err = self.run_pull(s)
            self.assertIn("delivery failed on msg 1", err)
            self.assertNotEqual(code, 0)
        seen = []
        if os.path.exists(self.mod.SEEN):
            with open(self.mod.SEEN) as f:
                seen = f.read().split()
        self.assertNotIn("uid-1", seen)

    def test_missing_config(self):
        code, _, err = self.run_pull(None)
        self.assertEqual(code, 2)
        self.assertIn("missing config", err)


class PasswordTest(unittest.TestCase):

    def setUp(self):
        self.mod = load()
        fd, self.pw = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write("# c\n\nbroken-line\n[h]:587 a@b:x\n[h]:587 me@b:with:colons\n")

    def test_lookup(self):
        self.assertEqual(self.mod.password(self.pw, "a@b"), "x")
        self.assertEqual(self.mod.password(self.pw, "me@b"), "with:colons")

    def test_missing_login_exits_2(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as e:
            self.mod.password(self.pw, "nobody@b")
        self.assertEqual(e.exception.code, 2)

    def test_unreadable_file_exits_2(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as e:
            self.mod.password(self.pw + ".nope", "a@b")
        self.assertEqual(e.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
