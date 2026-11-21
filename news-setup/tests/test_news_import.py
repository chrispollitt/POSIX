#!/usr/bin/env python3
"""Tests for news-setup/bin/news-import against a fake innd.

    python3 news-setup/tests/test_news_import.py
"""
import gzip
import importlib.machinery
import importlib.util
import io
import os
import shutil
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from fake_innd import FakeInnd  # noqa: E402

_loader = importlib.machinery.SourceFileLoader("news_import", str(HERE.parent / "bin" / "news-import"))
_spec = importlib.util.spec_from_loader("news_import", _loader)
ni = importlib.util.module_from_spec(_spec)
_loader.exec_module(ni)


def art(groups="comp.lang.c", subj="Hello", body="body line\n", mid="<a1@x.org>", extra="", date="Mon, 01 Sep 1986 10:00:00 +0000",
        path="utzoo!henry"):
    h = "From: henry@utzoo\nNewsgroups: %s\nSubject: %s\n" % (groups, subj)
    if mid:
        h += "Message-ID: %s\n" % mid
    if date:
        h += "Date: %s\n" % date
    if path:
        h += "Path: %s\n" % path
    return (h + extra + "\n" + body).encode("latin-1")


def mbox(*arts):
    out = b""
    for i, a in enumerate(arts):
        out += b"From henry@utzoo Mon Sep  1 10:0%d:00 1986\n" % i + a + b"\n"
    return out


class Args(object):
    def __init__(self, sources, port, **kw):
        self.sources = sources
        self.groups = None
        self.host = "127.0.0.1"
        self.port = port
        self.state = None
        self.no_state = True
        self.limit = 0
        self.dry_run = False
        self.keep_control = False
        self.verbose = False
        self.__dict__.update(kw)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="news-import-"))
        self.addCleanup(shutil.rmtree, str(self.tmp), True)

    def headers(self, wire):
        head = wire.split(b"\n\n", 1)[0].decode("latin-1")
        return dict(l.split(": ", 1) for l in head.split("\n") if ": " in l and not l.startswith((" ", "\t")))


class TestRepair(Base):
    def test_a_good_article_is_left_alone(self):
        wire, mid, notes = ni.repair(art())
        self.assertEqual((mid, notes), (b"<a1@x.org>", []))
        h = self.headers(wire)
        self.assertEqual(h["Path"], "utzoo!henry")
        self.assertEqual(h["Date"], "Mon, 01 Sep 1986 10:00:00 +0000")
        self.assertTrue(wire.endswith(b"\n\nbody line\n"))

    def test_missing_message_id_path_subject_from(self):
        raw = b"Newsgroups: net.jokes\nDate: Sat, 7 Mar 87 10:00:00 PST\n\nfunny\n"
        wire, mid, notes = ni.repair(raw)
        h = self.headers(wire)
        self.assertTrue(MID_OK(mid), mid)
        self.assertEqual(h["Message-ID"], mid.decode())
        self.assertEqual(h["Path"], "archive!not-for-mail")
        self.assertEqual(h["Subject"], "(none)")
        self.assertEqual(h["From"], "unknown@archive.invalid")
        self.assertTrue({"message-id", "path", "subject", "from"} <= set(notes))
        self.assertEqual(ni.repair(raw)[1], mid)                         # the same article always gets the same id

    def test_two_digit_year_and_zone_name_are_made_readable(self):
        wire, mid, notes = ni.repair(art(date="Sat, 7 Mar 87 10:00:00 PST"))
        h = self.headers(wire)
        self.assertEqual(h["Date"], "Sat, 07 Mar 1987 10:00:00 -0800")
        self.assertEqual(h["X-Original-Date"], "Sat, 7 Mar 87 10:00:00 PST")
        self.assertIn("date-format", notes)

    def test_an_unreadable_date_takes_the_mbox_from_line_then_a_fallback(self):
        data = mbox(art(date="Sat 7 Mar 87 25:99 PST"))
        raw = ni.split_mbox(data)[0]
        wire, mid, notes = ni.repair(raw)
        h = self.headers(wire)
        self.assertIn("1986", h["Date"])                                  # from "From henry@utzoo Mon Sep  1 10:00:00 1986"
        self.assertEqual(h["X-Original-Date"], "Sat 7 Mar 87 25:99 PST")
        wire, mid, notes = ni.repair(art(date="whenever"))
        self.assertEqual(self.headers(wire)["Date"], ni.FALLBACK_DATE)
        wire, mid, notes = ni.repair(art(date=None))
        self.assertEqual(self.headers(wire)["Date"], ni.FALLBACK_DATE)

    def test_control_messages_cannot_do_anything(self):
        wire, mid, notes = ni.repair(art(extra="Control: newgroup comp.evil\nSupersedes: <old@x>\nXref: s a:1\nApproved: me\n"))
        h = self.headers(wire)
        for k in ("Control", "Supersedes", "Xref", "Approved"):
            self.assertNotIn(k, h)
        self.assertEqual(h["X-Original-Control"], "newgroup comp.evil")
        self.assertEqual(h["X-Original-Supersedes"], "<old@x>")
        wire, mid, notes = ni.repair(art(extra="Control: cancel <x@y>\n"), keep_control=True)
        self.assertEqual(self.headers(wire)["Control"], "cancel <x@y>")

    def test_only_the_wanted_groups_stay(self):
        keep = ni.wanted_groups("# my groups\ncomp.lang.c  the language\nrec.*\n")
        wire, mid, notes = ni.repair(art(groups="comp.lang.c,talk.bizarre,rec.humor"), keep)
        h = self.headers(wire)
        self.assertEqual(h["Newsgroups"], "comp.lang.c,rec.humor")
        self.assertEqual(h["X-Original-Newsgroups"], "comp.lang.c,talk.bizarre,rec.humor")
        self.assertEqual(ni.repair(art(groups="talk.bizarre"), keep), (None, None, "not wanted"))

    def test_what_cannot_be_posted(self):
        self.assertEqual(ni.repair(b"just some text\n")[2], "no headers")
        self.assertEqual(ni.repair(b"From: a@b\nSubject: s\n\nx\n")[2], "no Newsgroups header")
        self.assertEqual(ni.repair(art(groups="bad group!"))[2], "bad group name")

    def test_folded_headers_and_dots_survive(self):
        wire, mid, notes = ni.repair(art(subj="a long\n subject", body=".dot\nx\n"))
        self.assertIn(b"Subject: a long\n subject\n", wire)
        self.assertTrue(wire.endswith(b"\n\n.dot\nx\n"))


def MID_OK(mid):
    return mid.startswith(b"<") and mid.endswith(b"@archive.invalid>") and len(mid) > 20


class TestSources(Base):
    def collect(self, paths, stdin=None):
        return [a for _, a in ni.iter_sources([str(p) for p in paths], stdin)]

    def test_mbox_gz_zip_tar_directory_rnews(self):
        a1, a2 = art(mid="<1@x>"), art(mid="<2@x>")
        (self.tmp / "m.mbox").write_bytes(mbox(a1, a2))
        self.assertEqual(len(self.collect([self.tmp / "m.mbox"])), 2)
        with gzip.open(str(self.tmp / "m.mbox.gz"), "wb") as f:
            f.write(mbox(a1, a2))
        self.assertEqual(len(self.collect([self.tmp / "m.mbox.gz"])), 2)
        with zipfile.ZipFile(str(self.tmp / "m.zip"), "w") as z:
            z.writestr("comp.lang.c.mbox", mbox(a1, a2))
        self.assertEqual(len(self.collect([self.tmp / "m.zip"])), 2)
        with tarfile.open(str(self.tmp / "t.tar.gz"), "w:gz") as t:
            for i, a in enumerate((a1, a2)):
                ti = tarfile.TarInfo("comp.lang.c/%d" % (i + 1))
                ti.size = len(a)
                t.addfile(ti, io.BytesIO(a))
        self.assertEqual(len(self.collect([self.tmp / "t.tar.gz"])), 2)
        d = self.tmp / "spool" / "comp" / "lang"
        d.mkdir(parents=True)
        (d / "1").write_bytes(a1)
        (d / "2").write_bytes(a2)
        self.assertEqual(len(self.collect([self.tmp / "spool"])), 2)
        batch = b"".join(b"#! rnews %d\n" % len(a) + a for a in (a1, a2))
        self.assertEqual(self.collect(["-"], io.BytesIO(batch)), [a1, a2])

    def test_mbox_from_line_needs_a_blank_line_before_it(self):
        body = b"text\nFrom here on it is quoted\n"
        parts = ni.split_mbox(mbox(art(body=body.decode())))
        self.assertEqual(len(parts), 1)
        self.assertIn(b"From here on", parts[0])


class TestRun(Base):
    def setUp(self):
        super().setUp()
        self.srv = FakeInnd()
        self.addCleanup(self.srv.stop)

    def go(self, sources, **kw):
        out, err = io.StringIO(), io.StringIO()
        kw.setdefault("port", self.srv.port)
        st = ni.run(Args([str(s) for s in sources], **kw), out, err)
        return st, out.getvalue(), err.getvalue()

    def test_offers_accepts_and_reports(self):
        (self.tmp / "m.mbox").write_bytes(mbox(art(mid="<1@x>"), art(mid="<2@x>", body=".leading dot\nx\n"), art(mid=None, path=None)))
        st, out, err = self.go([self.tmp / "m.mbox"])
        self.assertEqual(st, 0, err)
        self.assertIn("read 3: offered 3 (1 repaired): accepted 3", out)
        self.assertEqual([m for m, _ in self.srv.accepted][:2], [b"<1@x>", b"<2@x>"])
        self.assertIn(b"\n.leading dot\n", self.srv.accepted[1][1])           # dot-stuffing did not leak into the article
        self.assertNotIn(b"X-Mbox-From", self.srv.accepted[0][1])

    def test_duplicates_are_not_errors_and_rejections_are(self):
        self.srv.have = {b"<1@x>"}
        self.srv.reject = {b"<2@x>": "no such group"}
        (self.tmp / "m.mbox").write_bytes(mbox(art(mid="<1@x>"), art(mid="<2@x>"), art(mid="<3@x>")))
        st, out, err = self.go([self.tmp / "m.mbox"], verbose=True)
        self.assertEqual(st, 1)
        self.assertIn("accepted 1, already there 1, rejected 1", out)
        self.assertIn("437 no such group", out)
        self.assertIn("rejected <2@x>", err)

    def test_a_busy_server_is_asked_again(self):
        self.srv.busy = {b"<1@x>": 1}
        (self.tmp / "m.mbox").write_bytes(mbox(art(mid="<1@x>")))
        st, out, err = self.go([self.tmp / "m.mbox"])
        self.assertEqual(st, 0, err)
        self.assertIn("accepted 1", out)
        self.assertEqual(self.srv.offers, [b"<1@x>", b"<1@x>"])

    def test_resume_state_skips_what_was_done(self):
        (self.tmp / "m.mbox").write_bytes(mbox(art(mid="<1@x>"), art(mid="<2@x>")))
        state = self.tmp / "state"
        self.go([self.tmp / "m.mbox"], state=str(state), no_state=False, limit=1)
        self.assertEqual(len(self.srv.accepted), 1)
        st, out, err = self.go([self.tmp / "m.mbox"], state=str(state), no_state=False)
        self.assertEqual(st, 0)
        self.assertIn("accepted 1", out)
        self.assertIn("done before 1", out)
        self.assertEqual([m for m, _ in self.srv.accepted], [b"<1@x>", b"<2@x>"])
        n = len(self.srv.offers)
        self.go([self.tmp / "m.mbox"], state=str(state), no_state=False)
        self.assertEqual(len(self.srv.offers), n)                          # a third run offers nothing

    def test_groups_file_and_dry_run(self):
        (self.tmp / "g.list").write_text("comp.*\n")
        (self.tmp / "m.mbox").write_bytes(mbox(art(groups="comp.lang.c", mid="<1@x>"), art(groups="talk.bizarre", mid="<2@x>")))
        st, out, err = self.go([self.tmp / "m.mbox"], groups=str(self.tmp / "g.list"), dry_run=True, port=1)
        self.assertEqual(st, 0, err)                                       # no connection is made at all
        self.assertIn("would offer 1", out)
        self.assertIn("skipped 1", out)
        self.assertIn("not wanted", out)
        self.assertEqual(self.srv.offers, [])

    def test_an_unreachable_server_is_exit_2(self):
        (self.tmp / "m.mbox").write_bytes(mbox(art()))
        st, out, err = self.go([self.tmp / "m.mbox"], port=1)
        self.assertEqual(st, 2)
        self.assertIn("cannot reach", err)


# the shape of ~/Downloads/usenet-historic-posts.zip: a file per thread, "Newsgroup:" singular, a From of
# "addr Name" in any order, ISO dates, ids without a host, articles told apart by a line of ==========
GG = (
    "Newsgroup: comp.os.minix\r\nFrom: ast@cs.vu.nl Andy Tanenbaum\r\nDate: 1992-01-29T07:12:50.000Z\r\n"
    "Subject: LINUX is obsolete\r\nMessage-ID: <12595@star.cs.vu.nl>\r\n\r\n\r\nI was in the U.S.\r\n"
    "\r\n\n==========\n\n"
    "Newsgroup: comp.os.minix\nFrom: rms@mit-oz @mit-eddie.UUCP (Richard Stallman\nDate: 1992-01-29T09:00:00Z\n"
    "Subject: Re: LINUX is obsolete\nMessage-ID: <anews.Aucbonyx.118>\n\n>I was in the U.S.\nCafé society.\n"
    "\n==========\n\n"
    "Newsgroup: alt.test,comp.os.minix\nFrom: cs...@lcanter.win.net\nDate: not a date\nSubject: ads\n\nbuy\n"
    "\n==========\n"
).encode("utf-8")


class TestPlainTextFormat(Base):
    def articles(self):
        p = self.tmp / "thread.txt"
        p.write_bytes(GG)
        return [a for _, a in ni.iter_sources([str(p)])]

    def test_one_file_is_three_articles_and_the_separator_is_gone(self):
        arts = self.articles()
        self.assertEqual(len(arts), 3)
        self.assertTrue(all(b"=====" not in a and b"\r" not in a for a in arts))

    def test_headers_are_made_news_headers(self):
        h = [self.headers(ni.repair(a)[0]) for a in self.articles()]
        self.assertEqual(h[0]["Newsgroups"], "comp.os.minix")
        self.assertEqual(h[0]["From"], '"Andy Tanenbaum" <ast@cs.vu.nl>')
        self.assertEqual(h[0]["X-Original-From"], "ast@cs.vu.nl Andy Tanenbaum")
        self.assertEqual(h[0]["Date"], "Wed, 29 Jan 1992 07:12:50 +0000")
        self.assertEqual(h[0]["Message-ID"], "<12595@star.cs.vu.nl>")
        self.assertEqual(h[1]["From"], '"Richard Stallman" <rms@mit-oz>')                    # a broken From is read
        self.assertEqual(h[1]["Message-ID"], "<anews.Aucbonyx.118@archive.invalid>")         # an id with no host gets one
        self.assertEqual(h[2]["From"], "cs@lcanter.win.net")                                 # the mask "..." goes
        self.assertEqual(h[2]["Date"], "Tue, 01 Jan 1980 00:00:00 +0000")                      # an unreadable date: the fallback
        self.assertEqual(h[2]["X-Original-Date"], "not a date")
        self.assertEqual(h[2]["Newsgroups"], "alt.test,comp.os.minix")

    def test_a_reply_is_threaded_under_the_first_article_and_text_is_clean(self):
        arts = self.articles()
        h1 = self.headers(ni.repair(arts[1])[0])
        self.assertEqual(h1["References"], "<12595@star.cs.vu.nl>")
        self.assertIn("X-Archive-Thread", h1)
        self.assertNotIn("References", self.headers(ni.repair(arts[0])[0]))
        self.assertNotIn("References", self.headers(ni.repair(arts[2])[0]))                  # not a Re:
        self.assertEqual(ni.split_article(arts[0])[1], b"I was in the U.S.\n\n")
        self.assertIn("charset=utf-8", self.headers(arts[1])["Content-Type"])                # 8-bit text says so
        self.assertNotIn("Content-Type", self.headers(arts[0]))

    def test_non_ascii_names_and_subjects_become_encoded_words(self):
        v, changed = ni.gg_from("jose@x.es José Núñez")
        self.assertTrue(changed)
        self.assertRegex(v, r"^=\?utf-8\?[bq]\?.+\?= <jose@x\.es>$")
        self.assertEqual(ni.gg_from("Henry Spencer <henry@utzoo.uucp>"), ("Henry Spencer <henry@utzoo.uucp>", False))
        self.assertEqual(ni.gg_from("bob@x.org (Bob)"), ("bob@x.org (Bob)", False))
        self.assertEqual(ni.gg_from("just a name")[0], '"just a name" <just@archive.invalid>')

    def test_a_truncated_thread_banner_is_ignored_and_first_group_counts_only_the_first(self):
        p = self.tmp / "banner.txt"
        p.write_bytes(b"[Thread has 50 posts; first 40 shown]\n\n" + GG)
        arts = [a for _, a in ni.iter_sources([str(p)])]
        self.assertEqual(len(arts), 3)
        self.assertTrue(arts[0].startswith(b"Newsgroups: comp.os.minix\n"))
        out = io.StringIO()
        ni.run(Args([str(p)], 0, list_groups=True, first_group=True), out)
        self.assertEqual(out.getvalue(), "comp.os.minix  2\nalt.test  1\n")

    def test_list_groups_and_the_whole_run(self):
        p = self.tmp / "thread.txt"
        p.write_bytes(GG)
        out = io.StringIO()
        self.assertEqual(ni.run(Args([str(p)], 0, list_groups=True), out), 0)
        self.assertEqual(out.getvalue(), "comp.os.minix  3\nalt.test  1\n")
        srv = FakeInnd()
        self.addCleanup(srv.stop)
        out, err = io.StringIO(), io.StringIO()
        self.assertEqual(ni.run(Args([str(p)], srv.port), out, err), 0, err.getvalue())
        self.assertIn("read 3: offered 3 (3 repaired): accepted 3", out.getvalue())
        self.assertEqual(srv.accepted[1][0], b"<anews.Aucbonyx.118@archive.invalid>")


if __name__ == "__main__":
    unittest.main()
