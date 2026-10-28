#!/usr/bin/env python3
"""fake_nickserv.py MODE - one-connection IRC server for ergo-register.py's
test.  Prints its port on the first line of stdout, then serves one client:
registration (001), then NickServ answers REGISTER according to MODE:

  created   "Account created" (+ "You're now logged in as ...")
  exists    "Account already exists"
  refuse    "Passphrase contains forbidden characters or is otherwise invalid"
  silent    nothing (the client gives up)

Every line the client sent goes to stderr, so the test can check what it
said (and that the password never appears anywhere else).
"""
import socket
import sys

mode = sys.argv[1]
srv = socket.socket()
srv.bind(("127.0.0.1", 0))
srv.listen(1)
print(srv.getsockname()[1], flush=True)
srv.settimeout(20)
c, _ = srv.accept()
c.settimeout(5)
buf = b""
nick = "?"


def send(line):
    c.sendall(line.encode() + b"\r\n")


try:
    while True:
        data = c.recv(4096)
        if not data:
            break
        buf += data
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            line = raw.decode().rstrip("\r")
            sys.stderr.write(line + "\n")
            if line.startswith("NICK "):
                nick = line[5:]
            elif line.startswith("USER "):
                send(":srv NOTICE * :*** Looking up your hostname...")
                send(":srv 001 %s :Welcome to the FakeNet IRC Network" % nick)
                send("PING :fake")
            elif line.startswith("PRIVMSG NickServ :REGISTER "):
                ns = ":NickServ!NickServ@localhost NOTICE %s :" % nick
                if mode == "created":
                    send(ns + "Account created")
                    send(ns + "You're now logged in as %s" % nick)
                elif mode == "exists":
                    send(ns + "Account already exists")
                elif mode == "refuse":
                    send(ns + "Passphrase contains forbidden characters or is otherwise invalid")
            elif line.startswith("QUIT"):
                raise SystemExit(0)
except socket.timeout:
    pass
