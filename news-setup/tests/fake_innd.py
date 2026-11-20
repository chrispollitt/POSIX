"""A fake innd for news-import's tests: greets, answers IHAVE.

    srv = FakeInnd(); srv.accepted -> [(message_id, article_bytes), ...]
    srv.have = {b"<x@y>"}           message-ids it already has (435)
    srv.reject = {b"<z@y>": "reason"}   message-ids it refuses after the article (437)
    srv.busy = {b"<b@y>": 1}        answer 436 this many times first
"""
import socketserver
import threading


class _Handler(socketserver.StreamRequestHandler):
    def handle(self):
        srv = self.server.fake
        self.wfile.write(b"200 fake innd ready\r\n")
        while True:
            line = self.rfile.readline()
            if not line:
                return
            parts = line.strip().split(b" ", 1)
            word = parts[0].upper()
            if word == b"QUIT":
                self.wfile.write(b"205 bye\r\n")
                return
            if word != b"IHAVE" or len(parts) < 2:
                self.wfile.write(b"500 what?\r\n")
                continue
            mid = parts[1].strip()
            srv.offers.append(mid)
            if mid in srv.have:
                self.wfile.write(b"435 duplicate\r\n")
                continue
            if srv.busy.get(mid, 0) > 0:
                srv.busy[mid] -= 1
                self.wfile.write(b"436 try again later\r\n")
                continue
            self.wfile.write(b"335 send it\r\n")
            lines = []
            while True:
                ln = self.rfile.readline().rstrip(b"\r\n")
                if ln == b".":
                    break
                lines.append(ln[1:] if ln.startswith(b"..") else ln)
            art = b"\n".join(lines) + b"\n"
            if mid in srv.reject:
                self.wfile.write(("437 %s\r\n" % srv.reject[mid]).encode())
                continue
            srv.accepted.append((mid, art))
            srv.have.add(mid)
            self.wfile.write(b"235 article transferred ok\r\n")


class FakeInnd(object):
    def __init__(self):
        self.accepted, self.offers = [], []
        self.have, self.reject, self.busy = set(), {}, {}
        self.srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Handler)
        self.srv.daemon_threads = True
        self.srv.fake = self
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def stop(self):
        self.srv.shutdown()
        self.srv.server_close()
