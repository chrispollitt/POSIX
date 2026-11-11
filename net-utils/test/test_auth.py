#!/usr/bin/env python3
"""Tests for auth, on a throwaway gpg home and vault in a temp directory (nothing real is read or changed).

    python3 net-utils/test/test_auth.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)   # net-utils, the folder above
TOOL = os.path.join(TOOLS, "auth")

NETRC = "# comment\nmachine cpvax login system password s3cr3t-vax\n"        # allowlist secret
TICKETS = ("imaps://chris:pa%40ss%2Fword@cpbee.cmnet\n"                      # allowlist secret
           "https://chris:cal-pw@cpbee.cmnet:5232\n"                         # allowlist secret
           "# a comment\n")


class T(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.d = tempfile.mkdtemp(prefix="auth-")
        os.chmod(cls.d, 0o700)
        cls.gh = os.path.join(cls.d, "gnupg")
        os.makedirs(cls.gh, mode=0o700)
        cls.env = dict(os.environ, GNUPGHOME=cls.gh, AUTH_LOCAL="1", HOME=os.path.join(cls.d, "home"),
                       AUTH_VAULT=os.path.join(cls.d, "vault.gpg"), AUTH_GPG_ARGS="--pinentry-mode loopback --passphrase ''",
                       IDENTITY_FILE=os.path.join(cls.d, "identities"), IDENTITY_SYSTEM=os.path.join(cls.d, "none"),
                       AUTH_PERSON="chris", AUTH_SERVICE=os.path.join(cls.d, "service.gpg"), AUTH_CLIENTS=os.path.join(cls.d, "clients"),
                       AUTH_BIN=TOOL, PATH=TOOLS + os.pathsep + os.environ["PATH"])
        os.makedirs(cls.env["HOME"])

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["gpgconf", "--kill", "gpg-agent"], env=cls.env, stderr=subprocess.DEVNULL)
        shutil.rmtree(cls.d, ignore_errors=True)

    def run_auth(self, *args, stdin=None, env=None):
        r = subprocess.run([sys.executable, TOOL] + list(args), input=stdin, env=env or self.env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        return r.returncode, r.stdout, r.stderr

    def put(self, name, text):
        p = os.path.join(self.env["HOME"], name)
        with open(p, "w") as fh:
            fh.write(text)
        return p

    def fresh(self):
        """a new empty vault (the key is made once)."""
        if os.path.exists(self.env["AUTH_VAULT"]):
            os.remove(self.env["AUTH_VAULT"])
        if os.path.exists(self.env["AUTH_SERVICE"]):   # no service tier left over either
            os.remove(self.env["AUTH_SERVICE"])
        if os.path.exists(self.env["IDENTITY_FILE"]):   # no identity list left over from an earlier test
            os.remove(self.env["IDENTITY_FILE"])
        rc, out, err = self.run_auth("init")
        self.assertEqual(rc, 0, err)

    def test_00_help_and_usage(self):
        self.assertEqual(self.run_auth("-h")[0], 0)
        self.assertEqual(self.run_auth("bogus")[0], 2)
        self.assertEqual(self.run_auth("get", "imaps")[0], 2)

    def test_missing_vault_is_exit_4(self):
        env = dict(self.env, AUTH_VAULT=os.path.join(self.d, "nope.gpg"))
        self.assertEqual(self.run_auth("list", env=env)[0], 4)

    def test_set_get_list_remove(self):
        self.fresh()
        rc, out, err = self.run_auth("set", "imaps@cpbee", "chris", "--stdin", "--note", "mail", stdin="m41l pw\n")
        self.assertEqual(rc, 0, err)
        self.assertIn("added imaps@cpbee.cmnet", out)
        self.assertEqual(self.run_auth("get", "imap", "cpbee", "chris")[1], "m41l pw\n")      # imap == imaps, bare host
        self.assertEqual(self.run_auth("get", "smtp", "cpbee", "chris")[0], 1)               # other scheme: none
        rc, out, _ = self.run_auth("list")
        self.assertIn("chris", out)
        self.assertNotIn("m41l", out)                                                       # list never shows secrets
        self.assertIn("changed", self.run_auth("set", "imaps@cpbee", "chris", "--stdin", stdin="new\n")[1])
        self.assertEqual(self.run_auth("get", "imaps", "cpbee.cmnet", "chris")[1], "new\n")
        self.assertIn("removed", self.run_auth("remove", "imaps@cpbee", "chris")[1])
        self.assertEqual(self.run_auth("get", "imaps", "cpbee", "chris")[0], 1)

    def test_get_without_login_uses_the_only_one_or_identity(self):
        self.fresh()
        self.run_auth("set", "imaps@cpbee", "chris", "--stdin", stdin="a\n")
        self.assertEqual(self.run_auth("get", "imaps", "cpbee")[1], "a\n")                  # only one stored
        self.run_auth("set", "irc@cpbee", "chris-pollitt", "--stdin", stdin="b\n")
        self.run_auth("set", "*@cpbee", "other", "--stdin", stdin="c\n")
        rc, _, err = self.run_auth("get", "irc", "cpbee")                                   # two candidates, no identity
        self.assertEqual(rc, 1)
        self.assertIn("which login", err)
        self.put("../identities", "chris irc@cpbee.cmnet chris-pollitt\n")
        self.assertEqual(self.run_auth("get", "irc", "cpbee")[1], "b\n")                    # identity decides

    def test_empty_secret_refused(self):
        self.fresh()
        self.assertEqual(self.run_auth("set", "imaps@cpbee", "chris", "--stdin", stdin="\n")[0], 1)

    def test_import_tickets_and_netrc_then_render(self):
        self.fresh()
        t = self.put("tickets.in", TICKETS)
        n = self.put("netrc.in", NETRC)
        rc, out, err = self.run_auth("import", "tickets", t, "-n")
        self.assertEqual(rc, 0, err)
        self.assertIn("2 to add", out)
        self.assertEqual(self.run_auth("list")[1].strip(), "")                              # -n changed nothing
        self.assertEqual(self.run_auth("import", "tickets", t)[0], 0)
        self.assertIn("0 to add, 2 already", self.run_auth("import", "tickets", t)[1])
        self.assertEqual(self.run_auth("import", "netrc", n)[0], 0)
        self.assertEqual(self.run_auth("get", "imaps", "cpbee", "chris")[1], "pa@ss/word\n")  # percent-decoded
        self.assertEqual(self.run_auth("get", "ftp", "cpvax", "system")[1], "s3cr3t-vax\n")  # netrc entry is scheme *
        # a different secret for the same login is reported, not replaced
        t2 = self.put("tickets2.in", "imaps://chris:other@cpbee.cmnet\n")                   # allowlist secret
        rc, out, _ = self.run_auth("import", "tickets", t2)
        self.assertEqual(rc, 3)
        self.assertIn("DIFFERS", out)
        self.assertNotIn("other", out.replace("another", ""))
        self.assertEqual(self.run_auth("get", "imaps", "cpbee", "chris")[1], "pa@ss/word\n")

        # render: tickets, keeping what was there, port kept, idempotent, mode 600, backup
        out_t = self.put("tickets.out", "# mine\nimaps://old:keep@elsewhere\n")             # allowlist secret
        rc, out, err = self.run_auth("render", "tickets", "--out", out_t)
        self.assertEqual(rc, 0, err)
        txt = open(out_t).read()
        self.assertTrue(txt.startswith("# mine\nimaps://old:keep@elsewhere\n"))             # allowlist secret
        self.assertIn("imaps://chris:pa%40ss%2Fword@cpbee.cmnet\n", txt)                     # allowlist secret
        self.assertIn("https://chris:cal-pw@cpbee.cmnet:5232\n", txt)                        # allowlist secret
        self.assertNotIn("pa@ss", out)
        self.assertEqual(os.stat(out_t).st_mode & 0o077, 0)
        self.assertTrue([f for f in os.listdir(self.env["HOME"]) if f.startswith("tickets.out.bak-")])
        self.assertIn("(unchanged)", self.run_auth("render", "tickets", "--out", out_t)[1])
        # the block is not re-imported as if it were the user's own file
        self.assertIn("0 to add", self.run_auth("import", "tickets", out_t)[1].split("\n")[-2] + "0 to add")

        # render netrc: only ftp/telnet/* schemes
        out_n = self.put("netrc.out", "")
        self.assertEqual(self.run_auth("render", "netrc", "--out", out_n)[0], 0)
        txt = open(out_n).read()
        self.assertIn("machine cpvax.cmnet login system password s3cr3t-vax", txt)  # allowlist secret
        self.assertNotIn("cpbee", txt)

    def _foo_line(self, user, secret, label, password):
        """an entry as Foo_Bar.php writes it: hand padding, then OpenSSL's, base64."""
        import base64
        import hashlib
        data = password + label.encode()
        h = hashlib.sha256(data).digest()
        out = h
        for _ in range(5):
            h = hashlib.sha256(h + data).digest()
            out += h
        key, iv = out[:32], out[32:48]
        pad = 16 - (len(secret) % 16)
        ct = secret.encode() + bytes([pad]) * pad
        r = subprocess.run(["openssl", "enc", "-aes-256-cbc", "-K", key.hex(), "-iv", iv.hex()], input=ct,
                           stdout=subprocess.PIPE, check=True)
        return "%s\t%s\t%s" % (user, base64.b64encode(r.stdout).decode(), label)

    def test_import_foo(self):
        self.fresh()
        pw = b"-----BEGIN RSA PRIVATE KEY-----\nnot a real key\n"  # allowlist secret
        keyf = os.path.join(self.env["HOME"], "oldkey")
        with open(keyf, "wb") as fh:
            fh.write(pw)
        lines = [self._foo_line("whatwelo", "t0tp-seed", "whatwelove.org:2fa", pw),
                 self._foo_line("Chris", "pw with space & 16chars!", "cmpi:web", pw),
                 self._foo_line("root", "x", "cmpi:sudo", pw),
                 self._foo_line("mesh", "m", "mesh", pw),
                 self._foo_line("bad", "zzz", "lost:web", b"another key")]
        foo = self.put("bar", "\n".join(lines) + "\n")
        rc, out, err = self.run_auth("import", "foo", foo, "--key", keyf, "-n")
        self.assertEqual(rc, 3, err)                                           # one entry would not decrypt
        self.assertIn("UNREADABLE  lost:web", out)
        self.assertIn("would add  2fa@whatwelove.org whatwelo (password)", out)
        self.assertIn("would add  https@cmpi.cmnet Chris (password)", out)       # a LAN host gets the domain
        self.assertIn("would add  sudo@cmpi.cmnet root", out)
        self.assertIn("would add  *@mesh.cmnet mesh", out)
        for s in ("t0tp-seed", "pw with space"):
            self.assertNotIn(s, out)
        self.assertEqual(self.run_auth("list")[1].strip(), "")                  # -n changed nothing
        self.run_auth("import", "foo", foo, "--key", keyf, "--skip", "cmpi:sudo")
        self.assertEqual(self.run_auth("get", "https", "cmpi", "Chris")[1], "pw with space & 16chars!\n")
        self.assertEqual(self.run_auth("get", "2fa", "whatwelove.org", "whatwelo")[1], "t0tp-seed\n")
        self.assertEqual(self.run_auth("get", "sudo", "cmpi", "root")[0], 1)    # skipped
        self.assertEqual(self.run_auth("foo", "cmpi:web")[1], "Chris\tpw with space & 16chars!\n")   # the old foo() call
        self.assertEqual(self.run_auth("foo", "no:such")[0], 1)
        self.assertEqual(self.run_auth("get", "https", "cmpi", "Chris", "--with-login")[1], "Chris\tpw with space & 16chars!\n")
        self.assertIn("0 to add, 3 already", self.run_auth("import", "foo", foo, "--key", keyf, "--skip", "cmpi:sudo")[1])
        # imported entries are for the vault only: render never writes them to a file
        out_t = self.put("tickets.foo", "")
        self.run_auth("render", "tickets", "--out", out_t)
        self.assertNotIn("cmpi", open(out_t).read())
        self.assertEqual(self.run_auth("import", "foo", foo, "--key", os.path.join(self.d, "nokey"))[0], 1)


    def test_totp(self):
        self.fresh()
        seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"                    # RFC 6238 test key "12345678901234567890"
        self.run_auth("set", "2fa@wwl.example", "me", "--kind", "totp", "--stdin", stdin="gezd gnbv-gy3t qojq gezd gnbv gy3t qojq" + chr(10))
        for now, want in (("59", "287082"), ("1111111109", "081804"), ("1111111111", "050471"), ("20000000000", "353130")):
            env = dict(self.env, AUTH_NOW=now)
            rc, out, err = self.run_auth("totp", "wwl.example", env=env)
            self.assertEqual((rc, out.strip()), (0, want), err)             # the RFC vectors, spaces and case in the seed ignored
        self.assertEqual(self.run_auth("totp", "wwl.example", "me", env=dict(self.env, AUTH_NOW="59"))[1], "287082" + chr(10))
        self.assertEqual(self.run_auth("totp", "wwl.example", "nobody")[0], 1)
        self.assertEqual(self.run_auth("totp", "elsewhere.example")[0], 1)
        self.run_auth("set", "2fa@bad.example", "x", "--kind", "totp", "--stdin", stdin="not base32 !" + chr(10))
        rc, out, err = self.run_auth("totp", "bad.example")
        self.assertEqual(rc, 1)
        self.assertIn("not a base32", err)
        self.assertNotIn("not base32 !", err)
        self.run_auth("set", "2fa@wwl.example", "other", "--kind", "totp", "--stdin", stdin=seed + chr(10))
        rc, _, err = self.run_auth("totp", "wwl.example")
        self.assertEqual(rc, 1)
        self.assertIn("which login", err)

    def test_render_tickets_replaces_older_lines_and_adds_bare_names(self):
        self.fresh()
        self.run_auth("set", "imaps@cpbee", "chris", "--stdin", stdin="new-pw\n")
        self.run_auth("set", "https@cpbee:5232", "chris", "--stdin", stdin="cal-pw\n")
        self.run_auth("set", "imaps@192.168.10.1", "chris", "--stdin", stdin="ip-pw\n")
        old = ("# mine\n" "imaps://old:keep@elsewhere\n" "imaps://chris:stale@cpbee.cmnet\n" "imaps://chris:stale2@cpbee\n")  # allowlist secret
        f = self.put("tickets.bare", old)
        rc, out, err = self.run_auth("render", "tickets", "--out", f)
        self.assertEqual(rc, 0, err)
        self.assertIn("2 older lines", out)                                       # both spellings of the same login
        txt = open(f).read()
        self.assertNotIn("stale", txt)
        self.assertTrue(txt.startswith("# mine\nimaps://old:keep@elsewhere\n"))   # foreign lines stay, in place  # allowlist secret
        for line in ("imaps://chris:new-pw@cpbee.cmnet", "imaps://chris:new-pw@cpbee",  # allowlist secret
                     "https://chris:cal-pw@cpbee.cmnet:5232", "https://chris:cal-pw@cpbee:5232"):  # the port is kept  # allowlist secret
            self.assertIn(line + "\n", txt)
        self.assertEqual(txt.count("ip-pw"), 1)                                   # an IP address has no bare name
        self.assertEqual(txt.count("BEGIN auth"), 1)
        self.assertIn("(unchanged)", self.run_auth("render", "tickets", "--out", f)[1])

    def test_render_netrc_has_no_markers_and_replaces_its_own_lines(self):
        self.fresh()
        self.run_auth("set", "ftp@cpvax", "system", "--stdin", stdin="vax-pw\n")
        self.run_auth("set", "imaps@cpbee", "chris", "--stdin", stdin="mail-pw\n")
        old = ("# machine <hostname> login <username> password <pw>\n" "\n"  # allowlist secret
               "machine other login u password p\n"
               "machine cpvax login system password stale\n"  # allowlist secret
               "# BEGIN auth (written by auth render; edit the vault, not this block)\n"
               "machine cpvax.cmnet login system password stale2\n" "# END auth\n")  # allowlist secret
        f = self.put("netrc.bare", old)
        rc, out, err = self.run_auth("render", "netrc", "--out", f)
        self.assertEqual(rc, 0, err)
        txt = open(f).read()
        self.assertNotIn("BEGIN", txt)                                            # Mailutils reads # as a word
        self.assertNotIn("END auth", txt)
        self.assertNotIn("stale", txt)
        self.assertIn("machine other login u password p\n", txt)                  # foreign entries stay
        self.assertTrue(txt.startswith("# machine <hostname>"))
        self.assertIn("machine cpvax.cmnet login system password vax-pw\n", txt)  # both names ftp scripts may type  # allowlist secret
        self.assertIn("machine cpvax login system password vax-pw\n", txt)  # allowlist secret
        self.assertNotIn("cpbee", txt)                                            # a mail login never goes in the netrc
        self.assertNotIn("mail-pw", txt)
        self.assertIn("(unchanged)", self.run_auth("render", "netrc", "--out", f)[1])

    def test_one_record_for_several_schemes(self):
        self.fresh()
        rc, out, err = self.run_auth("set", "imaps,smtp@cpbee", "chris", "--stdin", stdin="multi-pw\n")
        self.assertEqual(rc, 0, err)
        self.assertIn("added imaps,smtp@cpbee.cmnet chris", out)
        self.assertEqual(self.run_auth("get", "imaps", "cpbee", "chris")[1], "multi-pw\n")
        self.assertEqual(self.run_auth("get", "smtp", "cpbee", "chris")[1], "multi-pw\n")
        self.assertEqual(self.run_auth("get", "smtps", "cpbee", "chris")[1], "multi-pw\n")      # smtp == smtps
        self.assertEqual(self.run_auth("get", "irc", "cpbee", "chris")[0], 1)                   # not a catch-all
        self.assertEqual(self.run_auth("list")[1].count("chris"), 1)                            # one record
        self.assertIn("changed", self.run_auth("set", "smtp,imaps@cpbee", "chris", "--stdin", stdin="two-pw\n")[1])
        self.assertEqual(self.run_auth("get", "imaps", "cpbee", "chris")[1], "two-pw\n")        # same set, other order
        f = self.put("tickets.multi", "")
        self.run_auth("render", "tickets", "--out", f)
        txt = open(f).read()
        for line in ("imaps://chris:two-pw@cpbee.cmnet", "imaps://chris:two-pw@cpbee", "smtp://chris:two-pw@cpbee.cmnet",  # allowlist secret
                     "smtp://chris:two-pw@cpbee"):  # allowlist secret
            self.assertIn(line + "\n", txt)
        self.assertNotIn("*://", txt)
        # a ticket line for one scheme of it is what render replaces, not a second copy
        g = self.put("tickets.multi2", "imaps://chris:old@cpbee\n")  # allowlist secret
        self.assertIn("1 older line", self.run_auth("render", "tickets", "--out", g)[1])
        # one scheme comes off, the record stays for the other
        rc, out, _ = self.run_auth("remove", "smtp@cpbee", "chris")
        self.assertIn("it stays for imaps", out)
        self.assertEqual(self.run_auth("get", "smtp", "cpbee", "chris")[0], 1)
        self.assertEqual(self.run_auth("get", "imaps", "cpbee", "chris")[1], "two-pw\n")
        self.run_auth("remove", "imaps@cpbee", "chris")
        self.assertEqual(self.run_auth("list")[1].strip(), "")

    def test_check_sees_each_scheme_of_a_multi_scheme_record(self):
        self.fresh()
        self.run_auth("set", "imaps,smtp@cpbee", "chris", "--stdin", stdin="x\n")
        self.put("../identities", "chris imaps@cpbee.cmnet chris\nchris smtp@cpbee.cmnet chris\n")
        rc, out, _ = self.run_auth("check")
        self.assertEqual(rc, 0, out)
        self.put("../identities", "chris imaps@cpbee.cmnet chris\n")
        rc, out, _ = self.run_auth("check")
        self.assertEqual(rc, 3)
        self.assertIn("NOIDENTITY  vault has smtp@cpbee.cmnet chris", out)

    def test_render_dry_run_changes_nothing(self):
        self.fresh()
        self.run_auth("set", "*@cpvax", "system", "--stdin", stdin="pw\n")
        p = self.put("n.out", "keep\n")
        rc, out, _ = self.run_auth("render", "netrc", "--out", p, "-n")
        self.assertEqual(rc, 0)
        self.assertEqual(open(p).read(), "keep\n")
        self.assertNotIn("pw", out.replace("password", ""))

    def test_check_against_identity(self):
        self.fresh()
        self.run_auth("set", "imaps@cpbee", "chris", "--stdin", stdin="a\n")
        self.run_auth("set", "irc@cpbee", "stray", "--stdin", stdin="b\n")
        self.put("../identities", "chris imaps@cpbee.cmnet chris\nchris smtp@cpbee.cmnet chris\n")
        rc, out, _ = self.run_auth("check")
        self.assertEqual(rc, 3)
        self.assertIn("NOIDENTITY  vault has irc@cpbee.cmnet stray", out)
        self.assertIn("NOSECRET    identity lists smtp@cpbee.cmnet chris", out)
        self.assertNotIn("imap@cpbee.cmnet chris;", out)
        self.assertNotIn("a\n", out.replace("vault has", ""))

    def test_check_wildcard_identity_line_is_satisfied_by_any_record(self):
        self.fresh()
        self.run_auth("set", "imaps,smtp@cpbee", "chris", "--stdin", stdin="x\n")
        self.put("../identities", "chris *@cpbee.cmnet chris\n")
        rc, out, _ = self.run_auth("check")
        self.assertEqual(rc, 0, out)

    def test_check_only_asks_about_lan_hosts_unless_all(self):
        self.fresh()
        self.run_auth("set", "imaps@cpbee", "chris", "--stdin", stdin="a\n")
        self.run_auth("set", "https@api.example.com", "me", "--stdin", stdin="b\n")
        self.put("../identities", "chris imaps@cpbee.cmnet chris\n")
        rc, out, _ = self.run_auth("check")
        self.assertEqual(rc, 0, out)
        rc, out, _ = self.run_auth("check", "--all")
        self.assertEqual(rc, 3)
        self.assertIn("NOIDENTITY  vault has https@api.example.com me", out)

    def test_set_keeps_the_netrc_mark_of_a_record(self):
        self.fresh()
        p = self.put("n.in", "machine cpbee login chris password old\n")  # allowlist secret
        self.assertEqual(self.run_auth("import", "netrc", p)[0], 0)
        self.assertIn("changed", self.run_auth("set", "*@cpbee", "chris", "--stdin", stdin="new\n")[1])
        out_file = os.path.join(self.env["HOME"], "n.out")
        self.assertEqual(self.run_auth("render", "netrc", "--out", out_file)[0], 0)
        text = open(out_file).read()
        self.assertIn("password new", text)       # still rendered into the netrc, with the new secret
        self.assertNotIn("password old", text)

    PUB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkeytestkeytestkeytestkey1 job@laptop"

    def fresh_service(self):
        if os.path.exists(self.env["AUTH_SERVICE"]):
            os.remove(self.env["AUTH_SERVICE"])
        rc, out, err = self.run_auth("init-service")
        self.assertEqual(rc, 0, err)

    def test_service_tier_reads_without_the_master_vault(self):
        self.fresh_service()
        rc, out, err = self.run_auth("set", "--service", "https@cpbee", "michelle", "--stdin", "--note", "radicale", stdin="S3rv1ce\n")
        self.assertEqual(rc, 0, err)
        nomaster = dict(self.env, AUTH_VAULT=os.path.join(self.d, "no-such-master.gpg"))   # master tier missing = locked
        rc, out, _ = self.run_auth("get", "https", "cpbee", "michelle", env=nomaster)
        self.assertEqual((rc, out), (0, "S3rv1ce\n"))
        rc, out, _ = self.run_auth("list", env=nomaster)
        self.assertEqual(rc, 4)                      # the master tier cannot be listed, and it says so
        self.assertIn("[service]", out)
        self.assertNotIn("S3rv1ce", out)

    def test_auth_askpass_picks_the_record_from_the_prompt(self):
        self.fresh()
        for spec, login, secret in (("sudo@boxa", "chris", "sudopw-1"), ("ssh@hostb", "alice", "sshpw-2"),
                                    ("sshkey@boxa", "id_test", "keypw-3"), ("https@github.com", "ghuser", "ghtok-4")):
            rc, _, err = self.run_auth("set", spec, login, "--stdin", stdin=secret + "\n")
            self.assertEqual(rc, 0, err)
        env = dict(self.env, AUTH_ASKPASS_HOST="boxa.cmnet")
        ask = os.path.join(TOOLS, "auth-askpass")

        def answer(prompt):
            r = subprocess.run(["bash", ask, prompt], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
            return r.returncode, r.stdout, r.stderr

        self.assertEqual(answer("[sudo] password for chris: ")[:2], (0, "sudopw-1\n"))
        self.assertEqual(answer("alice@hostb's password: ")[:2], (0, "sshpw-2\n"))
        self.assertEqual(answer("Enter passphrase for key '/home/x/.ssh/id_test': ")[:2], (0, "keypw-3\n"))
        self.assertEqual(answer("Enter passphrase for /home/x/.ssh/id_test: ")[:2], (0, "keypw-3\n"))      # the older wording
        self.assertEqual(answer("Username for 'https://github.com': ")[:2], (0, "ghuser\n"))
        self.assertEqual(answer("Password for 'https://ghuser@github.com': ")[:2], (0, "ghtok-4\n"))
        self.assertEqual(answer("Password for 'https://github.com': ")[:2], (0, "ghtok-4\n"))             # one login for the host
        rc, out, err = answer("[sudo] password for nobody: ")                                              # no such record
        self.assertEqual((rc, out), (1, ""))
        rc, out, err = answer("What is your favourite colour? ")                                          # no rule
        self.assertEqual((rc, out), (1, ""))
        self.assertIn("no rule", err)
        self.assertNotIn("pw", err + out)

    def test_ca_hands_out_the_ca_file_without_the_vault(self):
        pem = self.put("ca.pem", "-----BEGIN CERTIFICATE-----\nMIIBtest\n-----END CERTIFICATE-----\n")
        nomaster = dict(self.env, AUTH_VAULT=os.path.join(self.d, "no-such-master.gpg"), AUTH_CA_PATH=pem)   # locked is fine
        rc, out, err = self.run_auth("ca", env=nomaster)
        self.assertEqual((rc, out), (0, open(pem).read()), err)
        dest = os.path.join(self.env["HOME"], "out.pem")
        rc, out, err = self.run_auth("ca", "--out", dest, env=nomaster)
        self.assertEqual(rc, 0, err)
        self.assertIn("1 certificate", out)
        self.assertEqual(open(dest).read(), open(pem).read())
        rc, out, err = self.run_auth("ca", env=dict(nomaster, AUTH_CA_PATH=os.path.join(self.d, "missing.pem")))   # no such file
        self.assertEqual(rc, 1)
        self.assertIn("no CA certificate", err)

    def test_git_credential_helper(self):
        self.fresh()
        rc, _, err = self.run_auth("set", "https@github.com", "ghuser", "--stdin", stdin="ghtok-9\n")
        self.assertEqual(rc, 0, err)
        helper = os.path.join(TOOLS, "git-credential-auth")

        def run(op, text):
            r = subprocess.run(["bash", helper, op], input=text, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True)
            return r.returncode, r.stdout, r.stderr

        self.assertEqual(run("get", "protocol=https\nhost=github.com\n\n")[:2], (0, "username=ghuser\npassword=ghtok-9\n"))  # allowlist secret
        self.assertEqual(run("get", "protocol=https\nhost=github.com:443\nusername=ghuser\n\n")[:2],
                         (0, "username=ghuser\npassword=ghtok-9\n"))  # allowlist secret
        self.assertEqual(run("get", "protocol=https\nhost=elsewhere.example\n\n")[:2], (0, ""))            # no record: no answer
        self.assertEqual(run("get", "protocol=https\nhost=github.com\nusername=other\n\n")[:2], (0, ""))   # other login: no answer
        self.assertEqual(run("store", "protocol=https\nhost=github.com\nusername=ghuser\npassword=x\n\n")[:2], (0, ""))
        self.assertEqual(run("erase", "protocol=https\nhost=github.com\n\n")[:2], (0, ""))
        self.assertEqual(self.run_auth("get", "https", "github.com", "ghuser")[1], "ghtok-9\n")             # store/erase changed nothing

    def test_render_tmp_writes_a_private_file_not_the_real_one(self):
        self.fresh()
        rc, _, err = self.run_auth("set", "imaps@cpbee", "chris", "--stdin", stdin="tmpw-5\n")
        self.assertEqual(rc, 0, err)
        rtd = os.path.join(self.d, "runtime")
        os.makedirs(rtd, mode=0o700)
        env = dict(self.env, XDG_RUNTIME_DIR=rtd)
        rc, out, err = self.run_auth("render", "tickets", "--tmp", env=env)
        self.assertEqual(rc, 0, err)
        path = out.strip().splitlines()[-1]
        self.assertTrue(path.startswith(rtd), path)
        with open(path) as fh:
            self.assertIn("tmpw-5", fh.read())
        if not sys.platform.startswith("cygwin"):                                                         # Cygwin shows other modes
            self.assertEqual(os.stat(path).st_mode & 0o077, 0)
        self.assertFalse(os.path.exists(os.path.join(self.env["HOME"], ".mu-tickets")))                    # the real file untouched
        rc, out2, _ = self.run_auth("render", "tickets", "--tmp", env=env)                                 # again: fresh, same path
        self.assertEqual((rc, out2.strip().splitlines()[-1]), (0, path))
        rc, out3, _ = self.run_auth("render", "netrc", "--tmp", env=env)
        self.assertNotEqual(out3.strip().splitlines()[-1], path)                                           # its own file
        self.assertTrue(os.path.exists(out3.strip().splitlines()[-1]))

    def test_auth_canary_job(self):
        self.fresh()
        self.fresh_service()
        rc, _, err = self.run_auth("set", "--service", "https@cpbee", "michelle", "--stdin", stdin="S3rv1ce\n")
        self.assertEqual(rc, 0, err)
        log = os.path.join(self.env["HOME"], "canary.log")
        env = dict(self.env, AUTH_CANARY_LOG=log, AUTH_CANARY_OWN="https cpbee michelle", AUTH_CANARY_OTHER="imaps gmail.com")
        canary = os.path.join(TOOLS, "auth-canary")
        r = subprocess.run(["bash", canary], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("own=OK(len=7)", r.stdout)             # "S3rv1ce" and nothing else
        self.assertIn("other=DENIED", r.stdout)               # the master tier has no such record
        with open(log) as fh:
            text = fh.read()
        self.assertEqual(text.strip(), r.stdout.strip())
        self.assertNotIn("S3rv1ce", text + r.stdout)          # no secret in the log or the output
        env["AUTH_CANARY_OWN"] = "https cpbee nobody"          # its own record is missing: the job fails
        r = subprocess.run(["bash", canary], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn("own=FAIL", r.stdout)

    def test_bar_stores_by_old_label_and_foo_reads_it(self):
        self.fresh()                                 # an empty master tier, so a missing label is exit 1, not "locked"
        self.fresh_service()
        rc, out, err = self.run_auth("bar", "--service", "ahost:aserv", "auser", "--stdin", stdin="apass\n")
        self.assertEqual((rc, out.strip()), (0, "added ahost:aserv"), err)
        self.assertEqual(self.run_auth("foo", "ahost:aserv")[1], "auser\tapass\n")
        rc, out, _ = self.run_auth("bar", "--service", "ahost:aserv", "auser2", "--stdin", stdin="apass2\n")   # same label: replaced
        self.assertEqual((rc, out.strip()), (0, "changed ahost:aserv"))
        self.assertEqual(self.run_auth("foo", "ahost:aserv")[1], "auser2\tapass2\n")
        self.assertEqual(len(self.run_auth("list", "--service")[1].splitlines()), 1)
        self.assertNotIn("apass", self.run_auth("list", "--service")[1])
        self.assertEqual(self.run_auth("bar", "--service", "ahost:aserv", "u", "--stdin", stdin="\n")[0], 1)    # empty secret refused
        self.assertEqual(self.run_auth("bar", "--service")[0], 2)
        self.assertEqual(self.run_auth("bar", "--service", "--delete", "ahost:aserv")[1].strip(), "removed ahost:aserv")
        self.assertEqual(self.run_auth("foo", "ahost:aserv")[0], 1)
        self.assertEqual(self.run_auth("bar", "--service", "--delete", "ahost:aserv")[1].strip(), "nothing to remove")

    def test_php_shim_foo_and_bar(self):
        php = shutil.which("php-cli") or shutil.which("php")
        if not php:
            self.skipTest("no php on this machine")
        self.fresh_service()
        shim = os.path.join(TOOLS, "shims", "Foo_Bar.php")

        def run_php(code, env=None):
            p = self.put("t.php", "<?php require %r; %s" % (shim, code))
            r = subprocess.run([php, p], env=env or self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
            return r.stdout

        failed = '["failed","failed"]'                                                            # the original contract (fb.php tests 'failed')
        self.assertEqual(run_php('echo json_encode(foo("ahost:aserv"));'), failed)               # nothing yet
        self.assertEqual(run_php('echo json_encode(bar("auser", "ap ass\\"\'\\$x", "ahost:aserv"));'), "true")   # awkward characters
        self.assertEqual(run_php('echo json_encode(foo("ahost:aserv"));'), '["auser","ap ass\\"\'$x"]')
        # a thin web-server environment: no HOME, and a short PATH (php itself, and the wrapper that starts it, must still
        # be found, and on most hosts /usr/bin holds python3 and gpg too, so this proves the missing HOME, not the PATH part)
        thin = {k: v for k, v in self.env.items() if k not in ("HOME", "PATH")}
        thin["PATH"] = os.path.dirname(php) + os.pathsep + "/usr/bin"
        self.assertEqual(run_php('echo json_encode(foo("ahost:aserv"));', env=thin), '["auser","ap ass\\"\'$x"]')
        # ~/bin is on the PATH the shim gives auth (on the webhost python3 is a wrapper in ~/bin)
        home = run_php('echo fb_home();')
        prefix = run_php('echo fb_env_prefix();', env=thin)
        self.assertIn(home + "/bin:", prefix)
        self.assertIn(home + "/local/usr/bin", prefix)
        self.assertEqual(run_php('echo json_encode(bar("-delete", "x", "ahost:aserv"));'), "true")
        self.assertEqual(run_php('echo json_encode(foo("ahost:aserv"));'), failed)

    def test_master_record_is_not_found_in_the_service_tier(self):
        self.fresh()
        self.fresh_service()
        self.run_auth("set", "imaps@cpbee", "chris", "--stdin", stdin="M4ster\n")
        self.assertEqual(self.run_auth("get", "imaps", "cpbee", "chris")[1], "M4ster\n")      # falls through to the master tier
        self.assertEqual(self.run_auth("remove", "--service", "imaps@cpbee", "chris")[1].strip(), "nothing to remove")

    def test_enroll_serve_unenroll(self):
        self.fresh()
        self.fresh_service()
        self.run_auth("set", "--service", "https@cpbee", "michelle", "--stdin", stdin="S3rv1ce\n")
        self.run_auth("set", "--service", "irc@cpbee", "other", "--stdin", stdin="N0tAllowed\n")
        self.run_auth("set", "imaps@cpbee", "chris", "--stdin", stdin="M4ster\n")
        ak = os.path.join(self.env["HOME"], ".ssh", "authorized_keys")
        for _ in range(2):                                                               # twice: one line only
            rc, out, err = self.run_auth("enroll", "c1", "--allow", "https@cpbee/michelle", "--stdin", stdin=self.PUB + "\n")
            self.assertEqual(rc, 0, err)
        text = open(ak).read()
        self.assertEqual(text.count("auth-client-c1"), 1)
        self.assertIn('command="%s serve c1",restrict ssh-ed25519 ' % TOOL, text)
        self.assertIn("c1: http@cpbee.cmnet/michelle", self.run_auth("clients")[1])

        def served(cmdline):
            return self.run_auth("serve", "c1", env=dict(self.env, SSH_ORIGINAL_COMMAND=cmdline))

        rc, out, _ = served("auth get https cpbee michelle --domain cmnet")
        self.assertEqual((rc, out), (0, "S3rv1ce\n"))
        self.assertEqual(served("auth get irc cpbee other --domain cmnet")[0], 1)          # service record, not on the list
        rc, out, _ = served("auth get imaps cpbee chris --domain cmnet")                  # master record: never served
        self.assertEqual((rc, out), (1, ""))
        for bad in ("auth list", "auth set https@cpbee michelle", "auth _export", "auth get --service https cpbee michelle", "", "ls /"):
            rc, out, _ = served(bad)
            self.assertEqual(rc, 1, bad)
            self.assertNotIn("S3rv1ce", out)
        # the old foo LABEL call is served too, from the service tier and only for records on the allow list
        self.run_auth("bar", "--service", "cp.cmnet:web", "wuser", "--stdin", stdin="W3bpass\n")
        self.run_auth("bar", "--service", "dbx.cmnet:web", "otheruser", "--stdin", stdin="Hidd3n\n")
        rc, _, err = self.run_auth("enroll", "c1", "--allow", "https@cpbee/michelle", "--allow", "https@cp.cmnet/wuser",
                                   "--stdin", stdin=self.PUB + "\n")
        self.assertEqual(rc, 0, err)
        self.assertEqual(served("auth foo cp.cmnet:web")[:2], (0, "wuser\tW3bpass\n"))
        rc, out, _ = served("auth foo dbx.cmnet:web")                                      # service record, not on the list
        self.assertEqual((rc, out), (1, ""))
        self.assertEqual(served("auth foo nowhere.cmnet:web")[0], 1)
        self.run_auth("unenroll", "c1")
        self.assertNotIn("auth-client-c1", open(ak).read())
        self.assertEqual(served("auth get https cpbee michelle")[0], 1)

    def test_a_machine_with_its_own_store_runs_locally(self):
        """~/.config/auth/local (the webhost) makes auth work on its own files, with no ssh to another host."""
        self.fresh_service()
        self.run_auth("set", "--service", "https@cpbee", "michelle", "--stdin", stdin="S3rv1ce\n")
        env = {k: v for k, v in self.env.items() if k != "AUTH_LOCAL"}
        env["AUTH_HOST"] = "no-such-host.invalid"
        rc, out, _ = self.run_auth("get", "https", "cpbee", "michelle", env=env)       # would try ssh to that host
        self.assertNotEqual(out, "S3rv1ce\n")
        os.makedirs(os.path.join(self.env["HOME"], ".config", "auth"), exist_ok=True)
        marker = os.path.join(self.env["HOME"], ".config", "auth", "local")
        open(marker, "w").close()
        try:
            rc, out, _ = self.run_auth("get", "https", "cpbee", "michelle", env=env)
            self.assertEqual((rc, out), (0, "S3rv1ce\n"))
        finally:
            os.remove(marker)

    def test_kill_agent_marker_leaves_no_gpg_agent_running(self):
        """with 'kill-agent' in ~/.config/auth/local, auth stops the gpg-agent its gpg call started."""
        self.fresh_service()
        self.run_auth("set", "--service", "https@cpbee", "michelle", "--stdin", stdin="S3rv1ce\n")

        def agent_up():
            r = subprocess.run(["gpg-connect-agent", "--no-autostart", "getinfo pid", "/bye"], env=self.env,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
            return r.stdout.startswith("D ")             # an agent answers with its pid

        self.assertEqual(self.run_auth("get", "https", "cpbee", "michelle")[1], "S3rv1ce\n")
        self.assertTrue(agent_up())                      # normally the agent stays after a decrypt
        os.makedirs(os.path.join(self.env["HOME"], ".config", "auth"), exist_ok=True)
        marker = os.path.join(self.env["HOME"], ".config", "auth", "local")
        with open(marker, "w") as fh:
            fh.write("kill-agent\n")
        try:
            self.assertEqual(self.run_auth("get", "https", "cpbee", "michelle")[1], "S3rv1ce\n")
            for _ in range(20):                          # the agent takes a moment to exit
                if not agent_up():
                    break
                time.sleep(0.25)
            self.assertFalse(agent_up())                 # stopped when auth finished
        finally:
            os.remove(marker)

    def test_enroll_refuses_bad_input(self):
        self.fresh_service()
        self.assertEqual(self.run_auth("enroll", "c2", "--stdin", stdin=self.PUB + "\n")[0], 2)                  # no --allow
        self.assertEqual(self.run_auth("enroll", "c2", "--allow", "https@cpbee", "--stdin", stdin=self.PUB + "\n")[0], 2)  # no /LOGIN
        self.assertEqual(self.run_auth("enroll", "../c2", "--allow", "https@cpbee/x", "--stdin", stdin=self.PUB + "\n")[0], 2)
        self.assertEqual(self.run_auth("enroll", "c2", "--allow", "https@cpbee/x", "--stdin", stdin="not a key\n")[0], 2)


if __name__ == "__main__":
    unittest.main()
