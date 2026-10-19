"""Unit tests for tests/live/check-plus-addressing.py (the opt-in live probe).

Run against the in-process fake SMTP/POP3/IMAP servers over plain connections
(--no-tls --no-auth), so nothing leaves the machine.  FakeIMAP(smtp=...) acts
like a cPanel host: mail for cwp+TAG@ is filed in the folder <prefix>TAG.
"""
import io, os, sys, tempfile, unittest, contextlib
import importlib.util
from importlib.machinery import SourceFileLoader
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tests", "lib"))
from fakeservers import FakePOP3, FakeSMTP, FakeIMAP       # noqa: E402

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

    def run_probe(self, smtp, pop, imap=None, *extra):
        argv = ["probe", "--pwfile", self.pw, "--user", "cwp@u-l.ca", "--tag", "chris",
                "--token", TOKEN, "--wait", "0", "--no-tls", "--no-auth",
                "--smtp-host", "127.0.0.1", "--smtp-port", str(smtp.port),
                "--pop-host", "127.0.0.1", "--pop-port", str(pop.port)]
        argv += ["--imap-host", "127.0.0.1", "--imap-port", str(imap.port)] if imap else ["--no-imap"]
        argv += list(extra)
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

    def servers(self, pop_msgs=(), folders=None, **imap_kw):
        """started fakes: (smtp, pop, imap), the IMAP one wired to the SMTP one"""
        stack = contextlib.ExitStack()
        smtp = stack.enter_context(FakeSMTP())
        pop = stack.enter_context(FakePOP3(list(pop_msgs), user="cwp@u-l.ca", password="pa:ss"))
        imap = stack.enter_context(FakeIMAP(folders, user="cwp@u-l.ca", password="pa:ss", smtp=smtp, **imap_kw))
        self.addCleanup(stack.close)
        return smtp, pop, imap

    # ---- POP only -----------------------------------------------------
    def test_pop_inbox_all_good(self):
        smtp, pop, _ = self.servers([probe_msg("To: cwp+chris@u-l.ca\r\n")])
        code, out, err = self.run_probe(smtp, pop)
        self.assertEqual(code, 0, out + err)
        self.assertEqual(smtp.messages[0][0], "cwp+chris@u-l.ca")      # envelope sender
        self.assertEqual(smtp.messages[0][1], ["cwp+chris@u-l.ca"])
        self.assertIn("PASS  1.", out)
        self.assertIn("PASS  2.", out); self.assertIn("inbox (via POP3)", out)
        self.assertIn("PASS  3. a header names the tagged address: To", out)
        self.assertIn("pop-pull --plus-base cwp@u-l.ca works", out)
        self.assertEqual(pop.deleted, {1})                              # probe cleaned up

    def test_keep_leaves_the_probe(self):
        smtp, pop, _ = self.servers([probe_msg("Delivered-To: cwp+chris@u-l.ca\r\n")])
        code, out, _ = self.run_probe(smtp, pop, None, "--keep")
        self.assertEqual(code, 0)
        self.assertIn("header names the tagged address: Delivered-To", out)
        self.assertEqual(pop.deleted, set())

    def test_delivered_but_no_header_names_the_tag(self):
        smtp, pop, _ = self.servers([probe_msg("To: cwp@u-l.ca\r\n")])
        code, out, _ = self.run_probe(smtp, pop)
        self.assertEqual(code, 1)
        self.assertIn("PASS  2.", out)
        self.assertIn("FAIL  3.", out)

    def test_never_delivered(self):
        smtp, pop, imap = self.servers([])
        code, out, _ = self.run_probe(smtp, pop)
        self.assertEqual(code, 1)
        self.assertIn("FAIL  2.", out)

    # ---- cPanel-style: tag folders over IMAP ---------------------------
    def test_cpanel_folder_is_found_reported_and_cleaned_up(self):
        smtp, pop, imap = self.servers([])
        code, out, err = self.run_probe(smtp, pop, imap)
        self.assertEqual(code, 0, out + err)
        self.assertIn("PASS  2.", out); self.assertIn("IMAP folder INBOX.chris", out)
        self.assertIn("PASS  3. the folder name is the routing key: INBOX.chris  (prefix 'INBOX.')", out)
        self.assertIn("configure-getmail.sh --imap --plus-base cwp@u-l.ca", out)
        self.assertIn("--plus-prefix 'INBOX.'", out)
        self.assertIn("pop-pull and POP3 can't see tagged mail", out)
        self.assertEqual(imap.deleted_folders, ["INBOX.chris"])         # it created the folder -> removed it
        self.assertNotIn("INBOX.chris", imap.folders)
        self.assertIn("deleted the folder INBOX.chris the probe created", out)

    def test_existing_tag_folder_is_emptied_not_deleted(self):
        keep = b"From: x@y.org\r\nSubject: real mail\r\n\r\nhi\r\n"
        smtp, pop, imap = self.servers([], folders={"INBOX.chris": [keep]})
        code, out, _ = self.run_probe(smtp, pop, imap)
        self.assertEqual(code, 0, out)
        self.assertEqual(imap.deleted_folders, [])
        self.assertEqual(imap.folders["INBOX.chris"], [keep])           # only the probe went
        self.assertNotIn("deleted the folder", out)

    def test_keep_leaves_probe_and_folder(self):
        smtp, pop, imap = self.servers([])
        code, out, _ = self.run_probe(smtp, pop, imap, "--keep")
        self.assertEqual(code, 0, out)
        self.assertEqual(imap.deleted_folders, [])
        self.assertEqual(len(imap.folders["INBOX.chris"]), 1)

    def test_other_separator_and_prefix(self):
        smtp, pop, imap = self.servers([], delimiter="/", prefix="INBOX/")
        code, out, _ = self.run_probe(smtp, pop, imap)
        self.assertEqual(code, 0, out)
        self.assertIn("(prefix 'INBOX/')", out)
        self.assertIn("--plus-prefix 'INBOX/'", out)

    def test_tag_in_imap_inbox_is_routed_by_header(self):
        smtp, pop, imap = self.servers([], plus_folders=False)           # host delivers everything to INBOX
        code, out, _ = self.run_probe(smtp, pop, imap)
        self.assertEqual(code, 0, out)
        self.assertIn("inbox (via IMAP)", out)
        self.assertIn("header names the tagged address: Delivered-To", out)
        self.assertIn("pop-pull --plus-base cwp@u-l.ca works", out)
        self.assertEqual(imap.folders["INBOX"], [])                      # cleaned up

    def test_imap_enabled_but_mail_is_in_the_pop_inbox(self):
        smtp, pop, imap = self.servers([probe_msg("To: cwp+chris@u-l.ca\r\n")], plus_folders=False)
        imap.smtp = None                                                 # IMAP side sees nothing
        code, out, _ = self.run_probe(smtp, pop, imap)
        self.assertEqual(code, 0, out)
        self.assertIn("inbox (via POP3)", out)

    def test_nowhere_with_imap_enabled(self):
        smtp, pop, imap = self.servers([])
        imap.smtp = None
        code, out, _ = self.run_probe(smtp, pop, imap)
        self.assertEqual(code, 1)
        self.assertIn("FAIL  2.", out)
        self.assertIn("POP/IMAP tag folders", out)

    def test_bad_arguments(self):
        smtp, pop, _ = self.servers([])
        code, _, err = self.run_probe(smtp, pop, None, "--base", "cwp+x@u-l.ca")
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


class FolderMatchTest(unittest.TestCase):
    def test_tag_folders(self):
        mod = load()
        folders = [("INBOX", "."), ("INBOX.chris", "."), ("INBOX.miche", "."), ("INBOX.Sent", "."),
                   ("chris", "."), ("INBOX.x.chris", ".")]
        self.assertEqual(mod.tag_folders(folders, "chris"), ["INBOX", "INBOX.chris", "chris", "INBOX.x.chris"])
        self.assertEqual(mod.tag_folders(folders, "bob"), ["INBOX"])

    def test_list_parsing(self):
        mod = load()
        self.assertIsNotNone(mod.LIST_RE.match('(\\HasNoChildren) "." "INBOX.test"'))
        self.assertIsNotNone(mod.LIST_RE.match('(\\HasNoChildren) "/" INBOX/test'))


if __name__ == "__main__":
    unittest.main()
