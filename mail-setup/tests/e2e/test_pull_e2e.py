"""End-to-end: configure a puller with the real script, then pull over TLS.

For each puller the chain under test is the one a user gets:

    scripts/configure-*.sh  ->  ~/bin/mail-pull  ->  pop-pull | getmail
        -> POP3S (real TLS, cert verified)  ->  MDA  ->  mailbox

The only fakes are the far ends: a local POP3S server (tests/lib/fakeservers,
with a throwaway self-signed cert from openssl) and a fake MDA that appends to
a file.  Everything runs in a temporary $HOME.  Needs openssl; the getmail
cases also need getmail on $PATH (skipped otherwise).
"""
import os, re, shutil, subprocess, sys, tempfile, textwrap, unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tests", "lib"))
from fakeservers import FakePOP3, self_signed_cert, server_context   # noqa: E402

USER, PASSWORD = "me@example.org", "e2e:pa ss"
MSGS = [b"From: a@example.org\r\nSubject: e2e one\r\n\r\nfirst\r\n",
        b"From: b@example.org\r\nSubject: e2e two\r\n\r\nsecond\r\n.dot line\r\n"]


class PullE2E(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.certdir = tempfile.mkdtemp()
        pair = self_signed_cert(cls.certdir)
        if not pair:
            raise unittest.SkipTest("openssl not available - can't make a test cert")
        cls.cert, cls.key = pair

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.certdir, ignore_errors=True)

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(self.home, "bin"))
        self.box = os.path.join(self.tmp, "delivered")
        self.mda = os.path.join(self.tmp, "mda")
        with open(self.mda, "w") as f:
            f.write("#!/bin/sh\n{ echo 'From e2e'; cat; } >> '%s'\n" % self.box)
        os.chmod(self.mda, 0o755)
        self.pw = os.path.join(self.tmp, "sasl_passwd")
        with open(self.pw, "w") as f:
            f.write("[smtp.example.org]:587 %s:%s\n" % (USER, PASSWORD))
        self.env = dict(os.environ, HOME=self.home, MAIL_SETUP_MDA=self.mda,
                        MAIL_SETUP_SUDO="",
                        PATH=os.path.join(self.home, "bin") + os.pathsep + os.environ["PATH"])

    def sh(self, *argv, check=True):
        r = subprocess.run(list(argv), env=self.env, capture_output=True, text=True, timeout=120)
        if check and r.returncode != 0:
            self.fail("%s -> %d\n%s%s" % (argv, r.returncode, r.stdout, r.stderr))
        return r

    def delivered(self):
        try:
            with open(self.box, "rb") as f:
                return f.read()
        except OSError:
            return b""

    def edit(self, path, pairs):
        with open(path) as f:
            s = f.read()
        for pat, rep in pairs:
            s, n = re.subn(pat, rep, s, flags=re.M)
            self.assertTrue(n, "no %r in %s" % (pat, path))
        with open(path, "w") as f:
            f.write(s)

    def server(self, **kw):
        return FakePOP3(list(MSGS), user=USER, password=PASSWORD,
                        ssl_context=server_context(self.cert, self.key), **kw)

    # ------------------------------------------------------------------
    # pop-pull
    # ------------------------------------------------------------------
    def configure_pop_pull(self, port, *extra, cafile=None):
        self.sh(os.path.join(ROOT, "scripts", "configure-mail-pull.sh"),
                "--pwfile", self.pw, "--pop-user", USER, *extra)
        cfg = os.path.join(self.home, ".config", "mailpull.conf")
        self.edit(cfg, [(r"^server .*$", "server     = localhost"),
                        (r"^port .*$", "port       = %d" % port),
                        (r"^cafile .*$", "cafile     = %s" % (cafile or ""))])

    def test_pop_pull_keep(self):
        with self.server() as s:
            self.configure_pop_pull(s.port, cafile=self.cert)
            r = self.sh("mail-pull", "-v")
            self.assertIn("2 new message(s)", r.stdout)
            box = self.delivered()
            self.assertIn(b"Subject: e2e one", box)
            self.assertIn(b"\r\n.dot line\r\n", box)
            r = self.sh("mail-pull", check=False)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertIn("no new mail", r.stdout)
            self.assertEqual(self.delivered(), box)
            self.assertEqual(s.deleted, set())

    def test_pop_pull_delete(self):
        with self.server() as s:
            self.configure_pop_pull(s.port, "--delete", cafile=self.cert)
            self.sh("mail-pull")
            self.assertEqual(s.deleted, {1, 2})

    def test_pop_pull_rejects_untrusted_cert(self):
        with self.server() as s:
            self.configure_pop_pull(s.port)                  # no cafile: system CAs only
            r = self.sh("mail-pull", check=False)
            self.assertEqual(r.returncode, 2)
            self.assertRegex(r.stderr, r"(?i)certificate|ssl")
            self.assertEqual(s.logins, 0)                     # never sent the password
        self.assertEqual(self.delivered(), b"")

    def test_pop_pull_no_verify(self):
        with self.server() as s:
            self.configure_pop_pull(s.port, "--no-verify")
            self.sh("mail-pull")
        self.assertIn(b"Subject: e2e two", self.delivered())

    # ------------------------------------------------------------------
    # getmail
    # ------------------------------------------------------------------
    def configure_getmail(self, port, *extra):
        if not shutil.which("getmail"):
            self.skipTest("getmail not installed")
        self.sh(os.path.join(ROOT, "scripts", "configure-getmail.sh"),
                "--pwfile", self.pw, "--user", USER, *extra)
        rc = os.path.join(self.home, ".config", "getmail", "getmailrc")
        self.edit(rc, [(r"^server = .*$", "server = localhost"),
                       (r"^port = .*$", "port = %d\nssl_ca_certs = %s" % (port, self.cert))])

    def test_getmail_keep(self):
        with self.server() as s:
            self.configure_getmail(s.port)
            self.sh("mail-pull", "-v")
            box = self.delivered()
            self.assertIn(b"Subject: e2e one", box)
            self.assertIn(b"Subject: e2e two", box)
            self.sh("mail-pull")                              # remembered: no dupes
            self.assertEqual(self.delivered().count(b"Subject: e2e"), 2)
            self.assertEqual(s.deleted, set())

    def test_getmail_delete(self):
        with self.server() as s:
            self.configure_getmail(s.port, "--delete")
            self.sh("mail-pull")
            self.assertEqual(s.deleted, {1, 2})

    def test_getmail_password_comes_from_sasl_passwd(self):
        with self.server() as s:
            self.configure_getmail(s.port)
            with open(self.pw, "w") as f:                     # wrong password now
                f.write("[x]:587 %s:nope\n" % USER)
            r = self.sh("mail-pull", check=False)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(s.logins, 0)
        self.assertEqual(self.delivered(), b"")


if __name__ == "__main__":
    unittest.main()
