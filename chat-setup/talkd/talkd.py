#!/usr/bin/env python3
"""talkd.py - a talk(1) daemon for the LAN master (cpbee), stdlib only.

Speaks the standard ntalk protocol on UDP 518, so a plain `talk user@cpbee`
from any shell works as it always has: invitations are kept, looked up and
deleted, and a user logged in on this host is rung on their terminal with
the classic "Message from Talk_Daemon@..." lines.

It is the first piece of tvchat's talk support (TUIs HANDOFF.md, milestone
6).  Later steps add tvchat users (an invitation goes to tvchat instead of a
tty) and a relay (this daemon splices the two TCP streams, so laptops take
no inbound connections).

    talkd.py [--bind ADDR] [--port N] [--debug]

The wire, as FreeBSD's <protocols/talkd.h> and libexec/talkd/process.c have
it - every multi-byte field big-endian, the sockaddr's family too:

    CTL_MSG (84 bytes):      vers type answer pad  id_num(4)
                             addr(16) ctl_addr(16) pid(4)
                             l_name(12) r_name(12) r_tty(16)
    CTL_RESPONSE (24 bytes): vers type answer pad  id_num(4)  addr(16)
    sockaddr (4.3BSD):       family(2) port(2) IPv4(4) zero(8)

Python >= 3.6.  Run as a user in group tty (to write to terminals), with
CAP_NET_BIND_SERVICE for port 518 - chat-setup/scripts/configure-talkd.sh
(step 3) sets that up.
"""

import argparse
import logging
import os
import selectors
import socket
import stat
import struct
import sys
import time

TALK_VERSION = 1

# request types
LEAVE_INVITE, LOOK_UP, DELETE, ANNOUNCE = 0, 1, 2, 3
TYPES = ("LEAVE_INVITE", "LOOK_UP", "DELETE", "ANNOUNCE")

# answers
(SUCCESS, NOT_HERE, FAILED, MACHINE_UNKNOWN, PERMISSION_DENIED,
 UNKNOWN_REQUEST, BADVERSION, BADADDR, BADCTLADDR) = range(9)
ANSWERS = ("SUCCESS", "NOT_HERE", "FAILED", "MACHINE_UNKNOWN", "PERMISSION_DENIED",
           "UNKNOWN_REQUEST", "BADVERSION", "BADADDR", "BADCTLADDR")

MAX_LIFE = 60        # seconds an invitation is kept
NAME_SIZE = 12
TTY_SIZE = 16
AF_INET_WIRE = 2     # AF_INET as talk puts it on the wire (BSD's value)

MSG = struct.Struct("!BBBBI16s16si12s12s16s")
RESPONSE = struct.Struct("!BBBBI16s")
SOCKADDR = struct.Struct("!HH4s8x")

_log = logging.getLogger("talkd")


# --------------------------------------------------------------------------
# The codec
# --------------------------------------------------------------------------
def pack_addr(addr):
    """(ip, port) -> the 16-byte 4.3BSD sockaddr talk sends."""
    ip, port = addr
    return SOCKADDR.pack(AF_INET_WIRE, port, socket.inet_aton(ip))


def unpack_addr(raw):
    """16 bytes -> (family, ip, port)."""
    family, port, ip = SOCKADDR.unpack(raw)
    return family, socket.inet_ntoa(ip), port


def _name(raw):
    return raw.split(b"\0", 1)[0].decode("latin-1")


class Request:
    """One CTL_MSG.  addr is where the caller listens for the talk session
    (TCP), ctl_addr where its control socket waits for our answers (UDP)."""

    __slots__ = ("vers", "type", "id_num", "addr_family", "addr", "ctl_family",
                 "ctl_addr", "pid", "l_name", "r_name", "r_tty")

    @classmethod
    def parse(cls, data):
        if len(data) < MSG.size:
            return None
        (vers, rtype, _answer, _pad, id_num, addr, ctl, pid,
         l_name, r_name, r_tty) = MSG.unpack(data[:MSG.size])
        r = cls()
        r.vers, r.type, r.id_num, r.pid = vers, rtype, id_num, pid
        r.addr_family, ip, port = unpack_addr(addr)
        r.addr = (ip, port)
        r.ctl_family, ip, port = unpack_addr(ctl)
        r.ctl_addr = (ip, port)
        r.l_name, r.r_name, r.r_tty = _name(l_name), _name(r_name), _name(r_tty)
        return r

    def pack(self):
        """For tests and for calling other hosts' talkds (step 2)."""
        enc = lambda s, n: s.encode("latin-1")[:n]
        return MSG.pack(self.vers, self.type, 0, 0, self.id_num,
                        pack_addr(self.addr), pack_addr(self.ctl_addr), self.pid,
                        enc(self.l_name, NAME_SIZE), enc(self.r_name, NAME_SIZE),
                        enc(self.r_tty, TTY_SIZE))

    def __repr__(self):
        return "<%s id=%d %s -> %s tty=%r addr=%s:%d ctl=%s:%d pid=%d>" % (
            TYPES[self.type] if self.type < 4 else self.type, self.id_num,
            self.l_name, self.r_name, self.r_tty, self.addr[0], self.addr[1],
            self.ctl_addr[0], self.ctl_addr[1], self.pid)


def response(rtype, answer, id_num=0, addr=("0.0.0.0", 0)):
    return RESPONSE.pack(TALK_VERSION, rtype, answer, 0, id_num, pack_addr(addr))


# --------------------------------------------------------------------------
# Who is logged in, and on which terminal (utmp)
# --------------------------------------------------------------------------
# glibc's struct utmp (Linux, 64- and 32-bit alike: 384 bytes)
UTMP = struct.Struct("hhi32s4s32s256shhiii4i20s")
USER_PROCESS = 7
UTMP_FILES = ("/run/utmp", "/var/run/utmp")


def utmp_logins(path=None):
    """[(user, tty)] of the USER_PROCESS entries in utmp."""
    for p in ([path] if path else UTMP_FILES):
        try:
            with open(p, "rb") as f:
                data = f.read()
        except OSError:
            continue
        out = []
        for i in range(0, len(data) - UTMP.size + 1, UTMP.size):
            rec = UTMP.unpack_from(data, i)
            if rec[0] == USER_PROCESS:
                out.append((_name(rec[5]), _name(rec[3])))
        return out
    return []


# --------------------------------------------------------------------------
# The daemon
# --------------------------------------------------------------------------
class Invite:
    __slots__ = ("id", "req", "when")

    def __init__(self, ident, req, when):
        self.id, self.req, self.when = ident, req, when


class TalkDaemon:
    """The invitation table and the four requests, as BSD's talkd does them.
    logins() -> [(user, tty)] and the tty directory are injectable, and so
    is the clock, so the tests need no real terminals and no waiting."""

    def __init__(self, logins=utmp_logins, devdir="/dev", clock=time.time,
                 hostname=None, resolve=None):
        self.logins = logins
        self.devdir = devdir
        self.clock = clock
        self.hostname = hostname or socket.gethostname().split(".")[0]
        self.resolve = resolve or _reverse_name
        self.table = []                  # Invite, oldest first
        self._next = 0

    # -- the table ----------------------------------------------------------
    def _expire(self):
        now = self.clock()
        self.table = [e for e in self.table if now - e.when <= MAX_LIFE]

    def _new_id(self):
        self._next += 1
        return self._next

    def find_request(self, m):
        """The same caller's earlier LEAVE_INVITE / ANNOUNCE (a re-send)."""
        for e in self.table:
            r = e.req
            if (r.type == m.type and r.l_name == m.l_name and r.r_name == m.r_name
                    and r.ctl_addr == m.ctl_addr and r.pid == m.pid):
                return e
        return None

    def find_match(self, m):
        """An invitation left *for* the one looking: theirs is our r_name."""
        for e in self.table:
            r = e.req
            if r.type == LEAVE_INVITE and r.l_name == m.r_name and r.r_name == m.l_name:
                return e
        return None

    def insert(self, m):
        e = Invite(self._new_id(), m, self.clock())
        self.table.append(e)
        return e

    # -- requests -----------------------------------------------------------
    def process(self, data, src):
        """One datagram -> the reply bytes, or None (not a talk request)."""
        m = Request.parse(data)
        if m is None:
            _log.debug("%s: %d bytes, not a request", src, len(data))
            return None
        rtype = m.type if m.type < 4 else 0
        if m.vers != TALK_VERSION:
            return self._answer(m, src, rtype, BADVERSION)
        if m.addr_family != AF_INET_WIRE:
            return self._answer(m, src, rtype, BADADDR)
        if m.ctl_family != AF_INET_WIRE:
            return self._answer(m, src, rtype, BADCTLADDR)
        if not m.l_name or not all(32 <= ord(c) < 127 for c in m.l_name):
            return self._answer(m, src, rtype, FAILED)
        self._expire()
        if m.type == ANNOUNCE:
            return self._announce(m, src)
        if m.type == LEAVE_INVITE:
            e = self.find_request(m) or self.insert(m)
            e.when = self.clock()
            return self._answer(m, src, LEAVE_INVITE, SUCCESS, e.id)
        if m.type == LOOK_UP:
            e = self.find_match(m)
            if e is None:
                return self._answer(m, src, LOOK_UP, NOT_HERE)
            return self._answer(m, src, LOOK_UP, SUCCESS, e.id, e.req.addr)
        if m.type == DELETE:
            for e in self.table:
                if e.id == m.id_num:
                    self.table.remove(e)
                    return self._answer(m, src, DELETE, SUCCESS)
            return self._answer(m, src, DELETE, NOT_HERE)
        return self._answer(m, src, m.type & 0xFF, UNKNOWN_REQUEST)

    def _answer(self, m, src, rtype, answer, id_num=0, addr=("0.0.0.0", 0)):
        _log.debug("%s: %r -> %s id=%d", src, m, ANSWERS[answer], id_num)
        return response(rtype, answer, id_num, addr)

    def _announce(self, m, src):
        tty, answer = self.find_user(m.r_name, m.r_tty)
        if answer != SUCCESS:
            return self._answer(m, src, ANNOUNCE, answer)
        caller_host = self.resolve(m.ctl_addr[0] if m.ctl_addr[0] != "0.0.0.0" else src[0])
        e = self.find_request(m)
        if e is None:
            e = self.insert(m)
        elif m.id_num > e.id:            # the caller's next ring: a new id
            e.id = self._new_id()
        else:                            # a duplicate packet: rung already
            return self._answer(m, src, ANNOUNCE, SUCCESS, e.id)
        e.when = self.clock()
        if not self.ring(tty, m.l_name, caller_host):
            self.table.remove(e)
            return self._answer(m, src, ANNOUNCE, FAILED)
        return self._answer(m, src, ANNOUNCE, SUCCESS, e.id)

    # -- terminals ----------------------------------------------------------
    def find_user(self, name, want_tty=""):
        """(tty, answer): the named tty if given, else the user's terminal
        idle the shortest time that accepts messages (mesg y)."""
        best, best_idle, refused = None, None, False
        for user, tty in self.logins():
            if user != name or (want_tty and tty != want_tty):
                continue
            try:
                st = os.stat(os.path.join(self.devdir, tty))
            except OSError:
                continue
            if not st.st_mode & stat.S_IWGRP:    # mesg n
                refused = True
                continue
            idle = self.clock() - st.st_atime
            if best is None or idle < best_idle:
                best, best_idle = tty, idle
        if best is not None:
            return best, SUCCESS
        return None, PERMISSION_DENIED if refused else NOT_HERE

    def ring(self, tty, caller, caller_host):
        """The classic announcement, on the callee's terminal."""
        t = time.localtime(self.clock())
        text = ("\r\n\a\r\nMessage from Talk_Daemon@%s at %d:%02d ...\r\n"
                "talk: connection requested by %s@%s.\r\n"
                "talk: respond with:  talk %s@%s\r\n\r\n"
                % (self.hostname, t.tm_hour, t.tm_min, caller, caller_host,
                   caller, caller_host))
        path = os.path.join(self.devdir, tty)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOCTTY | os.O_NONBLOCK)
            try:
                os.write(fd, text.encode("latin-1", "replace"))
            finally:
                os.close(fd)
        except OSError as e:
            _log.warning("cannot ring %s: %s", path, e)
            return False
        return True


def _reverse_name(ip):
    """The caller's host name for the announcement; its address if unknown
    (BSD talkd refuses with MACHINE_UNKNOWN - on a LAN without reverse DNS
    that would refuse everyone)."""
    try:
        return socket.gethostbyaddr(ip)[0].split(".")[0]
    except OSError:
        return ip


# --------------------------------------------------------------------------
# The loop
# --------------------------------------------------------------------------
def serve(daemon, sock, stop=None):
    """Answer requests on sock until stop() is true (forever by default)."""
    sel = selectors.DefaultSelector()
    sel.register(sock, selectors.EVENT_READ)
    while not (stop and stop()):
        for _key, _mask in sel.select(0.5):
            try:
                data, src = sock.recvfrom(1024)
            except OSError:
                continue
            try:
                reply = daemon.process(data, src)
            except Exception:            # one bad packet, not the daemon
                _log.exception("%s: request failed", src)
                continue
            if reply is not None:
                try:
                    sock.sendto(reply, src)
                except OSError as e:
                    _log.debug("%s: reply failed: %s", src, e)


def main(argv=None):
    ap = argparse.ArgumentParser(description="talk(1) daemon (ntalk, UDP)")
    ap.add_argument("--bind", default="0.0.0.0", help="address to listen on")
    ap.add_argument("--port", type=int, default=518, help="UDP port (518)")
    ap.add_argument("--debug", action="store_true", help="log every request")
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if a.debug else logging.INFO,
                        format="talkd: %(message)s", stream=sys.stderr)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((a.bind, a.port))
    _log.info("listening on %s udp %d", a.bind, a.port)
    try:
        serve(TalkDaemon(), sock)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
