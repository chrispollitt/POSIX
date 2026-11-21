#!/usr/bin/env python3
"""Tests for lists-setup's listlib, listserv and listctl.

Nothing here needs mlmmj, Postfix or root: the programs they call (mlmmj-sub, mlmmj-unsub, sendmail, postmap,
postfix) are small fakes written into a temp directory that keep their state in files, and every path comes from a
lists.conf in that directory.

    python3 tests/test_lists.py
"""
import email
import email.policy
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
BIN = HERE.parent / "bin"
sys.path.insert(0, str(BIN))
import listlib as L  # noqa: E402

PY = sys.executable

FAKE_SUB = '''#!%(py)s
import os, sys
a = sys.argv[1:]
d = a[a.index("-L") + 1]; addr = a[a.index("-a") + 1].lower()
kind = "digesters.d" if "-d" in a else "nomailsubs.d" if "-n" in a else "subscribers.d"
for k in ("subscribers.d", "digesters.d", "nomailsubs.d"):
    p = os.path.join(d, k)
    for f in os.listdir(p):
        fp = os.path.join(p, f)
        lines = [l for l in open(fp).read().split("\\n") if l and l != addr]
        open(fp, "w").write("".join(l + "\\n" for l in lines))
with open(os.path.join(d, kind, addr[0]), "a") as fh:
    fh.write(addr + "\\n")
'''
FAKE_UNSUB = '''#!%(py)s
import os, sys
a = sys.argv[1:]
d = a[a.index("-L") + 1]; addr = a[a.index("-a") + 1].lower()
for k in ("subscribers.d", "digesters.d", "nomailsubs.d"):
    p = os.path.join(d, k)
    for f in os.listdir(p):
        fp = os.path.join(p, f)
        lines = [l for l in open(fp).read().split("\\n") if l and l != addr]
        open(fp, "w").write("".join(l + "\\n" for l in lines))
'''
FAKE_SENDMAIL = '''#!%(py)s
import os, sys, time
out = os.environ["FAKE_OUTBOX"]
data = sys.stdin.buffer.read()
with open(os.path.join(out, "mail.%%d" %% time.time_ns()), "wb") as fh:
    fh.write(("ARGS: " + " ".join(sys.argv[1:]) + "\\n").encode() + data)
'''
FAKE_LOG = '''#!%(py)s
import os, sys
with open(os.environ["FAKE_CALLS"], "a") as fh:
    fh.write(os.path.basename(sys.argv[0]) + " " + " ".join(sys.argv[1:]) + "\\n")
'''


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lists-setup-"))
        self.bindir = self.tmp / "bin"
        self.outbox = self.tmp / "outbox"
        self.spool = self.tmp / "spool"
        self.skel = self.tmp / "skel" / "en"
        for d in (self.bindir, self.outbox, self.spool, self.skel):
            d.mkdir(parents=True)
        (self.skel / "subscribed").write_text("welcome text\n")
        for name, code in (("mlmmj-sub", FAKE_SUB), ("mlmmj-unsub", FAKE_UNSUB), ("sendmail", FAKE_SENDMAIL),
                           ("postmap", FAKE_LOG), ("postfix", FAKE_LOG)):
            p = self.bindir / name
            p.write_text(code % {"py": PY})
            p.chmod(p.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.calls = self.tmp / "calls.log"
        self.conf = self.tmp / "lists.conf"
        self.write_conf()
        self.env = dict(os.environ, LISTS_SETUP_CONF=str(self.conf), FAKE_OUTBOX=str(self.outbox),
                        FAKE_CALLS=str(self.calls))
        os.environ.update(LISTS_SETUP_CONF=str(self.conf), FAKE_OUTBOX=str(self.outbox), FAKE_CALLS=str(self.calls))
        self.cfg = L.load_config()

    def tearDown(self):
        import shutil
        for k in ("LISTS_SETUP_CONF", "FAKE_OUTBOX", "FAKE_CALLS"):
            os.environ.pop(k, None)
        shutil.rmtree(str(self.tmp), ignore_errors=True)

    def write_conf(self, extra=""):
        self.conf.write_text(
            "# test config\nDOMAIN = cpbee.cmnet\nSPOOL = %s\nSENDMAIL = %s\nMLMMJ_BIN = %s\nPOSTMAP = %s\nPOSTFIX = %s\n"
            "REMOVED = %s\nSKEL = %s\n%s" % (self.spool, self.bindir / "sendmail", self.bindir, self.bindir / "postmap",
                                             self.bindir / "postfix", self.tmp / "removed", self.tmp / "skel", extra))

    def make(self, name, **kw):
        return L.create_list(self.cfg, name, **kw)

    def run_script(self, script, *args, stdin=None):
        return subprocess.run([PY, str(BIN / script)] + list(args), input=stdin, capture_output=True, env=self.env,
                              timeout=60)

    def ctl(self, *args):
        return self.run_script("listctl", *args)

    def outgoing(self):
        """The mails the fake sendmail was given: [(args line, parsed message)]."""
        out = []
        for p in sorted(self.outbox.glob("mail.*")):
            raw = p.read_bytes()
            first, _, rest = raw.partition(b"\n")
            out.append((first.decode(), email.message_from_bytes(rest, policy=email.policy.default)))
        return out

    def calls_text(self):
        return self.calls.read_text() if self.calls.exists() else ""


def mail(body="", subject="", frm="chris@cpbee.cmnet", extra=""):
    return ("From: %s\nTo: listserv@cpbee.cmnet\nSubject: %s\nMessage-ID: <cmd1@cpbee.cmnet>\n%s\n%s\n"
            % (frm, subject, extra, body)).encode()


class TestLib(Base):
    def test_names(self):
        for ok in ("alpha", "lan-talk", "a.b", "x9", "a_b"):
            self.assertTrue(L.valid_name(ok), ok)
        for bad in ("", "Alpha", "-a", "a--b", "a b", "a+b", "listserv", "postmaster", "a/b", "../x", "a@b"):
            self.assertFalse(L.valid_name(bad), bad)

    def test_config_needs_a_domain_and_the_environment_wins(self):
        self.conf.write_text("SPOOL = /x\n")
        with self.assertRaises(L.ListError):
            L.load_config()
        self.write_conf()
        os.environ["LISTS_SETUP_DOMAIN"] = "other.lan"
        try:
            c = L.load_config()
            self.assertEqual((c["DOMAIN"], c["ADDRESS"]), ("other.lan", "listserv@other.lan"))
        finally:
            del os.environ["LISTS_SETUP_DOMAIN"]

    def test_create_makes_the_mlmmj_layout_and_control_files(self):
        L.create_list(self.cfg, "alpha", description="The  first\n list", owners=["chris@cpbee.cmnet"])
        d = self.spool / "alpha"
        for sub in L.LAYOUT:
            self.assertTrue((d / sub).is_dir(), sub)
        c = lambda k: (d / "control" / k).read_text()
        self.assertEqual(c("listaddress"), "alpha@cpbee.cmnet\n")
        self.assertEqual(c("owner"), "chris@cpbee.cmnet\n")
        self.assertEqual(c("description"), "The first list\n")
        self.assertEqual(c("prefix"), "[alpha]\n")
        self.assertEqual(c("customheaders"), "List-Id: <alpha.cpbee.cmnet>\n")
        self.assertEqual(c("digestinterval"), "86400\n")
        for flag in ("tocc", "closedlist", "subonlypost"):
            self.assertTrue((d / "control" / flag).exists(), flag)
        for absent in ("moderated", "closedlistsub", "noarchive"):
            self.assertFalse((d / "control" / absent).exists(), absent)
        self.assertEqual((d / "text" / "subscribed").read_text(), "welcome text\n")       # mlmmj's default texts

    def test_create_options_and_refusals(self):
        L.create_list(self.cfg, "beta", moderated=True, moderators=["m@x"], closed_sub=True, open_post=True, digest_interval=3600)
        c = lambda k: (self.spool / "beta" / "control" / k)
        self.assertTrue(c("moderated").exists() and c("closedlistsub").exists())
        self.assertFalse(c("subonlypost").exists())
        self.assertEqual(c("moderators").read_text(), "m@x\n")
        self.assertEqual(c("digestinterval").read_text(), "3600\n")
        with self.assertRaises(L.ListError):
            L.create_list(self.cfg, "beta")                                    # exists
        for bad in ("Beta", "listserv", "a b", "a--b"):
            with self.assertRaises(L.ListError):
                L.create_list(self.cfg, bad)

    def test_the_postfix_tables_follow_mlmmjs_readme(self):
        self.make("alpha")
        self.make("beta")
        v, t = L.map_text(self.cfg)
        self.assertIn("alpha@cpbee.cmnet", v)
        self.assertRegex(v, r"alpha@cpbee\.cmnet\s+cpbee\.cmnet--alpha@localhost\.mlmmj")
        self.assertRegex(v, r"listserv@cpbee\.cmnet\s+listserv@localhost\.mlmmj")
        self.assertRegex(t, r"cpbee\.cmnet--beta@localhost\.mlmmj\s+mlmmj:beta")
        self.assertRegex(t, r"listserv@localhost\.mlmmj\s+listserv:")

    def test_regenerate_writes_postmaps_and_reloads(self):
        self.make("alpha")
        L.regenerate_maps(self.cfg)
        self.assertTrue((self.spool / "virtual").exists() and (self.spool / "transport").exists())
        calls = self.calls_text().splitlines()
        self.assertEqual(calls, ["postmap %s" % (self.spool / "virtual"), "postmap %s" % (self.spool / "transport"),
                                 "postfix reload"])

    def test_remove_keeps_the_list_elsewhere(self):
        self.make("alpha")
        L.subscribe(self.cfg, "alpha", "a@x")
        where = L.remove_list(self.cfg, "alpha")
        self.assertFalse((self.spool / "alpha").exists())
        self.assertTrue(Path(where, "subscribers.d", "a").exists())
        self.assertEqual(L.list_names(self.cfg), [])

    def test_members_and_versions(self):
        self.make("alpha")
        L.subscribe(self.cfg, "alpha", "Bob@X.org")
        L.subscribe(self.cfg, "alpha", "amy@x.org", "digest")
        L.subscribe(self.cfg, "alpha", "cy@x.org", "nomail")
        self.assertEqual(L.members(self.cfg, "alpha"), ["bob@x.org"])
        self.assertEqual(L.membership(self.cfg, "alpha", "AMY@x.org"), "digest")
        self.assertEqual(L.membership(self.cfg, "alpha", "cy@x.org"), "nomail")
        L.subscribe(self.cfg, "alpha", "amy@x.org")                              # back to normal: moved, not doubled
        self.assertEqual(L.members(self.cfg, "alpha", "digesters.d"), [])
        L.unsubscribe(self.cfg, "alpha", "bob@x.org")
        self.assertIsNone(L.membership(self.cfg, "alpha", "bob@x.org"))

    def test_a_failing_mlmmj_tool_is_a_list_error(self):
        self.make("alpha")
        self.write_conf("MLMMJ_BIN = %s\n" % (self.tmp / "nowhere"))
        with self.assertRaises(L.ListError):
            L.subscribe(L.load_config(), "alpha", "a@x")


class TestListserv(Base):
    def setUp(self):
        super().setUp()
        self.make("alpha", description="the first list", owners=["boss@cpbee.cmnet"])
        self.make("beta", description="")

    def ask(self, body="", subject="", sender="chris@cpbee.cmnet", extra="", frm=None):
        p = self.run_script("listserv", "--sender", sender, stdin=mail(body, subject, frm or sender, extra))
        self.assertEqual(p.returncode, 0, p.stderr)
        out = self.outgoing()
        return out[-1][1] if out else None

    def text(self, msg):
        return msg.get_content()

    def test_list_answers_ok_then_name_and_description_lines(self):
        r = self.ask("LIST", "LIST")
        t = self.text(r).splitlines()
        self.assertEqual(t[0], "OK 2 lists")
        self.assertRegex(t[1], r"^alpha\s{2,}the first list$")
        self.assertRegex(t[2], r"^beta\s{2,}\(no description\)$")
        self.assertEqual(r["To"], "chris@cpbee.cmnet")
        self.assertEqual(r["From"], "List server <listserv@cpbee.cmnet>")
        self.assertEqual(r["In-Reply-To"], "<cmd1@cpbee.cmnet>")                    # what tvmail finds the answer by
        self.assertEqual(r["Subject"], "Re: LIST")
        self.assertEqual(r["Auto-Submitted"], "auto-replied")
        self.assertEqual(self.outgoing()[0][0], "ARGS: -i -f <> chris@cpbee.cmnet")   # a null envelope sender

    def test_subscribe_puts_the_sender_on_the_list(self):
        r = self.ask("SUBSCRIBE alpha Chris P", "SUBSCRIBE alpha Chris P")
        self.assertTrue(self.text(r).startswith("OK you are subscribed to alpha"))
        self.assertEqual(L.members(self.cfg, "alpha"), ["chris@cpbee.cmnet"])
        r = self.ask("SUBSCRIBE alpha")
        self.assertTrue(self.text(r).startswith("OK you are already on alpha (normal)"))

    def test_nobody_can_act_for_another_address(self):
        self.ask("SUBSCRIBE alpha bob@cpbee.cmnet")                                  # the argument is a name, not an address
        self.assertEqual(L.members(self.cfg, "alpha"), ["chris@cpbee.cmnet"])

    def test_signoff_set_and_review(self):
        self.ask("SUBSCRIBE alpha")
        self.assertTrue(self.text(self.ask("SET alpha DIGEST")).startswith("OK alpha: you get one digest mail"))
        self.assertEqual(L.membership(self.cfg, "alpha", "chris@cpbee.cmnet"), "digest")
        self.assertTrue(self.text(self.ask("SET alpha DIGEST")).startswith("OK alpha is already set so for you"))
        self.assertTrue(self.text(self.ask("SET alpha NODIGEST")).startswith("OK alpha: you get every message"))
        self.assertEqual(L.membership(self.cfg, "alpha", "chris@cpbee.cmnet"), "normal")
        self.assertTrue(self.text(self.ask("SET alpha WHAT")).startswith("ERROR SET alpha what?"))
        rev = self.text(self.ask("REVIEW alpha")).splitlines()
        self.assertEqual(rev, ["OK 1 member of alpha", "chris@cpbee.cmnet"])
        self.assertTrue(self.text(self.ask("REVIEW alpha", sender="stranger@x.org")).startswith("ERROR only members and owners"))
        self.assertTrue(self.text(self.ask("REVIEW alpha", sender="boss@cpbee.cmnet")).startswith("OK 1 member of alpha"))
        self.assertEqual(self.text(self.ask("SIGNOFF alpha")), "OK you are signed off from alpha\n")
        self.assertEqual(self.text(self.ask("SIGNOFF alpha")), "ERROR you are not subscribed to alpha\n")
        self.assertEqual(self.text(self.ask("UNSUBSCRIBE beta")), "ERROR you are not subscribed to beta\n")

    def test_errors_are_error_lines(self):
        self.assertEqual(self.text(self.ask("SUBSCRIBE nosuch")), "ERROR no such list: nosuch\n")
        self.assertEqual(self.text(self.ask("SUBSCRIBE")), "ERROR no such list: \n")
        self.assertTrue(self.text(self.ask("FROBNICATE alpha")).startswith("ERROR unknown command 'FROBNICATE'"))
        L.write_control(self.cfg, "beta", "closedlistsub")
        self.assertTrue(self.text(self.ask("SUBSCRIBE beta")).startswith("ERROR beta is closed to new members"))
        self.assertEqual(L.members(self.cfg, "beta"), [])
        L.write_control(self.cfg, "alpha", "submod")
        self.assertTrue(self.text(self.ask("SUBSCRIBE alpha")).startswith("ERROR joining alpha needs its owner's approval"))

    def test_info_and_help(self):
        t = self.text(self.ask("INFO alpha")).splitlines()
        self.assertEqual(t[0], "OK alpha <alpha@cpbee.cmnet>")
        self.assertIn("  owner: boss@cpbee.cmnet", t)
        self.assertIn("  who may post: members only", t)
        h = self.text(self.ask("HELP")).splitlines()
        self.assertTrue(h[0].startswith("OK commands") and any("SUBSCRIBE list" in x for x in h))

    def test_the_subject_is_the_command_when_the_text_has_none(self):
        self.assertTrue(self.text(self.ask("", "SUBSCRIBE alpha")).startswith("OK you are subscribed to alpha"))
        self.assertTrue(self.text(self.ask("", "")).startswith("OK commands"))            # nothing at all: HELP

    def test_text_lines_win_over_the_subject_and_quotes_and_signatures_are_skipped(self):
        body = "> SUBSCRIBE beta\n# a comment\n\nLIST\n-- \nSUBSCRIBE beta\n"
        r = self.ask(body, "SUBSCRIBE beta")
        self.assertTrue(self.text(r).startswith("OK 2 lists"))
        self.assertEqual(L.members(self.cfg, "beta"), [])

    def test_several_commands_get_one_answer_with_an_overall_verdict(self):
        t = self.text(self.ask("SUBSCRIBE alpha\nSUBSCRIBE beta\nSIGNOFF nosuch\n")).splitlines()
        self.assertEqual(t[0], "ERROR 1 of 3 commands failed")
        self.assertIn("> SUBSCRIBE alpha", t)
        self.assertIn("> SIGNOFF nosuch", t)
        self.assertIn("ERROR no such list: nosuch", t)
        self.assertEqual(len(self.outgoing()), 1)
        t = self.text(self.ask("LIST\nLIST\n")).splitlines()
        self.assertEqual(t[0], "OK 2 commands")

    def test_robots_bounces_and_lists_are_never_answered(self):
        cases = [dict(extra="Auto-Submitted: auto-replied\n"), dict(extra="Precedence: bulk\n"),
                 dict(extra="List-Id: <x.cpbee.cmnet>\n"), dict(extra="X-Loop: yes\n"),
                 dict(sender="mailer-daemon@cpbee.cmnet"), dict(sender="listserv@cpbee.cmnet"),
                 dict(sender="postmaster@cpbee.cmnet"), dict(sender="x@localhost.mlmmj"), dict(sender="not an address"),
                 dict(sender="<>", frm="")]
        for kw in cases:
            self.assertIsNone(self.ask("LIST", "LIST", **kw), kw)
        self.assertEqual(self.outgoing(), [])

    def test_the_sender_defaults_to_from(self):
        p = self.run_script("listserv", stdin=mail("LIST", "LIST", frm="Chris <chris@cpbee.cmnet>"))
        self.assertEqual(p.returncode, 0)
        self.assertEqual(self.outgoing()[0][1]["To"], "chris@cpbee.cmnet")

    def test_a_failing_sendmail_is_tempfail_so_postfix_tries_again(self):
        self.write_conf("SENDMAIL = %s\n" % (self.tmp / "no-sendmail"))
        p = self.run_script("listserv", "--sender", "chris@cpbee.cmnet", stdin=mail("LIST", "LIST"))
        self.assertEqual(p.returncode, 75)

    def test_dry_run_prints_the_answer_and_sends_nothing(self):
        p = self.run_script("listserv", "--sender", "chris@cpbee.cmnet", "--dry-run", stdin=mail("LIST", "LIST"))
        self.assertEqual(p.returncode, 0)
        self.assertIn("OK 2 lists", p.stdout.decode())
        self.assertEqual(self.outgoing(), [])

    def test_a_list_you_cannot_subscribe_to_when_the_tool_fails_is_an_error_line_not_a_crash(self):
        self.write_conf("MLMMJ_BIN = %s\n" % (self.tmp / "nowhere"))
        r = self.ask("SUBSCRIBE alpha")
        self.assertTrue(self.text(r).startswith("ERROR cannot run mlmmj-sub"))


class TestListctl(Base):
    def test_create_list_show_set_members_remove(self):
        p = self.ctl("create", "alpha", "--description", "The first", "--owner", "chris@cpbee.cmnet")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("created alpha <alpha@cpbee.cmnet>", p.stdout.decode())
        self.assertIn("postfix reload", self.calls_text())
        self.assertTrue((self.spool / "transport").exists())
        self.assertIn("alpha", self.ctl("list").stdout.decode())
        shown = self.ctl("show", "alpha").stdout.decode()
        self.assertIn("owners      : chris@cpbee.cmnet", shown)
        self.assertIn("posting     : members only", shown)
        self.assertIn("joining     : open", shown)
        for args in (("closed-sub", "on"), ("open-post", "on"), ("moderated", "on"), ("digest-interval", "7200"),
                     ("description", "New", "text"), ("owner", "a@x", "b@x")):
            self.assertEqual(self.ctl("set", "alpha", *args).returncode, 0, args)
        shown = self.ctl("show", "alpha").stdout.decode()
        for want in ("joining     : closed", "posting     : anyone; moderated by chris@cpbee.cmnet", "digest every: 7200 s",
                     "description : New text", "owners      : a@x, b@x"):
            self.assertIn(want, shown)
        self.ctl("set", "alpha", "closed-sub", "off")
        self.ctl("set", "alpha", "moderated", "off")
        self.assertFalse((self.spool / "alpha" / "control" / "closedlistsub").exists())
        self.assertFalse((self.spool / "alpha" / "control" / "moderated").exists())
        p = self.ctl("add", "alpha", "Bob@X.org", "amy@x.org", "--digest")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ctl("members", "alpha").stdout.decode().split("\n")[:-1], ["amy@x.org  (digest)", "bob@x.org  (digest)"])
        self.ctl("del", "alpha", "bob@x.org")
        self.assertEqual(self.ctl("members", "alpha").stdout.decode().strip(), "amy@x.org  (digest)")
        p = self.ctl("remove", "alpha")
        self.assertNotEqual(p.returncode, 0)                                        # needs --yes
        self.assertIn("add --yes", p.stderr.decode())
        self.assertTrue((self.spool / "alpha").exists())
        p = self.ctl("remove", "alpha", "--yes")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse((self.spool / "alpha").exists())
        self.assertNotIn("alpha", (self.spool / "virtual").read_text().replace("# lists-setup", ""))

    def test_errors_are_one_line_and_exit_1(self):
        for args in (("create", "Bad Name"), ("create", "listserv"), ("show", "nosuch"), ("set", "nosuch", "owner", "a@x"),
                     ("add", "nosuch", "a@x")):
            p = self.ctl(*args)
            self.assertEqual(p.returncode, 1, args)
            self.assertTrue(p.stderr.decode().startswith("listctl: "), p.stderr)
        self.ctl("create", "alpha")
        self.assertEqual(self.ctl("create", "alpha").returncode, 1)
        for args in (("set", "alpha", "bogus", "1"), ("set", "alpha", "moderated", "maybe"), ("set", "alpha", "digest-interval", "5"),
                     ("add", "alpha", "not-an-address")):
            self.assertEqual(self.ctl(*args).returncode, 1, args)

    def test_no_postfix_writes_the_tables_and_touches_nothing_else(self):
        p = self.ctl("--no-postfix", "create", "alpha")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue((self.spool / "transport").exists())
        self.assertEqual(self.calls_text(), "")

    def test_sync_rebuilds_from_what_is_on_disk(self):
        self.make("alpha")
        (self.spool / "virtual").write_text("junk\n")
        p = self.ctl("sync")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("alpha@cpbee.cmnet", (self.spool / "virtual").read_text())

    def test_end_to_end_a_list_made_by_listctl_is_one_listserv_answers_for(self):
        self.ctl("create", "gamma", "--description", "A list to join")
        p = self.run_script("listserv", "--sender", "chris@cpbee.cmnet", stdin=mail("SUBSCRIBE gamma", "SUBSCRIBE gamma"))
        self.assertEqual(p.returncode, 0)
        self.assertEqual(self.ctl("members", "gamma").stdout.decode().strip(), "chris@cpbee.cmnet")
        self.assertTrue(self.outgoing()[0][1].get_content().startswith("OK you are subscribed to gamma"))


if __name__ == "__main__":
    unittest.main()
