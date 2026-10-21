#!/usr/bin/env python3
"""ergo-register.py HOST PORT NICK - create NickServ account NICK on an IRC
server (Ergo), with the password from $CHAT_SETUP_PASS (never argv, where
`ps` would show it).

Plain IRC over HOST:PORT - configure-ergo.sh points it at Ergo's loopback
plaintext listener.  Connects as NICK, waits for the welcome, says
`NickServ REGISTER <password>`, and reports NickServ's answer:

  exit 0  "Account created", or "Account already exists" (re-runs are fine;
          a different password is NOT changed - say so)
  exit 1  anything else NickServ said, or no answer
  exit 2  usage / cannot connect

Stdlib only, Python >= 3.6.
"""

import os
import socket
import sys
import time


def main(argv):
    if len(argv) != 4:
        sys.stderr.write(__doc__.split("\n\n")[0] + "\n")
        return 2
    host, port, nick = argv[1], int(argv[2]), argv[3]
    pw = os.environ.get("CHAT_SETUP_PASS", "")
    if not pw or " " in pw:
        sys.stderr.write("ergo-register: $CHAT_SETUP_PASS must be set, with no spaces\n")
        return 2
    try:
        s = socket.create_connection((host, port), timeout=10)
    except OSError as e:
        sys.stderr.write("ergo-register: cannot connect to %s port %d: %s\n" % (host, port, e))
        return 2
    s.settimeout(10)

    def send(line):
        s.sendall(line.encode("utf-8") + b"\r\n")

    send("NICK %s" % nick)
    send("USER %s 0 * :%s" % (nick, nick))
    buf = b""
    deadline = time.time() + 20
    registered = False
    try:
        while time.time() < deadline:
            data = s.recv(4096)
            if not data:
                break
            buf += data
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                line = raw.decode("utf-8", "replace").rstrip("\r")
                words = line.split(" ")
                if words[0] == "PING":
                    send("PONG " + " ".join(words[1:]))
                    continue
                cmd = words[1] if len(words) > 1 else ""
                if cmd == "433":
                    print("ergo-register: the nick %s is in use right now - try again later" % nick)
                    return 1
                if cmd == "001" and not registered:
                    registered = True
                    send("PRIVMSG NickServ :REGISTER %s" % pw)
                    continue
                if cmd == "NOTICE" and line.lower().startswith(":nickserv!"):
                    text = line.split(" :", 1)[1] if " :" in line else ""
                    if text.startswith("Account created"):
                        print("ergo-register: account %s created" % nick)
                        send("QUIT :registered")
                        return 0
                    if text.startswith("Account already exists"):
                        print("ergo-register: account %s already exists (its password is unchanged)" % nick)
                        send("QUIT")
                        return 0
                    if registered and "logged in" not in text:
                        print("ergo-register: NickServ says: %s" % text)
                        send("QUIT")
                        return 1
    except socket.timeout:
        pass
    finally:
        s.close()
    print("ergo-register: no answer from NickServ")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
