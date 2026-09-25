"""Tiny in-process POP3(S) and SMTP servers for the mail-setup tests.

Stdlib only.  Each server runs in a daemon thread on 127.0.0.1:<ephemeral>
and records what clients did, so a test can drive a real program (pop-pull,
getmail, the sendmail shim) at it and then assert on both sides.

    with FakePOP3([b"Subject: a\\r\\n\\r\\nhi\\r\\n"], user="u", password="p",
                  ssl_context=ctx) as pop:
        ... connect to pop.port ...
        pop.deleted        # 1-based message numbers DELEd (and committed)

    with FakeSMTP() as smtp:
        ... send to smtp.port ...
        smtp.messages      # [(mail_from, [rcpt, ...], data_bytes), ...]
"""
import os, socket, socketserver, ssl, shutil, subprocess, threading


class _Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class _Base:
    handler = None

    def __init__(self, ssl_context=None):
        self.ssl_context = ssl_context
        self.commands = []
        self._srv = _Server(("127.0.0.1", 0), self._make_handler())
        self.port = self._srv.server_address[1]
        self._t = threading.Thread(target=self._srv.serve_forever, daemon=True)

    def __enter__(self):
        self._t.start()
        return self

    def __exit__(self, *exc):
        self._srv.shutdown()
        self._srv.server_close()

    def _make_handler(self):
        outer = self

        class H(socketserver.BaseRequestHandler):
            def send(self, line):
                self.wfile.write(line.encode() + b"\r\n")
                self.wfile.flush()

            def handle(self):
                sock = self.request
                try:
                    if outer.ssl_context is not None:
                        # a rejected handshake (untrusted-cert tests) is expected
                        sock = outer.ssl_context.wrap_socket(sock, server_side=True)
                    self.rfile = sock.makefile("rb")
                    self.wfile = sock.makefile("wb")
                    outer.session(self)
                except (ConnectionError, ssl.SSLError, OSError):
                    pass
                finally:
                    try:
                        sock.close()
                    except OSError:
                        pass

        return H


class FakePOP3(_Base):
    """RFC 1939 subset: USER PASS STAT LIST UIDL RETR TOP DELE NOOP RSET CAPA QUIT."""

    def __init__(self, messages, user="user", password="secret",
                 uids=None, ssl_context=None):
        super().__init__(ssl_context)
        self.messages = [m if isinstance(m, bytes) else m.encode() for m in messages]
        self.uids = uids or ["uid-%d" % (i + 1) for i in range(len(self.messages))]
        self.user, self.password = user, password
        self.deleted = set()        # committed at QUIT, like a real server
        self.logins = 0

    def _live(self, gone):
        return [i for i in range(1, len(self.messages) + 1)
                if i not in self.deleted and i not in gone]

    def session(self, h):
        h.send("+OK fake pop3 ready")
        authed, who, gone = False, None, set()
        while True:
            raw = h.rfile.readline()
            if not raw:
                return
            parts = raw.decode("utf-8", "replace").strip().split()
            if not parts:
                continue
            cmd, args = parts[0].upper(), parts[1:]
            self.commands.append(cmd)
            if cmd == "CAPA":
                h.send("+OK capability list follows")
                for c in ("USER", "UIDL", "TOP", "."):
                    h.send(c)
            elif cmd == "USER":
                who = args[0] if args else None
                h.send("+OK")
            elif cmd == "PASS":
                if who == self.user and " ".join(args) == self.password:
                    authed = True
                    self.logins += 1
                    h.send("+OK logged in")
                else:
                    h.send("-ERR [AUTH] bad login")
            elif cmd == "QUIT":
                self.deleted |= gone
                h.send("+OK bye")
                return
            elif not authed:
                h.send("-ERR not logged in")
            elif cmd == "STAT":
                live = self._live(gone)
                h.send("+OK %d %d" % (len(live), sum(len(self.messages[i - 1]) for i in live)))
            elif cmd in ("LIST", "UIDL"):
                live = self._live(gone)
                val = (lambda i: len(self.messages[i - 1])) if cmd == "LIST" \
                    else (lambda i: self.uids[i - 1])
                if args:
                    i = int(args[0])
                    h.send("+OK %d %s" % (i, val(i)) if i in live else "-ERR no such message")
                else:
                    h.send("+OK")
                    for i in live:
                        h.send("%d %s" % (i, val(i)))
                    h.send(".")
            elif cmd in ("RETR", "TOP"):
                i = int(args[0])
                if i not in self._live(gone):
                    h.send("-ERR no such message")
                    continue
                body = self.messages[i - 1]
                if cmd == "TOP":
                    body = body.split(b"\r\n\r\n", 1)[0] + b"\r\n\r\n"
                h.send("+OK %d octets" % len(body))
                for ln in body.split(b"\r\n")[:-1] if body.endswith(b"\r\n") else body.split(b"\r\n"):
                    h.wfile.write((b"." + ln if ln.startswith(b".") else ln) + b"\r\n")
                h.send(".")
            elif cmd == "DELE":
                gone.add(int(args[0]))
                h.send("+OK deleted")
            elif cmd == "RSET":
                gone.clear()
                h.send("+OK")
            elif cmd == "NOOP":
                h.send("+OK")
            else:
                h.send("-ERR unknown command")


class FakeSMTP(_Base):
    """Enough ESMTP for smtplib.sendmail(): EHLO/HELO MAIL RCPT DATA RSET NOOP QUIT."""

    def __init__(self, ssl_context=None):
        super().__init__(ssl_context)
        self.messages = []

    def session(self, h):
        h.send("220 fake smtp ready")
        frm, rcpts = None, []
        while True:
            raw = h.rfile.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            cmd = line[:4].upper()
            self.commands.append(cmd)
            if cmd == "EHLO":
                h.send("250-fake")
                h.send("250 8BITMIME")
            elif cmd == "HELO":
                h.send("250 fake")
            elif cmd == "MAIL":
                frm, rcpts = line.split(":", 1)[1].strip().split()[0].strip("<>"), []
                h.send("250 ok")
            elif cmd == "RCPT":
                rcpts.append(line.split(":", 1)[1].strip().split()[0].strip("<>"))
                h.send("250 ok")
            elif cmd == "DATA":
                h.send("354 go ahead")
                buf = []
                while True:
                    ln = h.rfile.readline()
                    if not ln or ln in (b".\r\n", b".\n"):
                        break
                    buf.append(ln[1:] if ln.startswith(b"..") else ln)
                self.messages.append((frm, rcpts, b"".join(buf)))
                h.send("250 queued")
            elif cmd in ("RSET", "NOOP"):
                h.send("250 ok")
            elif cmd == "QUIT":
                h.send("221 bye")
                return
            else:
                h.send("502 not implemented")


def self_signed_cert(dirpath, host="localhost"):
    """(certfile, keyfile) for HOST made with openssl, or None if it can't."""
    exe = shutil.which("openssl")
    if not exe:
        return None
    crt, key = os.path.join(dirpath, "cert.pem"), os.path.join(dirpath, "key.pem")
    r = subprocess.run(
        [exe, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
         "-keyout", key, "-out", crt, "-subj", "/CN=" + host,
         "-addext", "subjectAltName=DNS:" + host],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return (crt, key) if r.returncode == 0 else None


def server_context(certfile, keyfile):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile, keyfile)
    return ctx
