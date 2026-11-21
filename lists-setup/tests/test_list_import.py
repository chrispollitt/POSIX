#!/usr/bin/env python3
"""Tests for lists-setup's list-import: the old date and address forms, the three splitters, what a converted message
looks like, and where messages go (mbox, a command, a state file).

    python3 tests/test_list_import.py
"""
import datetime
import importlib.machinery
import importlib.util
import mailbox
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
BIN = HERE.parent / "bin"
sys.path.insert(0, str(BIN))
_loader = importlib.machinery.SourceFileLoader("list_import", str(BIN / "list-import"))
_spec = importlib.util.spec_from_loader("list_import", _loader)
li = importlib.util.module_from_spec(_spec)
_loader.exec_module(li)

ARPA = """Date: 15 SEP 1979 2216-PDT
From: LSTEWART at PARC-MAXC
Subject: "Demon Breed"
To:   SF-Lovers:

For the James H. Schmitz fans out there
	"Demon Breed" is out in Paperback!
-------

Date: 18 Sep 1979 9:25 am (Tuesday)
From: Brodie at PARC-MAXC
Subject: Star Trek: The Motion Picture
To: Science Fiction Lovers <SF^>

It opens December 9.


Date: 18 Sep 1979 1331-EDT
From: PDL at MIT-DMS (P. David Lebling)
To: Brodie at PARC-MAXC
Cc: SF-LOVERS at MIT-AI
In-reply-to: Message of 18 Sep 79 at 0000 EDT by Brodie@PARC-MAXC
Subject: [Re: SF Magazines]
Message-id: <[MIT-DMS].123170>

F&SF is better than IASFM.
Not a Date: line in the text.
-------

Date: not a date
From: Andrew Knutsen <csd.knutsen at SU-SCORE>
Subject: unreadable date

after the one before.
"""

BABYL = ("BABYL OPTIONS:\nVersion: 5\nLabels:\nNote:   header of an rmail file.\n\x1f\x0c\n1, edited,,\n"
         "Received: from ibm.com by elbereth.rutgers.edu id AA17297; Thu, 2 Mar 89 19:02:32 EST\n"
         "Date: Thu, 2 Mar 89 19:02:32 EST\nFrom: BROWN@ibm.com\nMessage-Id: <8903030002.AA17297@elbereth.rutgers.edu>\n\n"
         "*** EOOH ***\nDate:  6 Jan 88 0837-EST\nFrom: Saul Jaffe (The Moderator) <SF-Lovers-Request@Red.Rutgers.Edu>\n"
         "Subject: SF-LOVERS Digest   V13 #1\n\n\nSF-LOVERS Digest  Volume 13 : Issue 1\n\nToday's Topics:\n   Books\n\n"
         "----------------------------------------------------------------------\n\nDate: 5 Jan 88\nFrom: Saul\n\nHello.\n\x1f"
         "\x0c\n1,,\nDate: Mon, 10 Jan 2000 11:36:58 -0500\nMessage-Id: <200001101636.LAA24941@sflovers.rutgers.edu>\n"
         "From: Saul Jaffe <sf-lovers-request@sflovers.rutgers.edu>\nSubject: SF-LOVERS Digest   V25 #1\n\n"
         "*** EOOH ***\nDate: Mon, 10 Jan 2000 11:36:58 -0500\nFrom: Saul Jaffe <sf-lovers-request@sflovers.rutgers.edu>\n"
         "Subject: SF-LOVERS Digest   V25 #1\n\nY2K digest.\n\x1f")

DOC = ("THE CYPHERNOMICON\n\n1. Introduction\n \n1.1. copyright\n   all rights reserved.\n"
       "1.2. Foreword\n- The Cypherpunks have existed since 1992.\n \n2. MFAQ--Most Frequently Asked Questions\n \n"
       "2.1. What is this?\n   An answer.\n")


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="list-import-"))

    def tearDown(self):
        import shutil
        shutil.rmtree(str(self.tmp), ignore_errors=True)

    def write(self, name, text):
        p = self.tmp / name
        p.write_text(text, encoding="utf-8")
        return str(p)

    def conv(self, text, name="x.txt", **kw):
        return li.convert("sf-lovers", "cpbee.cmnet", self.write(name, text), **kw)

    def msgs(self, conv):
        import email
        import email.policy
        return [email.message_from_bytes(raw, policy=email.policy.default) for raw, _, _ in conv]


class TestParsing(Base):
    def test_old_date_forms(self):
        d = li.parse_date
        self.assertEqual(d("15 SEP 1979 2216-PDT").isoformat(), "1979-09-15T22:16:00-07:00")
        self.assertEqual(d(" 6 Jan 88 0837-EST").isoformat(), "1988-01-06T08:37:00-05:00")
        self.assertEqual(d("18 Sep 1979 9:25 am (Tuesday)").isoformat(), "1979-09-18T09:25:00+00:00")     # no usable zone
        self.assertEqual(d("5 Jan 88 10:00:10 EST").isoformat(), "1988-01-05T10:00:10-05:00")
        self.assertEqual(d("Mon, 10 Jan 2000 11:36:58 -0500").isoformat(), "2000-01-10T11:36:58-05:00")
        self.assertEqual(d("Thu, 2 Mar 89 19:02:32 EST").isoformat(), "1989-03-02T19:02:32-05:00")
        self.assertEqual(d("1 Feb 2001 1:05 pm").isoformat(), "2001-02-01T13:05:00+00:00")
        self.assertEqual(d("12 Dec 1999 12:30 am").hour, 0)
        self.assertEqual(d("3 Mar 65 10:00").year, 2065)                                      # two digits: 70-99 are 19xx
        for bad in ("", "not a date", "31 Foo 1999", "32 Jan 1999 00:00", None):
            self.assertIsNone(d(bad), bad)

    def test_addresses(self):
        a = li.make_address
        self.assertEqual(a("LSTEWART at PARC-MAXC"), ("LSTEWART", "LSTEWART@PARC-MAXC.invalid"))
        self.assertEqual(a("PDL at MIT-DMS (P. David Lebling)"), ("P. David Lebling", "PDL@MIT-DMS.invalid"))
        self.assertEqual(a("ZIM, YEKTA at MIT-MC"), ("ZIM, YEKTA", "ZIM.YEKTA@MIT-MC.invalid"))
        self.assertEqual(a("Andrew Knutsen <csd.knutsen at SU-SCORE>"), ("Andrew Knutsen", "csd.knutsen@SU-SCORE.invalid"))
        self.assertEqual(a("Saul Jaffe (The Moderator) <x@y.org>")[1], "x@y.org")
        self.assertEqual(a("BROWN@ibm.com"), ("", "BROWN@ibm.com"))
        self.assertEqual(a("Sapsford"), ("Sapsford", "Sapsford@archive.invalid"))
        self.assertEqual(a("")[1], "unknown@archive.invalid")

    def test_headers_fold_and_lookup(self):
        h = li.parse_headers("Subject: a\n   b\nFrom: x\nnot a header line\nTo:  y ")
        self.assertEqual(li.header(h, "subject"), "a b")
        self.assertEqual((li.header(h, "TO"), li.header(h, "cc")), ("y", ""))

    def test_formats_are_detected(self):
        self.assertEqual(li.detect_format(ARPA), "arpa")
        self.assertEqual(li.detect_format(BABYL), "babyl")
        self.assertEqual(li.detect_format(DOC), "sections")


class TestSplitters(Base):
    def test_arpa_splits_on_date_from_pairs_not_on_dates_in_the_text(self):
        recs = li.split_arpa(ARPA)
        self.assertEqual(len(recs), 4)
        self.assertEqual(li.header(recs[0][0], "subject"), '"Demon Breed"')
        self.assertIn("Not a Date: line in the text.", recs[2][1])
        self.assertEqual(li.header(recs[2][0], "message-id"), "<[MIT-DMS].123170>")

    def test_babyl_uses_the_header_after_eooh_and_each_record_is_one_message(self):
        recs = li.split_babyl(BABYL)
        self.assertEqual(len(recs), 2)
        self.assertEqual(li.header(recs[0][0], "subject"), "SF-LOVERS Digest   V13 #1")
        self.assertEqual(li.header(recs[0][0], "message-id"), "<8903030002.AA17297@elbereth.rutgers.edu>")   # from before EOOH
        self.assertIn("Today's Topics:", recs[0][1])
        self.assertIn("Date: 5 Jan 88", recs[0][1])                                           # the digest stays whole
        self.assertEqual(li.header(recs[1][0], "date"), "Mon, 10 Jan 2000 11:36:58 -0500")

    def test_sections_keep_top_level_headings_with_the_section_after_them(self):
        s = li.split_sections(DOC)
        self.assertEqual([(n, t) for n, t, _ in s], [("1.1", "copyright"), ("1.2", "Foreword"), ("2.1", "What is this?")])
        self.assertTrue(s[0][2].startswith("THE CYPHERNOMICON\n\n1. Introduction"))
        self.assertTrue(s[2][2].startswith("2. MFAQ--Most Frequently Asked Questions"))
        self.assertNotIn("2. MFAQ", s[1][2])
        self.assertEqual("".join(t for _, _, t in s).count("all rights reserved"), 1)


class TestConvert(Base):
    def test_a_message_is_what_mlmmj_would_have_delivered(self):
        conv = self.conv(ARPA)
        m = self.msgs(conv)[0]
        self.assertEqual(m["Subject"], '[sf-lovers] "Demon Breed"')
        self.assertEqual(str(m["From"]), "LSTEWART <LSTEWART@PARC-MAXC.invalid>")
        self.assertEqual(m["To"], "sf-lovers@cpbee.cmnet")
        self.assertEqual(m["List-Id"], "<sf-lovers.cpbee.cmnet>")
        self.assertEqual(m["Date"], "Sat, 15 Sep 1979 22:16:00 -0700")
        self.assertTrue(m["Message-ID"].endswith("@archive.invalid>"))
        self.assertIn("x.txt#1", m["X-Archive-Source"])
        self.assertEqual(m.get_content(), "For the James H. Schmitz fans out there\n\t\"Demon Breed\" is out in Paperback!\n")
        self.assertEqual(m["Content-Type"], 'text/plain; charset="utf-8"')

    def test_real_message_ids_and_reply_links_are_kept_bogus_ones_are_not(self):
        ms = self.msgs(self.conv(ARPA.replace("<[MIT-DMS].123170>", "<123@mit-dms>")))
        by = {m["Subject"]: m for m in ms}
        self.assertEqual(by["[sf-lovers] [Re: SF Magazines]"]["Message-ID"], "<123@mit-dms>")
        self.assertNotIn("In-Reply-To", by["[sf-lovers] [Re: SF Magazines]"])                  # "Message of 18 Sep 79 ..." is not an id
        m = self.msgs(self.conv(ARPA.replace("In-reply-to: Message of 18 Sep 79 at 0000 EDT by Brodie@PARC-MAXC",
                                             "In-reply-to: <abc@x.y>")))
        self.assertTrue(any(x["In-Reply-To"] == "<abc@x.y>" for x in m))

    def test_ids_are_stable_and_distinct(self):
        a = [mid for _, mid, _ in self.conv(ARPA)]
        b = [mid for _, mid, _ in self.conv(ARPA)]
        self.assertEqual(a, b)
        self.assertEqual(len(set(a)), len(a))

    def test_an_unreadable_date_follows_the_message_before(self):
        conv = self.conv(ARPA)
        self.assertEqual(len(conv), 4)
        dates = [d for _, _, d in conv]
        by = {m["Subject"]: d for m, (_, _, d) in zip(self.msgs(conv), conv)}
        self.assertEqual(by["[sf-lovers] unreadable date"] - by["[sf-lovers] [Re: SF Magazines]"], datetime.timedelta(minutes=1))
        self.assertEqual(dates, sorted(dates))                                                 # oldest first

    def test_non_ascii_goes_out_as_utf8_with_an_encoded_header(self):
        text = ARPA.replace("LSTEWART at PARC-MAXC", "Zoë Ünicöde at PARC-MAXC").replace("fans", "fans café")
        m = self.msgs(self.conv(text))[0]
        self.assertIn("café", m.get_content())
        self.assertEqual(str(m["From"]).split("<")[0].strip(), "Zoë Ünicöde")
        raw = self.conv(text)[0][0]
        self.assertIn(b"=?utf-8?", raw.split(b"\n\n")[0])
        self.assertNotRegex(raw.split(b"\n\n")[0].decode("ascii"), r"[^\x00-\x7f]")

    def test_latin1_files_are_read(self):
        p = self.tmp / "l1.txt"
        p.write_bytes(ARPA.replace("fans", "fans café").encode("latin-1"))
        conv = li.convert("sf-lovers", "cpbee.cmnet", str(p))
        self.assertIn("café", self.msgs(conv)[0].get_content())

    def test_sections_need_a_date_and_each_is_a_minute_later(self):
        with self.assertRaises(li.ImportError_):
            self.conv(DOC, "cyph.txt", fmt="sections")
        conv = self.conv(DOC, "cyph.txt", fmt="sections", date="1994-09-10", title="Cyphernomicon")
        ms = self.msgs(conv)
        self.assertEqual([m["Subject"] for m in ms], ["[sf-lovers] Cyphernomicon 1.1 copyright",
                                                     "[sf-lovers] Cyphernomicon 1.2 Foreword",
                                                     "[sf-lovers] Cyphernomicon 2.1 What is this?"])
        self.assertEqual([m["Date"] for m in ms][:2], ["Sat, 10 Sep 1994 12:00:00 +0000", "Sat, 10 Sep 1994 12:01:00 +0000"])

    def test_no_prefix_and_a_prefix_already_there(self):
        m = self.msgs(self.conv(ARPA, prefix=False))[0]
        self.assertEqual(m["Subject"], '"Demon Breed"')
        m = self.msgs(self.conv(ARPA.replace('"Demon Breed"', "[sf-lovers] Demon")))[0]
        self.assertEqual(m["Subject"], "[sf-lovers] Demon")

    def test_zip_sources(self):
        z = self.tmp / "s.zip"
        with zipfile.ZipFile(str(z), "w") as f:
            f.writestr("listservs/a.txt", ARPA)
        conv = li.convert("sf-lovers", "cpbee.cmnet", "%s::listservs/a.txt" % z)
        self.assertEqual(len(conv), 4)
        self.assertIn("s.zip:listservs/a.txt#1", self.msgs(conv)[0]["X-Archive-Source"])
        with self.assertRaises(KeyError):
            li.convert("sf-lovers", "cpbee.cmnet", "%s::nothing.txt" % z)

    def test_trailing_dashes_and_control_characters_are_cleaned(self):
        self.assertEqual(li.clean_body("text\n\n-------\n\n"), "text\n")
        self.assertEqual(li.clean_body("a\x0cb\x1f\n"), "ab\n")
        self.assertEqual(li.clean_body("- a list item\n"), "- a list item\n")


class TestRun(Base):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(BIN / "list-import")] + list(args), capture_output=True, timeout=120)

    def test_dry_run_counts_and_writes_nothing(self):
        p = self.write("a.txt", ARPA)
        r = self.run_cli("--domain", "cpbee.cmnet", "--list", "sf-lovers", "--dry-run", p)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.decode(), "sf-lovers: read 4, would deliver 4, already done 0\n")

    def test_out_writes_a_readable_mbox(self):
        p = self.write("a.txt", ARPA)
        out = self.tmp / "o.mbox"
        r = self.run_cli("--domain", "cpbee.cmnet", "--list", "sf-lovers", "--out", str(out), p)
        self.assertEqual(r.returncode, 0, r.stderr)
        box = list(mailbox.mbox(str(out)))
        self.assertEqual(len(box), 4)
        self.assertEqual(box[0]["List-Id"], "<sf-lovers.cpbee.cmnet>")

    def test_from_lines_in_the_text_are_quoted_in_the_mbox(self):
        p = self.write("a.txt", ARPA.replace("It opens December 9.", "From here on it is quoted.\nFrom there too."))
        out = self.tmp / "o.mbox"
        self.run_cli("--domain", "cpbee.cmnet", "--list", "sf-lovers", "--out", str(out), p)
        self.assertEqual(len(list(mailbox.mbox(str(out)))), 4)
        self.assertIn(b">From here on", out.read_bytes())

    def test_a_command_gets_each_message_and_the_state_file_makes_a_rerun_skip_them(self):
        p = self.write("a.txt", ARPA)
        sink = self.tmp / "sink"
        sink.mkdir()
        tool = self.tmp / "deliver"
        tool.write_text("#!%s\nimport os, sys, time\nopen(os.path.join(%r, 'm%%d' %% time.time_ns()), 'wb').write(sys.stdin.buffer.read())\n"
                        % (sys.executable, str(sink)))
        tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
        st = self.tmp / "state"
        args = ["--domain", "cpbee.cmnet", "--list", "sf-lovers", "--state", str(st), p, "--", str(tool)]
        r = self.run_cli(*args)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.decode(), "sf-lovers: read 4, delivered 4, already done 0\n")
        self.assertEqual(len(list(sink.iterdir())), 4)
        self.assertEqual(len(st.read_text().split()), 4)
        r = self.run_cli(*args)
        self.assertEqual(r.stdout.decode(), "sf-lovers: read 4, delivered 0, already done 4\n")
        self.assertEqual(len(list(sink.iterdir())), 4)

    def test_a_failing_command_stops_and_the_state_keeps_what_went_in(self):
        p = self.write("a.txt", ARPA)
        tool = self.tmp / "flaky"
        counter = self.tmp / "count"
        tool.write_text("#!%s\nimport os, sys\nsys.stdin.buffer.read()\nn = int(open(%r).read() or 0) if os.path.exists(%r) else 0\n"
                        "open(%r, 'w').write(str(n + 1))\nif n >= 2:\n    sys.stderr.write('mailbox full'); sys.exit(75)\n"
                        % (sys.executable, str(counter), str(counter), str(counter)))
        tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
        st = self.tmp / "state"
        r = self.run_cli("--domain", "cpbee.cmnet", "--list", "sf-lovers", "--state", str(st), p, "--", str(tool))
        self.assertEqual(r.returncode, 1)
        self.assertIn("mailbox full", r.stderr.decode())
        self.assertIn("FAILED 1", r.stdout.decode())
        self.assertEqual(len(st.read_text().split()), 2)                                     # the two that went in

    def test_limit_and_usage_errors(self):
        p = self.write("a.txt", ARPA)
        r = self.run_cli("--domain", "cpbee.cmnet", "--list", "sf-lovers", "--dry-run", "--limit", "2", p)
        self.assertIn("would deliver 2", r.stdout.decode())
        for args in (["--domain", "x.y", "--list", "sf-lovers", p],                           # nowhere to send
                     ["--domain", "x.y", "--list", "Bad Name", "--dry-run", p],
                     ["--domain", "x.y", "--list", "a", "--dry-run", "--format", "sections", p],      # needs --date
                     ["--domain", "x.y", "--list", "a", "--dry-run", str(self.tmp / "missing.txt")]):
            self.assertEqual(self.run_cli(*args).returncode, 2, args)


if __name__ == "__main__":
    unittest.main()
