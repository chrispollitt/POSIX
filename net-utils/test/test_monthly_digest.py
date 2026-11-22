#!/usr/bin/env python3
"""Tests for net-utils/monthly-digest: the parsers, a failing section, and the whole run on any machine."""
import calendar
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "monthly-digest")


def load():
    loader = importlib.machinery.SourceFileLoader("monthly_digest", TOOL)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


md = load()


class TestParsers(unittest.TestCase):
    def test_count_articles_from_an_inn_active_file(self):
        active = ("control 0000000000 0000000001 n\n"          # empty group
                  "lan.misc 0000000012 0000000003 y\n"          # 10 articles
                  "comp.lang.c 0000001000 0000000001 n\n"       # 1000
                  "broken line\n"
                  "lan.talk 0000000000 0000000001 y\n")
        self.assertEqual(md.count_articles(active), (4, 1010, 10))

    def test_cert_days_left(self):
        now = calendar.timegm(time.strptime("2026-11-21", "%Y-%m-%d"))
        self.assertEqual(md.cert_days_left("notAfter=Nov 29 00:00:00 2026 GMT", now), 8)
        self.assertLess(md.cert_days_left("notAfter=Nov  1 00:00:00 2026 GMT", now), 0)
        self.assertGreater(md.cert_days_left("notAfter=Mar 19 23:08:15 2031 GMT", now), 1500)


class TestDigest(unittest.TestCase):
    def test_a_failing_section_is_reported_and_the_rest_goes_on(self):
        d = md.Digest("1 month ago")

        def boom():
            raise RuntimeError("no way")
        d.section("Broken", boom)
        d.section("Fine", lambda: d.line("  all good"))
        text = "\n".join(d.out)
        self.assertIn("(this section failed: RuntimeError: no way)", text)
        self.assertIn("all good", text)
        self.assertTrue(any("Broken" in w for w in d.attention))

    def test_the_whole_run_prints_the_headings_and_exits_0(self):
        env = dict(os.environ, DIGEST_NEWS_ACTIVE="/nonexistent", DIGEST_REPORT_LOG="/nonexistent")
        r = subprocess.run([sys.executable, TOOL], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, universal_newlines=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        for h in ("monthly digest:", "== Needs a look ==", "== System ==", "== Updates ==", "== Services ==", "== Mail ==",
                  "== Usenet ==", "== Security ==", "== Certificates =="):
            self.assertIn(h, r.stdout)

    def test_usenet_counts_come_from_the_active_file(self):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            act = os.path.join(t, "active")
            open(act, "w").write("lan.misc 0000000012 0000000003 y\ncomp.x 0000000100 0000000001 n\n")
            env = dict(os.environ, DIGEST_NEWS_ACTIVE=act, DIGEST_REPORT_LOG=os.path.join(t, "none"))
            r = subprocess.run([sys.executable, TOOL], stdout=subprocess.PIPE, env=env, universal_newlines=True)
            self.assertIn("2 groups, 110 articles (10 in lan.*", r.stdout)

    def test_mail_mode_builds_a_message_for_sendmail(self):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            fake = os.path.join(t, "sendmail")
            out = os.path.join(t, "mail.txt")
            open(fake, "w").write("#!/bin/sh\ncat > '%s'\n" % out)
            os.chmod(fake, 0o755)
            env = dict(os.environ, PATH=t + os.pathsep + os.environ["PATH"], DIGEST_NEWS_ACTIVE="/nonexistent")
            r = subprocess.run([sys.executable, TOOL, "--mail", "someone@example.org"], env=env, stderr=subprocess.PIPE,
                               universal_newlines=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            mail = open(out).read()
            self.assertIn("To: someone@example.org", mail)
            self.assertIn("Subject: ", mail)
            self.assertIn("monthly digest,", mail)
            self.assertIn("Auto-Submitted: auto-generated", mail)
            self.assertIn("== Needs a look ==", mail)


if __name__ == "__main__":
    unittest.main()
