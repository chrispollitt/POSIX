#!/usr/bin/env python3
"""Tests for identity, on throwaway files in a temp directory (nothing real is read or changed).

    python3 net-utils/test/test_identity.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)   # net-utils, the folder above
TOOL = os.path.join(TOOLS, "identity")

LIST = """# PERSON SCHEME@HOST LOGIN flags # why
chris   imaps@cpbee        chris           # mail: the Unix and Dovecot user
chris   smtp@cpbee.cmnet   chris           # submission
chris   *@cpbee.cmnet:5232 chris           # the calendar and anything else there
chris   irc@irc.libera.chat chris-pollitt admin   # Libera
chris   irc@cpbee.cmnet    chris-pollitt  admin   # Ergo on the LAN
floyd   irc@cpbee.cmnet    Floyd          bot     # the central bot
ann     imaps@cpbee.cmnet  ann             # a second person
"""


class T(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="ident-")
        self.f = os.path.join(self.d, "identities")
        self.put(self.f, LIST)
        self.env = dict(os.environ, IDENTITY_FILE=self.f, IDENTITY_SYSTEM=os.path.join(self.d, "none"),
                        HOME=os.path.join(self.d, "home"))

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def put(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(text)

    def run_tool(self, *args):
        p = subprocess.run([sys.executable, TOOL] + list(args), env=self.env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        return p.returncode, p.stdout.strip()

    # -- asking
    def test_login_exact_scheme_then_wildcard_and_bare_hosts_are_qualified(self):
        self.assertEqual(self.run_tool("login", "chris", "irc", "irc.libera.chat"), (0, "chris-pollitt"))
        self.assertEqual(self.run_tool("login", "chris", "imaps", "cpbee"), (0, "chris"))           # bare = cpbee.cmnet
        self.assertEqual(self.run_tool("login", "chris", "imap", "cpbee.cmnet"), (0, "chris"))      # imap = imaps
        self.assertEqual(self.run_tool("login", "chris", "https", "cpbee"), (0, "chris"))           # the * line, port ignored
        self.assertEqual(self.run_tool("login", "chris", "irc", "cpbee"), (0, "chris-pollitt"))     # exact beats *
        self.assertEqual(self.run_tool("login", "chris", "irc", "nowhere.example")[0], 1)
        self.assertEqual(self.run_tool("login", "nobody", "irc", "cpbee")[0], 1)

    def test_person_and_admins(self):
        self.assertEqual(self.run_tool("person", "irc", "irc.libera.chat", "chris-pollitt"), (0, "chris"))
        self.assertEqual(self.run_tool("person", "irc", "cpbee", "Floyd"), (0, "floyd"))
        self.assertEqual(self.run_tool("person", "imaps", "cpbee", "ann"), (0, "ann"))
        self.assertEqual(self.run_tool("person", "imaps", "cpbee", "chris-pollitt")[0], 1)
        self.assertEqual(self.run_tool("admins"), (0, "chris-pollitt"))
        self.assertEqual(self.run_tool("admins", "irc@irc.libera.chat"), (0, "chris-pollitt"))
        self.assertEqual(self.run_tool("admins", "imaps")[0], 1)

    def test_list(self):
        rc, out = self.run_tool("list", "ann")
        self.assertEqual(rc, 0)
        self.assertIn("ann", out)
        self.assertNotIn("chris", out)

    # -- changing
    def test_add_plan_and_remove(self):
        rc, out = self.run_tool("plan", "add", "ann", "irc@cpbee", "ann-irc", "--why", "her IRC login")
        self.assertEqual(rc, 3, out)
        self.assertNotIn("ann-irc", open(self.f).read())                      # plan changes nothing
        rc, out = self.run_tool("add", "ann", "irc@cpbee", "ann-irc", "--why", "her IRC login")
        self.assertEqual(rc, 0, out)
        self.assertIn("ann-irc", open(self.f).read())
        self.assertEqual(self.run_tool("login", "ann", "irc", "cpbee"), (0, "ann-irc"))
        self.assertEqual(self.run_tool("plan", "add", "ann", "irc@cpbee", "ann-irc", "--why", "x")[0], 0)   # already there
        self.assertEqual(len([n for n in os.listdir(self.d) if ".bak-" in n]), 1)
        self.assertEqual(self.run_tool("remove", "ann", "irc@cpbee")[0], 0)
        self.assertNotIn("ann-irc", open(self.f).read())
        self.assertIn("# PERSON", open(self.f).read())                         # comments survive

    def test_add_refusals(self):
        rc, out = self.run_tool("add", "ann", "imaps@cpbee", "chris", "--why", "x")
        self.assertEqual(rc, 1)
        self.assertIn("chris's", out)                                         # another person's login there
        rc, out = self.run_tool("add", "chris", "imaps@cpbee", "chris-pollitt", "--why", "x")
        self.assertEqual(rc, 1)
        self.assertIn("two logins for one person", out)
        self.assertEqual(self.run_tool("add", "chris", "imaps@cpbee", "chris-pollitt", "--also", "--why", "x")[0], 0)
        self.assertEqual(self.run_tool("add", "ann", "irc@cpbee", "a")[0], 1)               # a reason is required
        self.assertEqual(self.run_tool("add", "bad name", "irc@cpbee", "a", "--why", "x")[0], 1)
        self.assertEqual(self.run_tool("add", "ann", "irc@cpbee", "a", "root", "--why", "x")[0], 1)   # unknown flag

    def test_a_bad_line_is_reported_with_its_place(self):
        self.put(self.f, "chris irc\n")
        rc, out = self.run_tool("list")
        self.assertEqual(rc, 1)
        self.assertIn(":1:", out)

    # -- check
    def fixtures(self):
        h = os.path.join(self.d, "home")
        self.put(h + "/.mu-tickets", "*://chris:s3cret@cpbee\nirc://chris-pollitt:x@cpbee\nimaps://stranger:y@cpbee\n")  # allowlist secret
        self.put(h + "/.netrc", "machine cpbee.cmnet login chris@cpbee.cmnet password z\n"
                                "machine irc.libera.chat login chris-pollitt password q\n")
        self.put(h + "/.config/tvchat/tvchat.conf",
                 "[account:libera]\nprotocol = irc\nhost = irc.libera.chat\nnick = chris-pollitt\nsasl = chris-pollitt\n"
                 "[account:cpbee_chat]\nprotocol = irc\nhost = cpbee\nsasl = chris-pollitt\n"
                 "[account:delta]\nprotocol = deltachat\naddr = chris@chat.example.org\n")
        self.put(h + "/.config/tvmail/tvmail.conf", "[imap]\nhost = cpbee\nuser = chris\n[smtp]\nhost = cpbee\nuser = chris\n")
        self.put(h + "/.config/tvcal/tvcal.conf", "[server]\nurl = https://cpbee:5232/chris/calendar/\nuser = chris\n")
        self.put(h + "/.mail", 'mailbox { mailbox-pattern "imap://chris@cpbee:143/INBOX"; };\nmailer { url "smtp://cpbee:25"; };\n')
        self.floyd = os.path.join(self.d, "floyd.conf")
        self.put(self.floyd, "[account:floyd]\nprotocol = floyd\nadmins = chris-pollitt, chris\n"
                             "[account:libera]\nprotocol = irc\nhost = irc.libera.chat\nsasl = floyd-bot\n"
                             "contact = chris-pollitt\ninvite_from = chris-pollitt\n")

    def test_check_finds_what_the_list_does_not_know(self):
        self.fixtures()
        rc, out = self.run_tool("check", "--floyd-conf", self.floyd)
        self.assertEqual(rc, 3, out)
        self.assertIn("UNREGISTERED  imap login stranger on cpbee.cmnet", out)
        self.assertIn("UNREGISTERED  any protocol login chris@cpbee.cmnet on cpbee.cmnet", out)
        self.assertIn("UNREGISTERED  deltachat login chris@chat.example.org", out)
        self.assertIn("UNREGISTERED  irc login floyd-bot on irc.libera.chat", out)
        self.assertNotIn("login chris-pollitt on irc.libera.chat", out)         # known
        self.assertNotIn("UNREGISTERED  http", out)                               # the calendar login is known (* line)
        self.assertNotIn("s3cret", out)
        self.assertIn("ADMIN         admins = chris is not a login the list flags admin", out)
        self.assertNotIn("contact = chris-pollitt is not", out)
        self.assertIn("note DIFFERS  chris on cpbee.cmnet", out)                  # chris vs chris-pollitt on one host

    def test_check_flags_conflict_and_duplicate(self):
        self.put(self.f, LIST + "ann   imaps@cpbee   chris   # oops\nchris irc@irc.libera.chat chris-p2  # second\n")
        rc, out = self.run_tool("check", "--no-default-files")
        self.assertEqual(rc, 3, out)
        self.assertIn("CONFLICT      imap on cpbee.cmnet: login chris is listed for ann and chris", out)
        self.assertIn("DUPLICATE     chris has 2 logins for irc on irc.libera.chat", out)

    def test_host_aliases_and_floyd_local(self):
        self.put(self.f, "@host cpbee.cmnet 192.168.10.1\nfloyd  irc@cpbee  Floyd  bot\nfloyd  talk@cpbee  floyd  bot\n")
        fl = os.path.join(self.d, "f.conf")
        self.put(fl, "[account:a]\nprotocol = irc\nhost = 192.168.10.1\nsasl = Floyd\n"
                     "[account:t]\nprotocol = talk\nhost = 127.0.0.1\nuser = floyd\n")
        self.assertEqual(self.run_tool("login", "floyd", "irc", "192.168.10.1"), (0, "Floyd"))
        rc, out = self.run_tool("check", "--no-default-files", "--floyd-conf", fl)
        self.assertIn("UNREGISTERED  talk login floyd on 127.0.0.1", out)          # without the hint: not known
        rc, out = self.run_tool("check", "--no-default-files", "--floyd-conf", fl, "--floyd-local", "cpbee")
        self.assertEqual(rc, 0, out)

    def test_a_clean_list_exits_0_and_notes_only_count_with_strict(self):
        self.put(self.f, "chris  *@cpbee.cmnet  chris\nchris  irc@irc.libera.chat  chris-pollitt  admin\n")
        self.put(os.path.join(self.d, "home/.mu-tickets"), "*://chris:p@cpbee\n")  # allowlist secret
        self.assertEqual(self.run_tool("check")[0], 0)
        self.put(self.f, "chris  *@cpbee.cmnet  chris\nchris  irc@cpbee.cmnet  chris-pollitt\n")
        rc, out = self.run_tool("check", "--no-default-files")
        self.assertEqual(rc, 0, out)
        self.assertIn("note DIFFERS", out)
        self.assertEqual(self.run_tool("check", "--no-default-files", "--strict")[0], 3)

    def test_unseen_with_v(self):
        self.put(self.f, "chris  imaps@cpbee  chris\nchris  irc@x.example  chris2\n")
        self.put(os.path.join(self.d, "home/.mu-tickets"), "imaps://chris:p@cpbee\n")  # allowlist secret
        rc, out = self.run_tool("check", "-v")
        self.assertIn("note UNSEEN   chris irc@x.example login chris2", out)
        self.assertNotIn("UNSEEN   chris imap", out)

    def test_no_password_ever_reaches_the_output(self):
        self.fixtures()
        for cmd in (("check", "--floyd-conf", self.floyd, "-v"), ("list",), ("check", "--strict")):
            out = self.run_tool(*cmd)[1]
            for secret in ("s3cret", " password z", "password q"):
                self.assertNotIn(secret, out)


if __name__ == "__main__":
    unittest.main()
