"""Unit tests for bin/sendmail-shim against tests/lib/fakeservers.FakeSMTP.

The shim is copied with RELAY_HOST/RELAY_PORT rewritten the same way
scripts/install-sendmail-shim.sh does it, then run as a real process.
"""
import os, re, subprocess, sys, tempfile, unittest, socket

sys.dont_write_bytecode = True     # keep bin/ and tests/ free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tests", "lib"))
from fakeservers import FakeSMTP                     # noqa: E402

SHIM = os.path.join(ROOT, "bin", "sendmail-shim")

MSG = (b"From: Me <me@example.org>\n"
       b"To: a@example.org, B <b@example.org>\n"
       b"Cc: c@example.org\n"
       b"Bcc: secret@example.org\n"
       b"Subject: hi\n\nbody\n")


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close()
    return p


class ShimTest(unittest.TestCase):

    def shim_for(self, port):
        with open(SHIM) as f:
            src = f.read()
        src = re.sub(r'(?m)^RELAY_HOST = .*$', 'RELAY_HOST = "127.0.0.1"', src)
        src = re.sub(r'(?m)^RELAY_PORT = .*$', 'RELAY_PORT = %d' % port, src)
        fd, p = tempfile.mkstemp(suffix="-shim")
        with os.fdopen(fd, "w") as f:
            f.write(src)
        self.addCleanup(os.remove, p)
        return p

    def send(self, port, stdin, *args):
        return subprocess.run([sys.executable, self.shim_for(port)] + list(args),
                              input=stdin, capture_output=True)

    def test_explicit_recipients(self):
        with FakeSMTP() as s:
            r = self.send(s.port, MSG, "-oi", "x@example.org")
        self.assertEqual(r.returncode, 0, r.stderr)
        frm, rcpts, data = s.messages[0]
        self.assertEqual((frm, rcpts), ("me@example.org", ["x@example.org"]))
        self.assertIn(b"Subject: hi", data)

    def test_t_reads_to_cc_bcc_and_strips_bcc(self):
        with FakeSMTP() as s:
            r = self.send(s.port, MSG, "-t")
        self.assertEqual(r.returncode, 0, r.stderr)
        _, rcpts, data = s.messages[0]
        self.assertEqual(sorted(rcpts), ["a@example.org", "b@example.org",
                                         "c@example.org", "secret@example.org"])
        self.assertNotIn(b"Bcc:", data)
        self.assertNotIn(b"secret@example.org", data)

    def test_f_sets_envelope_sender(self):
        with FakeSMTP() as s:
            self.send(s.port, MSG, "-f", "bounce@example.org", "x@example.org")
        self.assertEqual(s.messages[0][0], "bounce@example.org")

    def test_no_from_header_falls_back_to_root(self):
        with FakeSMTP() as s:
            self.send(s.port, b"To: a@example.org\nSubject: s\n\nb\n", "-t")
        self.assertEqual(s.messages[0][0], "root@localhost")

    def test_no_recipients_is_ex_nouser(self):
        with FakeSMTP() as s:
            r = self.send(s.port, b"Subject: s\n\nb\n")
        self.assertEqual(r.returncode, 66)
        self.assertEqual(s.messages, [])

    def test_empty_input_sends_nothing(self):
        with FakeSMTP() as s:
            r = self.send(s.port, b"", "x@example.org")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(s.messages, [])

    def test_relay_down_is_ex_oserr(self):
        r = self.send(free_port(), MSG, "x@example.org")
        self.assertEqual(r.returncode, 71)
        self.assertIn(b"SMTP Error", r.stderr)


if __name__ == "__main__":
    unittest.main()
