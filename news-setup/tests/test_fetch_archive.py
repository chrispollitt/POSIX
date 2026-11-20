#!/usr/bin/env python3
"""Tests for news-setup/bin/fetch-archive against a local HTTP server that imitates archive.org's
/metadata/ITEM and /download/ITEM/NAME.

    python3 news-setup/tests/test_fetch_archive.py
"""
import hashlib
import http.server
import importlib.machinery
import importlib.util
import io
import json
import shutil
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_loader = importlib.machinery.SourceFileLoader("fetch_archive", str(HERE.parent / "bin" / "fetch-archive"))
_spec = importlib.util.spec_from_loader("fetch_archive", _loader)
fa = importlib.util.module_from_spec(_spec)
_loader.exec_module(fa)

FILES = {"usenet-comp.lang.c.mbox.zip": b"c" * 3000, "usenet-rec.humor.mbox.zip": b"h" * 2000, "notes.txt": b"hi"}
SERVED = dict(FILES)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/metadata/item1":
            meta = {"files": [{"name": n, "size": str(len(d)), "md5": hashlib.md5(d).hexdigest()} for n, d in FILES.items()]
                    + [{"name": "item1_meta.xml", "size": "10", "md5": "x"}]}
            body = json.dumps(meta).encode()
        elif self.path == "/metadata/gone":
            body = b'{}'
        elif self.path.startswith("/download/item1/"):
            n = self.path[len("/download/item1/"):]
            if n not in SERVED:
                self.send_response(404)
                self.end_headers()
                return
            body = SERVED[n]
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class T(unittest.TestCase):
    def setUp(self):
        SERVED.clear()
        SERVED.update(FILES)
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        self.tmp = Path(tempfile.mkdtemp(prefix="fetch-archive-"))
        self.addCleanup(shutil.rmtree, str(self.tmp), True)

    def run_fa(self, *args, stdin=""):
        out = io.StringIO()
        st = fa.main(["--base", self.base, *args], out, io.StringIO(stdin))
        return st, out.getvalue()

    def test_list_shows_names_and_sizes_not_the_item_bookkeeping(self):
        st, out = self.run_fa("--item", "item1", "--list")
        self.assertEqual(st, 0)
        self.assertIn("usenet-comp.lang.c.mbox.zip", out)
        self.assertIn("2.9 KB", out)
        self.assertNotIn("_meta.xml", out)
        self.assertIn("3 file(s)", out)
        st, out = self.run_fa("--item", "item1", "--list", "--match", r"humor")
        self.assertIn("1 file(s)", out)

    def test_download_asks_then_checks_and_skips_what_is_there(self):
        to = str(self.tmp / "dl")
        st, out = self.run_fa("--item", "item1", "--match", r"\.zip$", "--to", to, stdin="n\n")
        self.assertEqual(st, 1)
        self.assertIn("nothing downloaded", out)
        self.assertFalse((self.tmp / "dl").exists())
        st, out = self.run_fa("--item", "item1", "--match", r"\.zip$", "--to", to, stdin="y\n")
        self.assertEqual(st, 0, out)
        self.assertEqual((self.tmp / "dl" / "usenet-rec.humor.mbox.zip").read_bytes(), FILES["usenet-rec.humor.mbox.zip"])
        st, out = self.run_fa("--item", "item1", "--match", r"\.zip$", "--to", to, "--yes")
        self.assertEqual(out.count("  have  "), 2)

    def test_a_wrong_checksum_is_refused_and_not_kept(self):
        SERVED["usenet-rec.humor.mbox.zip"] = b"tampered" * 10
        st, out = self.run_fa("--item", "item1", "--match", "humor", "--to", str(self.tmp / "dl"), "--yes")
        self.assertEqual(st, 1)
        self.assertIn("BAD", out)
        self.assertFalse(list((self.tmp / "dl").glob("*")))

    def test_an_item_with_no_files(self):
        with self.assertRaises(SystemExit) as e:
            self.run_fa("--item", "gone", "--list")
        self.assertIn("no files", str(e.exception))


if __name__ == "__main__":
    unittest.main()
