#!/usr/bin/env python3
"""talkd.py - a talk(1) daemon for the LAN master (cpbee), stdlib only.

Speaks the standard ntalk protocol on UDP 518, so a plain `talk user@cpbee`
from any shell works as it always has: invitations are kept, looked up and
deleted, and a user logged in on this host is rung on their terminal with
the classic "Message from Talk_Daemon@..." lines.

It is also where tvchat (TUIs HANDOFF.md, milestone 6) meets talk: one
talkd on the LAN master, none on the laptops.  tvchat connects to it over
TCP (port 518 too), says who it is, and from then on an ANNOUNCE for that
user rings tvchat instead of a terminal.  This daemon carries every
conversation a tvchat user is in - it connects to the real talk's address
itself, or takes the real talk's connection on a relay port of its own -
and splices the bytes, so laptops take no inbound connections.

    talkd.py [--bind ADDR] [--port N] [--debug]

The control protocol (tvchat <-> talkd, TCP; one line each way, UTF-8,
fields split by spaces, free text last; LAN only and without passwords,
like talk itself):

    tvchat says                  talkd answers / tells
    HELLO USER                   OK USER@HOST          (or ERR TEXT)
    CALL CID USER[@HOST] [TTY]   STATE CID TEXT ... then CONNECT CID TOKEN
                                 or GONE CID WHY       (CID: tvchat's id)
                                 RING ID WHO@HOST      (a call for us; ID: talkd's)
    ACCEPT ID                    CONNECT ID TOKEN      (or GONE ID WHY)
    DECLINE ID                   (stops ringing us; a real talk caller
                                 just keeps ringing until it gives up)
    HANGUP CID|ID                GONE ... to the other side
    PING                         PONG

A CONNECT is answered with a second TCP connection to the same port whose
first line is "ATTACH TOKEN"; after it, that connection carries the talk
session's raw bytes (each side's three edit characters first, as talk
does).  When either side closes, both get GONE ... hung up.

Calls:  real talk -> tvchat user: ANNOUNCE rings tvchat (RING); on ACCEPT
talkd connects to the caller's address.  tvchat -> tvchat: RING the callee,
CONNECT both on ACCEPT.  tvchat -> someone with a terminal here, or USER@HOST
with a talkd of its own: talkd leaves the invitation in its own table and
rings them (ANNOUNCE to HOST's talkd, every 30 s) with a relay port of its
own as the address; their talk LOOK_UPs here and connects to it.

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
import errno
import heapq
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
        self.relay = None                # Relay: tvchat users, when serving them

    # -- the table ----------------------------------------------------------
    def _expire(self):
        now = self.clock()
        keep = [e for e in self.table if now - e.when <= MAX_LIFE]
        gone = [e for e in self.table if now - e.when > MAX_LIFE]
        self.table = keep
        for e in gone:
            self._gone(e)

    def _gone(self, e):
        if self.relay is not None:
            self.relay.invite_gone(e)

    def remove(self, e):
        if e in self.table:
            self.table.remove(e)
            self._gone(e)

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
                    self.remove(e)
                    return self._answer(m, src, DELETE, SUCCESS)
            return self._answer(m, src, DELETE, NOT_HERE)
        return self._answer(m, src, m.type & 0xFF, UNKNOWN_REQUEST)

    def _answer(self, m, src, rtype, answer, id_num=0, addr=("0.0.0.0", 0)):
        _log.debug("%s: %r -> %s id=%d", src, m, ANSWERS[answer], id_num)
        return response(rtype, answer, id_num, addr)

    def _announce(self, m, src):
        # a tvchat user is rung in tvchat, not on a terminal
        tvchat = self.relay is not None and self.relay.has_user(m.r_name)
        tty = None
        if not tvchat:
            tty, answer = self.find_user(m.r_name, m.r_tty)
            if answer != SUCCESS:
                return self._answer(m, src, ANNOUNCE, answer)
        caller_host = self.resolve(m.ctl_addr[0] if m.ctl_addr[0] != "0.0.0.0" else src[0])
        e = self.find_request(m)
        if e is None:
            e = self.insert(m)
        elif m.id_num > e.id:            # the caller's next ring: a new id
            e.id = self._new_id()
            if tvchat:                   # tvchat is told once, not every 30 s
                e.when = self.clock()
                return self._answer(m, src, ANNOUNCE, SUCCESS, e.id)
        else:                            # a duplicate packet: rung already
            return self._answer(m, src, ANNOUNCE, SUCCESS, e.id)
        e.when = self.clock()
        if tvchat:
            self.relay.incoming(e, caller_host)
        elif not self.ring(tty, m.l_name, caller_host):
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


# --------------------------------------------------------------------------
# tvchat users and the relay
# --------------------------------------------------------------------------
RING_WAIT = 30       # ring a callee again after this long (talk's value)
CTL_WAIT = 2         # resend a request to another talkd after this long
CTL_TRIES = 3
CALL_LIFE = 600      # stop ringing after ten minutes
ATTACH_WAIT = 30     # a CONNECT not followed by its ATTACH is dropped


class Loop:
    """selectors over every socket plus a timer heap - one thread."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.sel = selectors.DefaultSelector()
        self.timers = []
        self._n = 0

    def watch(self, sock, on_read=None, on_write=None):
        mask = ((selectors.EVENT_READ if on_read else 0)
                | (selectors.EVENT_WRITE if on_write else 0))
        try:
            key = self.sel.get_key(sock)
        except (KeyError, ValueError):
            key = None
        if not mask:
            if key is not None:
                self.sel.unregister(sock)
        elif key is None:
            self.sel.register(sock, mask, (on_read, on_write))
        else:
            self.sel.modify(sock, mask, (on_read, on_write))

    def call_later(self, delay, fn):
        self._n += 1
        t = [self.clock() + delay, self._n, fn, True]
        heapq.heappush(self.timers, t)
        return t

    @staticmethod
    def cancel(t):
        if t is not None:
            t[3] = False

    def run_once(self, timeout=0.5):
        while self.timers and not self.timers[0][3]:
            heapq.heappop(self.timers)
        if self.timers:
            timeout = min(timeout, max(0.0, self.timers[0][0] - self.clock()))
        for key, mask in self.sel.select(timeout):
            try:
                cur = self.sel.get_key(key.fileobj)
            except (KeyError, ValueError):
                continue                 # closed by an earlier callback
            on_read, on_write = cur.data
            if mask & selectors.EVENT_WRITE and on_write:
                self._call(on_write)
            if mask & selectors.EVENT_READ and on_read:
                try:
                    on_read = self.sel.get_key(key.fileobj).data[0]
                except (KeyError, ValueError):
                    on_read = None
                if on_read:
                    self._call(on_read)
        now = self.clock()
        while self.timers and self.timers[0][0] <= now:
            t = heapq.heappop(self.timers)
            if t[3]:
                self._call(t[2])

    @staticmethod
    def _call(fn):
        try:
            fn()
        except Exception:                # one bad callback, not the daemon
            _log.exception("callback %r failed", fn)


def _close(loop, sock):
    if sock is None:
        return
    try:
        loop.watch(sock)
    except (KeyError, ValueError, OSError):
        pass
    try:
        sock.close()
    except OSError:
        pass


class Pipe:
    """Two connected sockets, every byte copied both ways (the relay)."""

    LIMIT = 65536                        # stop reading while this much waits

    def __init__(self, loop, a, b, on_end, to_a=b"", to_b=b""):
        self.loop, self.a, self.b, self.on_end = loop, a, b, on_end
        self.out = {a: to_a, b: to_b}    # bytes waiting to be written TO it
        self.open = True
        for s in (a, b):
            s.setblocking(False)
        self._rewatch()

    def other(self, s):
        return self.b if s is self.a else self.a

    def _rewatch(self):
        for s in (self.a, self.b):
            o = self.other(s)
            self.loop.watch(
                s, on_read=(lambda s=s: self._read(s)) if len(self.out[o]) < self.LIMIT else None,
                on_write=(lambda s=s: self._write(s)) if self.out[s] else None)

    def _read(self, s):
        try:
            data = s.recv(16384)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            data = b""
        if not data:
            o = self.other(s)
            try:                         # what is still owed, best effort
                o.setblocking(True)
                o.settimeout(1)
                o.sendall(self.out[o])
            except OSError:
                pass
            self.close("hung up")
            return
        self.out[self.other(s)] += data
        self._rewatch()

    def _write(self, s):
        try:
            n = s.send(self.out[s])
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            self.close("hung up")
            return
        self.out[s] = self.out[s][n:]
        self._rewatch()

    def close(self, why):
        if self.open:
            self.open = False
            _close(self.loop, self.a)
            _close(self.loop, self.b)
            self.on_end(why)


class Control:
    """One tvchat's control connection (or, after ATTACH, a data one)."""

    def __init__(self, relay, sock, peer):
        self.relay, self.sock, self.peer = relay, sock, peer
        self.user = None
        self.rbuf = b""
        self.wbuf = b""
        self.closed = False
        sock.setblocking(False)
        self._rewatch()

    def __repr__(self):
        return "<tvchat %s %s:%d>" % (self.user or "?", self.peer[0], self.peer[1])

    def send(self, text):
        if self.closed:
            return
        _log.debug("%r << %s", self, text)
        self.wbuf += (text + "\n").encode("utf-8")
        self._rewatch()

    def _rewatch(self):
        self.relay.loop.watch(self.sock, on_read=self._read,
                              on_write=self._write if self.wbuf else None)

    def _write(self):
        try:
            n = self.sock.send(self.wbuf)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            self.close()
            return
        self.wbuf = self.wbuf[n:]
        self._rewatch()

    def _read(self):
        try:
            data = self.sock.recv(4096)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            data = b""
        if not data:
            self.close()
            return
        self.rbuf += data
        while b"\n" in self.rbuf and not self.closed:
            raw, self.rbuf = self.rbuf.split(b"\n", 1)
            text = raw.decode("utf-8", "replace").rstrip("\r")
            if text.startswith("ATTACH ") and self.user is None:
                # a data connection: hand the socket (and what came after the
                # line) to its call, and stop being a control connection
                self.closed = True
                self.relay.loop.watch(self.sock)
                self.relay.attach(text[7:].strip(), self.sock, self.rbuf)
                return
            _log.debug("%r >> %s", self, text)
            try:
                self.relay.command(self, text)
            except Exception:
                _log.exception("%r: %r failed", self, text)
                self.send("ERR internal error")

    def close(self):
        if not self.closed:
            self.closed = True
            _close(self.relay.loop, self.sock)
            self.relay.control_closed(self)


class Call:
    """One call a tvchat user is in.  kind: 'in' (a real talk calls a tvchat
    user), 'tv' (tvchat to tvchat), 'out' (tvchat to a talk user here or on
    another host).  sides: Control -> the id that side knows the call by."""

    def __init__(self, relay, kind, ident):
        self.relay, self.kind, self.id = relay, kind, ident
        self.sides = {}                  # Control -> its id for this call
        self.caller = None               # the calling Control ('tv', 'out')
        self.ringing = []                # Controls being rung ('in', 'tv')
        self.who = ""                    # WHO@HOST, as RING shows it
        self.callee = ""
        self.invite = None               # an Invite in the daemon's table
        self.peer_addr = None            # 'in': the caller's TCP address
        self.waiting = {}                # token -> (Control, socket or None)
        self.socks = []                  # sockets to close on the way out
        self.listen = None               # 'out': the relay port's socket
        self.ctl = None                  # 'out': UDP to another talkd
        self.remote = None               # 'out': that talkd's (ip, port)
        self.remote_id = None
        self.timers = []
        self.pipe = None
        self.done = False

    def tell(self, text_for):
        for c, cid in list(self.sides.items()):
            c.send(text_for(cid))


class Relay:
    def __init__(self, daemon, loop, peer_port=518, local_names=()):
        self.d = daemon
        self.loop = loop
        self.peer_port = peer_port       # where other hosts' talkds listen
        self.local = set(n.lower() for n in local_names) | {
            "", "localhost", daemon.hostname.lower(), socket.getfqdn().lower()}
        self.users = {}                  # user -> [Control]
        self.calls = {}                  # talkd's call id -> Call
        self.tokens = {}                 # token -> Call
        self._n = 0
        daemon.relay = self

    def has_user(self, name):
        return bool(self.users.get(name))

    def _id(self):
        self._n += 1
        return "t%d" % self._n

    # -- control commands ---------------------------------------------------
    def command(self, c, text):
        word, _, rest = text.partition(" ")
        word, args = word.upper(), rest.split()
        if word == "PING":
            c.send("PONG")
            return
        if word == "HELLO":
            name = args[0] if len(args) == 1 else ""
            if c.user is not None:
                c.send("ERR already HELLO %s" % c.user)
            elif not name or len(name) > NAME_SIZE or not all(32 < ord(ch) < 127 for ch in name):
                c.send("ERR HELLO needs a user name (up to %d characters)" % NAME_SIZE)
            else:
                c.user = name
                self.users.setdefault(name, []).append(c)
                c.send("OK %s@%s" % (name, self.d.hostname))
            return
        if c.user is None:
            c.send("ERR say HELLO USER first")
            return
        if word == "CALL" and len(args) in (2, 3):
            self.call(c, args[0], args[1], args[2] if len(args) == 3 else "")
        elif word == "ACCEPT" and len(args) == 1:
            self.accept(c, args[0])
        elif word == "DECLINE" and len(args) == 1:
            call = self.calls.get(args[0])
            if call is not None and c in call.ringing:
                call.ringing.remove(c)
                call.sides.pop(c, None)
                if call.kind == "tv" and not call.ringing:
                    self.end(call, "declined")
        elif word == "HANGUP" and len(args) == 1:
            call = self._mine(c, args[0])
            if call is not None:
                self.end(call, "hung up")
        else:
            c.send("ERR unknown or malformed: %s" % text[:80])

    def _mine(self, c, cid):
        for call in list(self.calls.values()):
            if call.sides.get(c) == cid:
                return call
        return None

    def control_closed(self, c):
        if c.user and c in self.users.get(c.user, []):
            self.users[c.user].remove(c)
        for call in list(self.calls.values()):
            if c in call.sides and call.pipe is None:
                if c is call.caller or call.kind == "in" and len(call.sides) == 1:
                    self.end(call, "hung up")
                else:
                    call.sides.pop(c, None)
                    if c in call.ringing:
                        call.ringing.remove(c)
                    if call.kind == "tv" and not call.ringing and call.caller is not None:
                        self.end(call, "%s went away" % call.callee)

    # -- the three kinds of call ---------------------------------------------
    def incoming(self, e, caller_host):
        """A real talk's ANNOUNCE for a tvchat user (the daemon's table holds
        it as e): ring every tvchat that user has open."""
        call = Call(self, "in", self._id())
        call.invite, call.peer_addr = e, e.req.addr
        call.who = "%s@%s" % (e.req.l_name, caller_host)
        call.callee = e.req.r_name
        for c in self.users.get(call.callee, []):
            call.ringing.append(c)
            call.sides[c] = call.id
        self.calls[call.id] = call
        call.tell(lambda cid: "RING %s %s" % (cid, call.who))

    def invite_gone(self, e):
        """The daemon dropped an invitation (DELETE, or not renewed)."""
        for call in list(self.calls.values()):
            if call.invite is e and call.pipe is None and not call.waiting:
                if call.kind == "in":
                    self.end(call, "the caller gave up")

    def call(self, c, cid, target, tty):
        if self._mine(c, cid) is not None:
            c.send("GONE %s the id %s is in use" % (cid, cid))
            return
        user, _, host = target.partition("@")
        if not user or len(user) > NAME_SIZE:
            c.send("GONE %s not a talk user: %s" % (cid, target))
            return
        call = Call(self, "", self._id())
        call.caller, call.sides[c] = c, cid
        call.callee = user
        call.who = "%s@%s" % (c.user, self.d.hostname)
        self.calls[call.id] = call
        call.timers.append(self.loop.call_later(CALL_LIFE, lambda: self.end(call, "no answer")))
        if host.lower() in self.local:
            if self.has_user(user) and not tty:
                call.kind = "tv"
                for o in self.users[user]:
                    if o is not c:
                        call.ringing.append(o)
                        call.sides[o] = call.id
                        o.send("RING %s %s" % (call.id, call.who))
                if not call.ringing:
                    self.end(call, "%s is only here" % user)
                    return
                c.send("STATE %s ringing %s" % (cid, user))
                return
            call.kind = "out"
            self._listen(call)
            self._ring_local(call, tty)
            return
        call.kind = "out"
        try:
            ip = socket.gethostbyname(host)
        except OSError as e:
            self.end(call, "unknown host %s: %s" % (host, e))
            return
        call.remote = (ip, self.peer_port)
        call.ctl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        call.ctl.bind(("0.0.0.0", 0))
        call.ctl.setblocking(False)
        call.socks.append(call.ctl)
        self.loop.watch(call.ctl, on_read=lambda: self._ctl_read(call))
        c.send("STATE %s looking for an invitation on %s" % (cid, host))
        self._transact(call, LOOK_UP, 0, self._looked_up)

    # -- 'out': the relay port and our own invitation ---------------------------
    def _listen(self, call):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", 0))
        s.listen(1)
        s.setblocking(False)
        call.listen = s
        call.socks.append(s)
        self.loop.watch(s, on_read=lambda: self._answered(call))

    def _my_addr(self, call, toward):
        """(ip, port) of the relay port as the callee's host can reach it."""
        return self._my_addr_ip(toward), call.listen.getsockname()[1]

    def _leave_invite(self, call, toward):
        """Our invitation for the callee, in our own table: their talk's
        LOOK_UP here finds the relay port."""
        r = Request()
        r.vers, r.type, r.id_num, r.pid = TALK_VERSION, LEAVE_INVITE, 0, 0
        r.addr_family = r.ctl_family = AF_INET_WIRE
        r.addr = self._my_addr(call, toward)
        r.ctl_addr = (r.addr[0], 0)
        r.l_name, r.r_name, r.r_tty = call.caller.user, call.callee, ""
        if call.invite is None or call.invite not in self.d.table:
            call.invite = self.d.insert(r)
        call.invite.when = self.d.clock()
        return r.addr

    def _ring_local(self, call, tty):
        if call.done:
            return
        t, answer = self.d.find_user(call.callee, tty)
        if answer != SUCCESS:
            self.end(call, "%s %s" % (call.callee, "is refusing messages"
                                      if answer == PERMISSION_DENIED else "is not logged in"))
            return
        self._leave_invite(call, "127.0.0.1")
        if not self.d.ring(t, call.caller.user, self.d.hostname):
            self.end(call, "cannot ring %s" % call.callee)
            return
        call.caller.send("STATE %s ringing %s on %s" % (call.sides[call.caller], call.callee, t))
        call.timers.append(self.loop.call_later(RING_WAIT, lambda: self._ring_local(call, tty)))

    # -- 'out' to another host: its talkd over UDP ------------------------------
    def _transact(self, call, rtype, id_num, on_answer, tries=CTL_TRIES):
        if call.done:
            return
        r = Request()
        r.vers, r.type, r.id_num, r.pid = TALK_VERSION, rtype, id_num, 0
        r.addr_family = r.ctl_family = AF_INET_WIRE
        if call.listen is not None:
            r.addr = self._my_addr(call, call.remote[0])
        else:
            r.addr = ("0.0.0.0", 0)
        r.ctl_addr = (self._my_addr_ip(call.remote[0]), call.ctl.getsockname()[1])
        r.l_name, r.r_name, r.r_tty = call.caller.user, call.callee, ""
        try:
            call.ctl.sendto(r.pack(), call.remote)
        except OSError as e:
            self.end(call, "cannot reach the talkd on %s: %s" % (call.remote[0], e))
            return
        call.pending = (rtype, on_answer)
        if tries > 1:
            retry = lambda: self._transact(call, rtype, id_num, on_answer, tries - 1)
        else:
            retry = lambda: self.end(call, "no answer from the talkd on %s" % call.remote[0])
        self.loop.cancel(getattr(call, "resend", None))
        call.resend = self.loop.call_later(CTL_WAIT, retry)

    @staticmethod
    def _my_addr_ip(toward):
        """Our address on the route to `toward` (connecting a UDP socket
        sends nothing; it only picks the route)."""
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            u.connect((toward, 9))
            return u.getsockname()[0]
        except OSError:
            return "127.0.0.1"
        finally:
            u.close()

    def _ctl_read(self, call):
        try:
            data = call.ctl.recv(1024)
        except OSError:
            return
        if len(data) < RESPONSE.size or getattr(call, "pending", None) is None:
            return
        _vers, rtype, answer, _pad, id_num, addr = RESPONSE.unpack(data[:RESPONSE.size])
        if rtype != call.pending[0]:
            return                       # a late answer to an earlier request
        on_answer = call.pending[1]
        call.pending = None
        self.loop.cancel(call.resend)
        _fam, ip, port = unpack_addr(addr)
        on_answer(call, answer, id_num, (ip, port))

    def _looked_up(self, call, answer, id_num, addr):
        if answer == SUCCESS:            # they called us first: connect to them
            self._connect_out(call, addr, call.caller)
            return
        self._listen(call)
        self._announce_remote(call, 0xFFFFFFFF)

    def _announce_remote(self, call, id_num):
        if call.done:
            return
        self._leave_invite(call, call.remote[0])
        self._transact(call, ANNOUNCE, id_num, self._announced)

    def _announced(self, call, answer, id_num, addr):
        if answer != SUCCESS:
            why = {NOT_HERE: "is not logged in", PERMISSION_DENIED: "is refusing messages",
                   MACHINE_UNKNOWN: "- their talkd does not know this host"}.get(
                       answer, "- their talkd says %s" % (ANSWERS[answer] if answer < 9 else answer))
            self.end(call, "%s %s" % (call.callee, why))
            return
        call.remote_id = id_num
        call.caller.send("STATE %s ringing %s@%s" % (call.sides[call.caller], call.callee,
                                                     call.remote[0]))
        call.timers.append(self.loop.call_later(
            RING_WAIT, lambda: self._announce_remote(call, (call.remote_id + 1) & 0xFFFFFFFF)))

    def _connect_out(self, call, addr, c):
        """Connect to a real talk waiting at addr; then CONNECT c to it."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setblocking(False)
        call.socks.append(s)
        rc = s.connect_ex(addr)
        if rc not in (0, errno.EINPROGRESS, errno.EWOULDBLOCK, errno.EALREADY):
            self.end(call, "cannot connect to %s:%d: %s" % (addr[0], addr[1], os.strerror(rc)))
            return

        def done():
            self.loop.watch(s)
            err = s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
            if err:
                self.end(call, "cannot connect to %s:%d: %s" % (addr[0], addr[1], os.strerror(err)))
                return
            self._offer(call, c, s)
        self.loop.watch(s, on_write=done)

    def _answered(self, call):
        """The callee's talk connected to our relay port."""
        try:
            s, _peer = call.listen.accept()
        except OSError:
            return
        _close(self.loop, call.listen)
        call.listen = None
        call.socks.append(s)
        self._offer(call, call.caller, s)

    # -- accepting, attaching, ending ------------------------------------------
    def accept(self, c, ident):
        call = self.calls.get(ident)
        if call is None or c not in call.ringing:
            c.send("GONE %s no such call" % ident)
            return
        for o in call.ringing:
            if o is not c:
                o.send("GONE %s answered elsewhere" % call.sides.pop(o))
        call.ringing = []
        if call.kind == "tv":
            self._offer(call, call.caller, None)
            self._offer(call, c, None)
            return
        # 'in': connect to the real talk that is waiting for us (its own
        # talk DELETEs the invitation once it is connected)
        if call.invite in self.d.table:
            self.d.table.remove(call.invite)
        call.invite = None
        self._connect_out(call, call.peer_addr, c)

    def _offer(self, call, c, sock):
        """CONNECT c to the call: a token for its data connection.  sock:
        the other end's socket, when that is a real talk."""
        self._stop_ringing(call)
        token = os.urandom(12).hex()
        call.waiting[token] = (c, sock)
        self.tokens[token] = call
        c.send("CONNECT %s %s" % (call.sides[c], token))
        call.timers.append(self.loop.call_later(
            ATTACH_WAIT, lambda: token in call.waiting and self.end(call, "never attached")))

    def _stop_ringing(self, call):
        for t in call.timers:
            self.loop.cancel(t)
        call.timers = []
        if call.invite is not None and call.invite in self.d.table:
            self.d.table.remove(call.invite)
        call.invite = None
        if call.remote is not None and call.remote_id is not None:
            self._delete_remote(call)

    def _delete_remote(self, call):
        r = Request()
        r.vers, r.type, r.id_num, r.pid = TALK_VERSION, DELETE, call.remote_id, 0
        r.addr_family = r.ctl_family = AF_INET_WIRE
        r.addr = ("0.0.0.0", 0)
        r.ctl_addr = (self._my_addr_ip(call.remote[0]), call.ctl.getsockname()[1])
        r.l_name, r.r_name, r.r_tty = call.caller.user if call.caller else "", call.callee, ""
        try:
            call.ctl.sendto(r.pack(), call.remote)
        except OSError:
            pass
        call.remote_id = None

    def attach(self, token, sock, first):
        call = self.tokens.pop(token, None)
        if call is None or token not in call.waiting:
            _close(self.loop, sock)
            return
        c, other = call.waiting.pop(token)
        if other is not None:            # a real talk at the other end
            self._splice(call, sock, other, first)
            return
        call.attached = getattr(call, "attached", []) + [(sock, first)]
        if len(call.attached) == 2:      # tvchat to tvchat: both are here
            (a, fa), (b, fb) = call.attached
            self._splice(call, a, b, fa, fb)

    def _splice(self, call, a, b, a_sent=b"", b_sent=b""):
        """a, b: the two ends; x_sent: what x sent already (after its ATTACH
        line), owed to the other."""
        call.pipe = Pipe(self.loop, a, b, lambda why: self.end(call, why),
                         to_a=b_sent, to_b=a_sent)

    def end(self, call, why):
        if call.done:
            return
        call.done = True
        self._stop_ringing(call)
        call.tell(lambda cid: "GONE %s %s" % (cid, why))
        for token in list(call.waiting):
            self.tokens.pop(token, None)
            sock = call.waiting[token][1]
            _close(self.loop, sock)
        call.waiting = {}
        if call.pipe is not None:
            call.pipe.close(why)
        for s in call.socks:
            _close(self.loop, s)
        self.calls.pop(call.id, None)


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


class Server:
    """The whole daemon: ntalk on UDP, tvchat's control and data
    connections on TCP, one loop.  Ports 0 pick free ones (tests)."""

    def __init__(self, bind="0.0.0.0", port=518, tcp_port=None, peer_port=518,
                 daemon=None):
        self.loop = Loop()
        self.d = daemon or TalkDaemon()
        self.relay = Relay(self.d, self.loop, peer_port=peer_port)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind((bind, port))
        self.udp.setblocking(False)
        self.tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.tcp.bind((bind, port if tcp_port is None else tcp_port))
        self.tcp.listen(16)
        self.tcp.setblocking(False)
        self.loop.watch(self.udp, on_read=self._udp)
        self.loop.watch(self.tcp, on_read=self._accept)

    def _udp(self):
        try:
            data, src = self.udp.recvfrom(1024)
        except OSError:
            return
        reply = self.d.process(data, src)
        if reply is not None:
            try:
                self.udp.sendto(reply, src)
            except OSError as e:
                _log.debug("%s: reply failed: %s", src, e)

    def _accept(self):
        try:
            s, peer = self.tcp.accept()
        except OSError:
            return
        Control(self.relay, s, peer)

    def run(self, stop=None):
        while not (stop and stop()):
            self.loop.run_once(0.5)

    def close(self):
        """Every socket the loop still watches: ours, tvchat's, the relays."""
        for key in list(self.loop.sel.get_map().values()):
            _close(self.loop, key.fileobj)
        for s in (self.udp, self.tcp):
            _close(self.loop, s)


def main(argv=None):
    ap = argparse.ArgumentParser(description="talk(1) daemon: ntalk on UDP, tvchat on TCP")
    ap.add_argument("--bind", default="0.0.0.0", help="address to listen on")
    ap.add_argument("--port", type=int, default=518,
                    help="UDP port for talk, and TCP port for tvchat (518)")
    ap.add_argument("--debug", action="store_true", help="log every request")
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if a.debug else logging.INFO,
                        format="talkd: %(message)s", stream=sys.stderr)
    srv = Server(a.bind, a.port)
    _log.info("listening on %s port %d (udp: talk, tcp: tvchat)", a.bind, a.port)
    try:
        srv.run()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
