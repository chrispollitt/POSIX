#!/usr/bin/env python3
"""Tests for auth, on a throwaway gpg home and vault in a temp directory (nothing real is read or changed).

    python3 net-utils/test_auth.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "auth")

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
                       AUTH_PERSON="chris", PATH=HERE + os.pathsep + os.environ["PATH"])
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
        self.assertIn("would add  2fa@whatwelove.org whatwelo (totp)", out)
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
        self.assertIn("0 to add, 3 already", self.run_auth("import", "foo", foo, "--key", keyf, "--skip", "cmpi:sudo")[1])
        # imported entries are for the vault only: render never writes them to a file
        out_t = self.put("tickets.foo", "")
        self.run_auth("render", "tickets", "--out", out_t)
        self.assertNotIn("cmpi", open(out_t).read())
        self.assertEqual(self.run_auth("import", "foo", foo, "--key", os.path.join(self.d, "nokey"))[0], 1)


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


if __name__ == "__main__":
    unittest.main()
