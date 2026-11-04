#!/usr/bin/env python3
"""Tests for netrc-to-tickets, on throwaway files in a temp directory (nothing real is touched).

    python3 net-utils/test/test_netrc_to_tickets.py
"""
import os
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)   # net-utils, the folder above
TOOL = os.path.join(TOOLS, "netrc-to-tickets")

NETRC = """# my logins
machine cpbee login chris-pollitt password "irc pw 1"
machine cpbee login chris password "mail/pw:2@x"  # allowlist secret
machine cpbee:5232 login chris password "cal pw 3"
machine irc.libera.chat
  login chris-pollitt
  password "quoted pw"  # allowlist secret
machine cpvax login system password vaxpw
default login anonymous password a@b
machine nopass login bob
"""


class T(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="n2t-")
        self.netrc = os.path.join(self.d, "netrc")
        self.tix = os.path.join(self.d, "tickets")
        with open(self.netrc, "w") as fh:
            fh.write(NETRC)
        os.chmod(self.netrc, 0o644)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.d, ignore_errors=True)

    def run_tool(self, *args, answers=None):
        """answers: text for stdin (with --prompt the tool asks and reads it from there)."""
        p = subprocess.run([sys.executable, TOOL, "--netrc", self.netrc, "--tickets", self.tix] + list(args),
                           input=answers, stdin=None if answers is not None else subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        return p.returncode, p.stdout

    def put(self, path, text):
        with open(path, "w") as fh:
            fh.write(text)

    def test_port_keyword_and_known_ports_need_no_question(self):
        self.put(self.netrc, 'machine mailhost login a password "p1" port 993\n'
                             'machine mailhost:587 login a password "p1"\n'  # allowlist secret
                             'machine web login w password "p2" port 8080\n')
        rc, out = self.run_tool("--prompt", "-y", answers="")
        self.assertEqual(rc, 0, out)
        t = self.tickets()
        self.assertIn("imaps://a:p1@mailhost.cmnet:993", t)       # the keyword port: protocol added, port kept  # allowlist secret
        self.assertIn("smtp://a:p1@mailhost.cmnet:587", t)  # allowlist secret
        self.assertIn("*://w:p2@web.cmnet:8080", t)               # 8080 is not a known port: the default (-y: no question)  # allowlist secret

    def test_a_portless_entry_asks_and_takes_several_names(self):
        self.put(self.netrc, 'machine cpbee login chris password "pw1"\nmachine cpvax login system password "pw2"\n')  # allowlist secret
        # first question: imaps and smtp; second: Enter = the default; then "go ahead"
        rc, out = self.run_tool("--prompt", answers="imaps,smtp\n\ny\n")
        self.assertEqual(rc, 0, out)
        self.assertIn("scheme(s) for cpbee login chris", out)
        self.assertNotIn("pw1", out)
        self.assertEqual(self.tickets(), ["imaps://chris:pw1@cpbee.cmnet", "smtp://chris:pw1@cpbee.cmnet",  # allowlist secret
                                          "*://system:pw2@cpvax.cmnet"])  # allowlist secret

    def test_an_answer_that_is_not_a_scheme_is_asked_again(self):
        self.put(self.netrc, 'machine cpbee login chris password "pw1"\n')  # allowlist secret
        rc, out = self.run_tool("--prompt", answers="not a/scheme!\nimap\ny\n")
        self.assertIn("not a scheme name", out)
        self.assertEqual(self.tickets(), ["imap://chris:pw1@cpbee.cmnet"])  # allowlist secret

    def test_the_host_name_is_the_default_answer(self):
        self.put(self.netrc, 'machine irc.libera.chat login nick password "pw1"\n')  # allowlist secret
        rc, out = self.run_tool("--prompt", answers="\ny\n")
        self.assertEqual(self.tickets(), ["irc://nick:pw1@irc.libera.chat"])  # allowlist secret

    def test_existing_glob_tickets_are_retagged_in_place(self):
        self.put(self.netrc, "")
        self.put(self.tix, "# mine\n*://chris:p%40ss@cpbee.cmnet\n*://nick:x@irc.libera.chat\n"  # allowlist secret
                           "*://sys:y@somewhere.example\nimaps://keep:z@cpbee.cmnet\n*://k:v@host.example:993\n")  # allowlist secret
        # asked in file order: chris (imaps smtp), nick (Enter = irc, from the host name), sys (Enter = stays *);
        # the 993 ticket is decided by its port; then "go ahead"
        rc, out = self.run_tool("--prompt", answers="imaps smtp\n\n\ny\n")
        self.assertEqual(rc, 0, out)
        self.assertEqual(open(self.tix).read().splitlines(), [
            "# mine",
            "imaps://chris:p%40ss@cpbee.cmnet",                  # the password text is untouched  # allowlist secret
            "smtp://chris:p%40ss@cpbee.cmnet",  # allowlist secret
            "*://nick:x@irc.libera.chat".replace("*", "irc"),   # Enter = the host-name guess  # allowlist secret
            "*://sys:y@somewhere.example",                      # Enter on a host nothing guesses: kept as *  # allowlist secret
            "imaps://keep:z@cpbee.cmnet",  # allowlist secret
            "imaps://k:v@host.example:993"])                    # the port decided it without a question  # allowlist secret
        self.assertEqual(len([n for n in os.listdir(self.d) if ".bak-" in n]), 1)

    def test_yes_retags_only_what_something_decides(self):
        self.put(self.netrc, "")
        self.put(self.tix, "*://nick:x@irc.libera.chat\n*://sys:y@somewhere.example\n*://k:v@h.example:143\n")  # allowlist secret
        self.run_tool("-y")
        self.assertEqual(self.tickets(), ["irc://nick:x@irc.libera.chat", "*://sys:y@somewhere.example",  # allowlist secret
                                          "imap://k:v@h.example:143"])  # allowlist secret
        self.put(self.tix, "*://nick:x@irc.libera.chat\n")  # allowlist secret
        self.run_tool("-y", "--no-retag")
        self.assertEqual(self.tickets(), ["*://nick:x@irc.libera.chat"])  # allowlist secret
        self.run_tool("-y", "--map", "irc.libera.chat=ircs,irc")
        self.assertEqual(self.tickets(), ["ircs://nick:x@irc.libera.chat", "irc://nick:x@irc.libera.chat"])  # allowlist secret

    def tickets(self):
        try:
            with open(self.tix) as fh:
                return [l.rstrip("\n") for l in fh if l.strip() and not l.startswith("#")]
        except OSError:
            return []

    def test_dry_run_changes_nothing_and_shows_no_password(self):
        rc, out = self.run_tool("-n", "-y")
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(self.tix))
        self.assertEqual(open(self.netrc).read(), NETRC)
        for secret in ("irc pw 1", "mail/pw", "cal pw 3", "quoted pw", "vaxpw"):
            self.assertNotIn(secret, out)
        self.assertIn("irc://", out)                     # irc.libera.chat: by its name
        self.assertIn("https://", out)                   # cpbee:5232: by its port
        self.assertIn("no login or password", out)

    def test_copy_with_schemes_from_map_port_host_and_default(self):
        rc, out = self.run_tool("-y", "--map", "cpbee=imaps", "--map", "cpvax=smtp")
        self.assertEqual(rc, 0, out)
        t = self.tickets()
        self.assertIn("imaps://chris-pollitt:irc%20pw%201@cpbee.cmnet", t)  # allowlist secret
        self.assertIn("imaps://chris:mail%2Fpw%3A2%40x@cpbee.cmnet", t)  # allowlist secret
        self.assertIn("https://chris:cal%20pw%203@cpbee.cmnet:5232", t)  # allowlist secret
        self.assertIn("irc://chris-pollitt:quoted%20pw@irc.libera.chat", t)  # allowlist secret
        self.assertIn("smtp://system:vaxpw@cpvax.cmnet", t)  # allowlist secret
        self.assertEqual(len(t), 5)                      # default and the entry without a password: not copied
        self.assertEqual(open(self.netrc).read(), NETRC)             # a copy, not a move
        self.assertEqual(stat.S_IMODE(os.stat(self.tix).st_mode) & 0o077, 0)

    def test_unknown_hosts_get_the_default_scheme(self):
        self.run_tool("-y", "--default-scheme", "imap")
        self.assertTrue(any(l.startswith("imap://system:vaxpw@cpvax.cmnet") for l in self.tickets()))  # allowlist secret
        os.unlink(self.tix)
        self.run_tool("-y")
        self.assertIn("*://system:vaxpw@cpvax.cmnet", self.tickets())  # allowlist secret

    def test_move_removes_only_the_migrated_entries_and_keeps_the_rest(self):
        rc, out = self.run_tool("-y", "--move", "--map", "cpbee=imaps", "--map", "cpvax=smtp")
        self.assertEqual(rc, 0, out)
        left = open(self.netrc).read()
        self.assertIn("# my logins", left)
        self.assertIn("default login anonymous", left)
        self.assertIn("machine nopass login bob", left)
        for gone in ("cpbee", "irc.libera.chat", "cpvax"):
            self.assertNotIn(gone, left)
        self.assertEqual(stat.S_IMODE(os.stat(self.netrc).st_mode) & 0o077, 0)     # nobody else can read it
        baks = [n for n in os.listdir(self.d) if ".bak-" in n]
        self.assertEqual(len(baks), 1)                   # the netrc's; there was no tickets file to back up
        self.assertEqual(open(os.path.join(self.d, baks[0])).read(), NETRC)

    def test_rerun_adds_nothing_twice(self):
        self.run_tool("-y")
        n = len(self.tickets())
        rc, out = self.run_tool("-y")
        self.assertEqual((rc, len(self.tickets())), (0, n))
        self.assertIn("nothing to do", out)

    def test_a_different_password_is_reported_and_left_alone(self):
        with open(self.tix, "w") as fh:
            fh.write("imaps://chris:another@cpbee.cmnet\n")  # allowlist secret
        rc, out = self.run_tool("-y", "--move")
        self.assertEqual(rc, 0)
        self.assertIn("DIFFER chris", out.replace("cpbee login ", ""))
        self.assertIn("login chris   (", out)
        self.assertIn("machine cpbee login chris password", open(self.netrc).read())   # not removed
        self.assertEqual(sum(1 for l in self.tickets() if "@cpbee.cmnet" in l and l.startswith("imaps://chris:")), 1)

    def test_nothing_is_done_without_a_yes_when_no_terminal(self):
        rc, out = self.run_tool()
        self.assertEqual(rc, 1)
        self.assertFalse(os.path.exists(self.tix))

    def test_domain_only_for_bare_names(self):
        with open(self.netrc, "w") as fh:
            fh.write('machine cpbee login a password "x1"\nmachine localhost login b password "x2"\n'  # allowlist secret
                     'machine 10.0.0.5 login c password "x3"\nmachine files.example.org login d password "x4"\n'  # allowlist secret
                     'machine web:8080 login e password "x5"\n')  # allowlist secret
        self.run_tool("-y")
        t = self.tickets()
        self.assertEqual([l.split("@")[1] for l in t],
                         ["cpbee.cmnet", "localhost", "10.0.0.5", "files.example.org", "web.cmnet:8080"])
        os.unlink(self.tix)
        self.run_tool("-y", "--domain", "lan.example")
        self.assertIn("cpbee.lan.example", self.tickets()[0])
        os.unlink(self.tix)
        self.run_tool("-y", "--no-domain")
        self.assertEqual(self.tickets()[0].split("@")[1], "cpbee")

    def test_an_existing_fully_qualified_ticket_counts_as_the_same_host(self):
        with open(self.tix, "w") as fh:
            fh.write("imaps://chris:mail%2Fpw%3A2%40x@cpbee.cmnet\n")  # allowlist secret
        rc, out = self.run_tool("-y", "--map", "cpbee=imaps")
        self.assertEqual(sum(1 for l in self.tickets() if l.startswith("imaps://chris:mail")), 1)
        self.assertIn("there", out)

    def test_bad_map(self):
        rc, out = self.run_tool("--map", "cpbee")
        self.assertEqual(rc, 2)

    def test_the_apps_can_read_what_it_wrote(self):
        """tvmail-backend's own reading of a ticket line gives the password back."""  # allowlist secret
        self.run_tool("-y", "--map", "cpbee=imaps")
        import importlib.machinery
        import importlib.util
        path = os.path.join(TOOLS, "..", "..", "TUIs", "tvmail", "backend", "tvmail-backend")
        if not os.path.exists(path):
            self.skipTest("tvmail not beside this repository")
        loader = importlib.machinery.SourceFileLoader("tvm", path)
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("tvm", loader))
        loader.exec_module(mod)
        os.environ["TVMAIL_MU_TICKETS"] = self.tix
        self.addCleanup(os.environ.pop, "TVMAIL_MU_TICKETS", None)
        self.assertEqual(mod._mu_ticket_pass("imaps", "cpbee.cmnet", "chris"), "mail/pw:2@x")
        self.assertEqual(mod._mu_ticket_pass("imaps", "cpbee.cmnet", "chris-pollitt"), "irc pw 1")


if __name__ == "__main__":
    unittest.main()
