#!/usr/bin/env python3
"""Tests for chat-setup/talkd/talkd.py: the ntalk codec, the invitation
table, the four requests, the tty announcement and utmp - with fake
terminals (plain files), a fake clock and a fake talk client over UDP on
127.0.0.1.  Stdlib only, no root, no network.

    python3 -m unittest discover -s chat-setup/tests -p test_talkd.py
"""
import importlib.util
import os
import shutil
import socket
import struct
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("talkd", str(HERE.parent / "talkd" / "talkd.py"))
td = importlib.util.module_from_spec(spec)
spec.loader.exec_module(td)


class Clock:
    def __init__(self, t=1000000.0):
        self.t = t

    def __call__(self):
        return self.t


def req(rtype, l_name="alice", r_name="bob", r_tty="", id_num=0, pid=42,
        addr=("192.168.10.5", 40000), ctl=("192.168.10.5", 40001), vers=1):
    r = td.Request()
    r.vers, r.type, r.id_num, r.pid = vers, rtype, id_num, pid
    r.addr_family = r.ctl_family = td.AF_INET_WIRE
    r.addr, r.ctl_addr = addr, ctl
    r.l_name, r.r_name, r.r_tty = l_name, r_name, r_tty
    return r.pack()


def answer(raw):
    """(type, answer, id, (ip, port)) of a CTL_RESPONSE."""
    vers, rtype, ans, _pad, id_num, addr = td.RESPONSE.unpack(raw)
    _fam, ip, port = td.unpack_addr(addr)
    return rtype, ans, id_num, (ip, port)


SRC = ("192.168.10.5", 40001)


class TalkdBase(unittest.TestCase):
    def setUp(self):
        self.dev = Path(tempfile.mkdtemp(prefix="talkd-t-"))
        self.addCleanup(shutil.rmtree, str(self.dev), True)
        self.users = []                  # (user, tty) "logged in"
        self.clock = Clock()
        self.d = td.TalkDaemon(logins=lambda: list(self.users), devdir=str(self.dev),
                               clock=self.clock, hostname="cpbee",
                               resolve=lambda ip: {"192.168.10.5": "cmlaptop"}.get(ip, ip))

    def tty(self, user, name, mesg=True, idle=0):
        p = self.dev / name
        p.write_bytes(b"")
        p.chmod(0o620 if mesg else 0o600)
        t = self.clock() - idle
        os.utime(str(p), (t, t))
        self.users.append((user, name))
        return p

    def ask(self, data, src=SRC):
        return answer(self.d.process(data, src))


class TestCodec(unittest.TestCase):
    def test_sizes_and_big_endian(self):
        self.assertEqual((td.MSG.size, td.RESPONSE.size), (84, 24))
        raw = td.pack_addr(("192.168.10.1", 518))
        # family 2 big-endian - the classic trap - then the port, the address
        self.assertEqual(raw, b"\x00\x02\x02\x06\xc0\xa8\x0a\x01" + b"\0" * 8)
        self.assertEqual(td.unpack_addr(raw), (2, "192.168.10.1", 518))

    def test_request_round_trip(self):
        m = td.Request.parse(req(td.ANNOUNCE, r_tty="pts/3", id_num=7))
        self.assertEqual((m.type, m.id_num, m.l_name, m.r_name, m.r_tty, m.pid),
                         (td.ANNOUNCE, 7, "alice", "bob", "pts/3", 42))
        self.assertEqual((m.addr, m.ctl_addr), (("192.168.10.5", 40000), SRC))
        # a full 12-character name has no NUL at all
        m = td.Request.parse(req(td.LOOK_UP, l_name="twelve_chars"))
        self.assertEqual(m.l_name, "twelve_chars")

    def test_short_packet_is_ignored(self):
        self.assertIsNone(td.Request.parse(b"\x01\x01"))


class TestRequests(TalkdBase):
    def test_leave_invite_look_up_delete(self):
        t, a, ident, _ = self.ask(req(td.LEAVE_INVITE))
        self.assertEqual((t, a, ident), (td.LEAVE_INVITE, td.SUCCESS, 1))
        # the caller's re-send keeps its id
        self.assertEqual(self.ask(req(td.LEAVE_INVITE))[2], 1)
        # bob looks for alice's invitation: the address to connect to
        t, a, ident, addr = self.ask(req(td.LOOK_UP, l_name="bob", r_name="alice"))
        self.assertEqual((t, a, ident, addr),
                         (td.LOOK_UP, td.SUCCESS, 1, ("192.168.10.5", 40000)))
        # nobody left one for carol
        self.assertEqual(self.ask(req(td.LOOK_UP, l_name="carol", r_name="alice"))[1],
                         td.NOT_HERE)
        self.assertEqual(self.ask(req(td.DELETE, id_num=1))[:2], (td.DELETE, td.SUCCESS))
        self.assertEqual(self.ask(req(td.DELETE, id_num=1))[1], td.NOT_HERE)
        self.assertEqual(self.ask(req(td.LOOK_UP, l_name="bob", r_name="alice"))[1],
                         td.NOT_HERE)

    def test_invitations_expire(self):
        self.ask(req(td.LEAVE_INVITE))
        self.clock.t += td.MAX_LIFE + 1
        self.assertEqual(self.ask(req(td.LOOK_UP, l_name="bob", r_name="alice"))[1],
                         td.NOT_HERE)

    def test_bad_requests(self):
        self.assertEqual(self.ask(req(td.LOOK_UP, vers=2))[1], td.BADVERSION)
        self.assertEqual(self.ask(req(9))[:2], (9, td.UNKNOWN_REQUEST))
        self.assertEqual(self.ask(req(td.LOOK_UP, l_name="a\x07b"))[1], td.FAILED)
        self.assertEqual(self.ask(req(td.LOOK_UP, l_name=""))[1], td.FAILED)
        # sa_family little-endian (2 as 0x0200): refused, as BSD talkd does
        raw = bytearray(req(td.LOOK_UP))
        raw[8:10] = b"\x02\x00"
        self.assertEqual(self.ask(bytes(raw))[1], td.BADADDR)
        raw = bytearray(req(td.LOOK_UP))
        raw[24:26] = b"\x02\x00"
        self.assertEqual(self.ask(bytes(raw))[1], td.BADCTLADDR)
        self.assertIsNone(self.d.process(b"hello", SRC))


class TestAnnounce(TalkdBase):
    def test_rings_the_least_idle_writable_terminal(self):
        old = self.tty("bob", "pts1", idle=600)
        new = self.tty("bob", "pts2", idle=5)
        self.tty("bob", "pts3", mesg=False, idle=0)       # mesg n: skipped
        t, a, ident, _ = self.ask(req(td.ANNOUNCE))
        self.assertEqual((t, a, ident), (td.ANNOUNCE, td.SUCCESS, 1))
        text = new.read_text(encoding="latin-1")
        self.assertIn("Message from Talk_Daemon@cpbee at", text)
        self.assertIn("talk: connection requested by alice@cmlaptop.", text)
        self.assertIn("talk: respond with:  talk alice@cmlaptop", text)
        self.assertIn("\a", text)
        self.assertEqual(old.read_bytes(), b"")

    def test_named_tty(self):
        a = self.tty("bob", "pts1", idle=600)
        self.tty("bob", "pts2", idle=5)
        self.assertEqual(self.ask(req(td.ANNOUNCE, r_tty="pts1"))[1], td.SUCCESS)
        self.assertIn(b"alice@cmlaptop", a.read_bytes())

    def test_not_logged_in_and_mesg_n(self):
        self.assertEqual(self.ask(req(td.ANNOUNCE))[1], td.NOT_HERE)
        self.tty("bob", "pts1", mesg=False)
        self.assertEqual(self.ask(req(td.ANNOUNCE))[1], td.PERMISSION_DENIED)

    def test_rings_again_only_for_a_newer_id(self):
        p = self.tty("bob", "pts1")
        ident = self.ask(req(td.ANNOUNCE))[2]
        # the same packet again (a lost reply): not rung twice
        self.assertEqual(self.ask(req(td.ANNOUNCE))[2], ident)
        self.assertEqual(p.read_bytes().count(b"Message from"), 1)
        # talk's next ring carries the id it was given, plus one
        again = self.ask(req(td.ANNOUNCE, id_num=ident + 1))
        self.assertEqual(again[1], td.SUCCESS)
        self.assertGreater(again[2], ident)
        self.assertEqual(p.read_bytes().count(b"Message from"), 2)

    def test_unknown_host_is_shown_by_address(self):
        p = self.tty("bob", "pts1")
        self.ask(req(td.ANNOUNCE, ctl=("10.9.9.9", 5000)), src=("10.9.9.9", 5000))
        self.assertIn(b"requested by alice@10.9.9.9.", p.read_bytes())

    def test_a_terminal_that_cannot_be_written(self):
        self.tty("bob", "pts1")
        (self.dev / "pts1").unlink()
        self.users.append(("bob", "gone"))
        self.assertEqual(self.ask(req(td.ANNOUNCE))[1], td.NOT_HERE)


class TestUtmp(unittest.TestCase):
    def test_user_processes_only(self):
        def rec(utype, user, line):
            return td.UTMP.pack(utype, 0, 123, line.encode(), b"ts/1", user.encode(),
                                b"host", 0, 0, 0, 0, 0, 0, 0, 0, 0, b"")
        tmp = Path(tempfile.mkdtemp(prefix="talkd-u-"))
        self.addCleanup(shutil.rmtree, str(tmp), True)
        f = tmp / "utmp"
        f.write_bytes(rec(2, "reboot", "~") + rec(7, "bob", "pts/1") +
                      rec(8, "dead", "pts/2") + rec(7, "alice", "tty1"))
        self.assertEqual(td.UTMP.size, 384)
        self.assertEqual(td.utmp_logins(str(f)), [("bob", "pts/1"), ("alice", "tty1")])
        self.assertIsNone(td.utmp_logins(str(tmp / "none")))
        # utmp there: it is what counts, even when the terminals say more
        self.assertEqual(td.system_logins(str(tmp), str(f)), [("bob", "pts/1"), ("alice", "tty1")])

    def test_no_utmp_the_terminals_owners(self):
        # cpbee (Debian 13), Oct 22: no /run/utmp at all - `who` asks
        # systemd-logind - so every call was "not logged on"
        import pwd
        me = pwd.getpwuid(os.getuid()).pw_name
        dev = Path(tempfile.mkdtemp(prefix="talkd-d-"))
        self.addCleanup(shutil.rmtree, str(dev), True)
        (dev / "pts").mkdir()
        for name in ("pts/1", "pts/12", "pts/ptmx", "tty3", "ttyS0", "console"):
            (dev / name).write_bytes(b"")
        self.assertEqual(td.tty_logins(str(dev)), [("%s" % me, "pts/1"), (me, "pts/12"), (me, "tty3")])
        self.assertEqual(td.system_logins(str(dev), str(dev / "no-utmp")), td.tty_logins(str(dev)))
        # and a daemon with no logins= given uses exactly that, on a host with
        # no utmp (this one may have its own: point the lookup at nowhere)
        self.addCleanup(setattr, td, "UTMP_FILES", td.UTMP_FILES)
        td.UTMP_FILES = (str(dev / "no-utmp"),)
        d = td.TalkDaemon(devdir=str(dev), hostname="cpbee")
        (dev / "pts" / "1").chmod(0o620)
        self.assertEqual(d.find_user(me)[1], td.SUCCESS)
        self.assertEqual(td.tty_logins(str(dev / "nowhere")), [])


class TestOverUdp(TalkdBase):
    def test_a_talk_client_round_trip(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        srv.bind(("127.0.0.1", 0))
        stop = threading.Event()
        th = threading.Thread(target=td.serve, args=(self.d, srv, stop.is_set), daemon=True)
        th.start()
        self.addCleanup(srv.close)
        self.addCleanup(th.join, 3)
        self.addCleanup(stop.set)
        cli = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        cli.settimeout(3)
        self.addCleanup(cli.close)
        cli.bind(("127.0.0.1", 0))
        me = cli.getsockname()
        cli.sendto(req(td.LEAVE_INVITE, addr=("127.0.0.1", 4444), ctl=me),
                   srv.getsockname())
        self.assertEqual(answer(cli.recv(64))[:3], (td.LEAVE_INVITE, td.SUCCESS, 1))
        cli.sendto(req(td.LOOK_UP, l_name="bob", r_name="alice", ctl=me), srv.getsockname())
        self.assertEqual(answer(cli.recv(64)), (td.LOOK_UP, td.SUCCESS, 1, ("127.0.0.1", 4444)))
        # garbage gets no answer, and the daemon goes on
        cli.sendto(b"junk", srv.getsockname())
        cli.sendto(req(td.LOOK_UP, l_name="nobody", ctl=me), srv.getsockname())
        self.assertEqual(answer(cli.recv(64))[1], td.NOT_HERE)


# --------------------------------------------------------------------------
# tvchat users and the relay: a whole Server on 127.0.0.1 (free ports), a
# fake tvchat (the control protocol) and a fake talk (ntalk over UDP, plus
# the TCP socket a talk listens on).
# --------------------------------------------------------------------------
class TvChat:
    def __init__(self, srv, user=None):
        self.srv = srv
        self.sock = socket.create_connection(srv.tcp.getsockname(), 5)
        self.buf = b""
        self.got = []
        if user:
            self.say("HELLO " + user)
            self.expect("OK %s@" % user)

    def say(self, line):
        self.sock.sendall((line + "\n").encode())

    def expect(self, prefix):
        """The first not-yet-taken line starting with prefix."""
        while True:
            for i, ln in enumerate(self.got):
                if ln.startswith(prefix):
                    del self.got[i]
                    return ln
            while b"\n" not in self.buf:
                data = self.sock.recv(4096)
                if not data:
                    raise AssertionError("talkd hung up waiting for %r" % prefix)
                self.buf += data
            ln, self.buf = self.buf.split(b"\n", 1)
            self.got.append(ln.decode())

    def lines_now(self, wait=0.3):
        """Whatever arrives within `wait` (to show nothing more came)."""
        self.sock.settimeout(wait)
        try:
            while True:
                data = self.sock.recv(4096)
                if not data:
                    break
                self.buf += data
        except socket.timeout:
            pass
        finally:
            self.sock.settimeout(5)
        while b"\n" in self.buf:
            ln, self.buf = self.buf.split(b"\n", 1)
            self.got.append(ln.decode())
        return list(self.got)

    def attach(self, connect_line, first=b""):
        token = connect_line.split()[2]
        d = socket.create_connection(self.srv.tcp.getsockname(), 5)
        d.sendall(b"ATTACH " + token.encode() + b"\n" + first)
        return d

    def close(self):
        self.sock.close()


class FakeTalk:
    """A talk client: a UDP control socket and the TCP socket it listens on."""

    def __init__(self, name):
        self.name = name
        self.ctl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.ctl.bind(("127.0.0.1", 0))
        self.ctl.settimeout(3)
        self.lsn = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.lsn.bind(("127.0.0.1", 0))
        self.lsn.listen(1)
        self.lsn.settimeout(5)

    def ask(self, srv, rtype, r_name, id_num=0):
        self.ctl.sendto(req(rtype, l_name=self.name, r_name=r_name, id_num=id_num,
                            addr=self.lsn.getsockname(), ctl=self.ctl.getsockname()),
                        srv.udp.getsockname())
        return answer(self.ctl.recv(64))

    def close(self):
        self.ctl.close()
        self.lsn.close()


def recv_until(sock, want, timeout=5):
    sock.settimeout(timeout)
    got = b""
    while want not in got:
        data = sock.recv(4096)
        if not data:
            break
        got += data
    return got


class RelayBase(TalkdBase):
    def server(self, users=None, devdir=None, resolve=None, **kw):
        d = td.TalkDaemon(logins=(lambda: list(users)) if users is not None else (lambda: []),
                          devdir=devdir or str(self.dev), hostname="cpbee",
                          resolve=resolve or (lambda ip: "cmlaptop" if ip == "127.0.0.1" else ip))
        srv = td.Server("127.0.0.1", 0, tcp_port=0, daemon=d, **kw)
        stop = threading.Event()
        th = threading.Thread(target=srv.run, args=(stop.is_set,), daemon=True)
        th.start()
        self.addCleanup(srv.close)
        self.addCleanup(th.join, 3)
        self.addCleanup(stop.set)
        return srv

    def tv(self, srv, user):
        c = TvChat(srv, user)
        self.addCleanup(c.close)
        return c

    def talk(self, name):
        t = FakeTalk(name)
        self.addCleanup(t.close)
        return t


class TestRelay(RelayBase):
    def test_tvchat_to_tvchat(self):
        srv = self.server()
        a, b = self.tv(srv, "chris"), self.tv(srv, "miche")
        a.say("CALL c1 miche")
        a.expect("STATE c1 ringing miche")
        ring = b.expect("RING ")
        self.assertRegex(ring, r"^RING t\d+ chris@cpbee$")
        b.say("ACCEPT " + ring.split()[1])
        ca, cb = a.expect("CONNECT c1 "), b.expect("CONNECT " + ring.split()[1])
        # what chris sends right after ATTACH (talk's edit characters first)
        # reaches miche even though she attaches later
        da = a.attach(ca, b"\x7f\x15\x17hi miche")
        db = b.attach(cb)
        self.addCleanup(da.close)
        self.addCleanup(db.close)
        self.assertEqual(recv_until(db, b"hi miche"), b"\x7f\x15\x17hi miche")
        db.sendall(b"\x08\x15\x17yo")
        self.assertEqual(recv_until(da, b"yo"), b"\x08\x15\x17yo")
        da.close()
        self.assertEqual(recv_until(db, b"never"), b"")         # EOF: hung up
        a.expect("GONE c1 hung up")
        b.expect("GONE %s hung up" % ring.split()[1])

    def test_a_real_talk_calls_a_tvchat_user(self):
        srv = self.server()
        c = self.tv(srv, "chris")
        alice = self.talk("alice")
        self.assertEqual(alice.ask(srv, td.LOOK_UP, "chris")[1], td.NOT_HERE)
        t, a, ident, _ = alice.ask(srv, td.ANNOUNCE, "chris", id_num=0xFFFFFFFF)
        self.assertEqual((t, a), (td.ANNOUNCE, td.SUCCESS))
        ring = c.expect("RING ")
        self.assertRegex(ring, r"^RING t\d+ alice@cmlaptop$")
        # talk rings again every 30 s: tvchat is told once
        self.assertEqual(alice.ask(srv, td.ANNOUNCE, "chris", id_num=ident + 1)[1], td.SUCCESS)
        self.assertFalse([ln for ln in c.lines_now() if ln.startswith("RING")])
        c.say("ACCEPT " + ring.split()[1])
        conn, _ = alice.lsn.accept()             # talkd connected to alice
        self.addCleanup(conn.close)
        d = c.attach(c.expect("CONNECT " + ring.split()[1]))
        self.addCleanup(d.close)
        conn.sendall(b"\x7f\x15\x17hello chris")
        self.assertEqual(recv_until(d, b"chris"), b"\x7f\x15\x17hello chris")
        d.sendall(b"hi alice")
        self.assertEqual(recv_until(conn, b"alice"), b"hi alice")
        conn.close()
        c.expect("GONE %s hung up" % ring.split()[1])

    def test_the_caller_gives_up(self):
        srv = self.server()
        c = self.tv(srv, "chris")
        alice = self.talk("alice")
        ident = alice.ask(srv, td.ANNOUNCE, "chris", id_num=0xFFFFFFFF)[2]
        ring = c.expect("RING ")
        self.assertEqual(alice.ask(srv, td.DELETE, "chris", id_num=ident)[1], td.SUCCESS)
        c.expect("GONE %s the caller gave up" % ring.split()[1])

    def test_tvchat_calls_someone_logged_in_here(self):
        tty = self.dev / "pts1"
        tty.write_bytes(b"")
        tty.chmod(0o620)
        srv = self.server(users=[("bob", "pts1")])
        c = self.tv(srv, "chris")
        c.say("CALL c1 bob")
        c.expect("STATE c1 ringing bob on pts1")
        self.assertIn(b"respond with:  talk chris@cpbee", tty.read_bytes())
        # bob's talk looks here, finds our invitation: the relay port
        bob = self.talk("bob")
        t, a, _ident, addr = bob.ask(srv, td.LOOK_UP, "chris")
        self.assertEqual((t, a), (td.LOOK_UP, td.SUCCESS))
        conn = socket.create_connection(addr, 5)
        self.addCleanup(conn.close)
        d = c.attach(c.expect("CONNECT c1 "), b"hey bob")
        self.addCleanup(d.close)
        self.assertEqual(recv_until(conn, b"bob"), b"hey bob")
        conn.sendall(b"hey chris")
        self.assertEqual(recv_until(d, b"chris"), b"hey chris")
        # connected: the invitation is gone
        self.assertEqual(bob.ask(srv, td.LOOK_UP, "chris")[1], td.NOT_HERE)

    def test_tvchat_calls_someone_on_another_host(self):
        other = Path(tempfile.mkdtemp(prefix="talkd-h-"))
        self.addCleanup(shutil.rmtree, str(other), True)
        tty = other / "pts7"
        tty.write_bytes(b"")
        tty.chmod(0o620)
        host = self.server(users=[("bob", "pts7")], devdir=str(other))
        srv = self.server()
        srv.relay.peer_port = host.udp.getsockname()[1]
        c = self.tv(srv, "chris")
        c.say("CALL c1 bob@127.0.0.1")
        c.expect("STATE c1 looking for an invitation on 127.0.0.1")
        c.expect("STATE c1 ringing bob@127.0.0.1")
        self.assertIn(b"talk: connection requested by chris@cmlaptop.", tty.read_bytes())
        self.assertEqual(len(host.d.table), 1)
        # bob answers "talk chris@cpbee": his talk looks on cpbee - us
        bob = self.talk("bob")
        t, a, _ident, addr = bob.ask(srv, td.LOOK_UP, "chris")
        self.assertEqual(a, td.SUCCESS)
        conn = socket.create_connection(addr, 5)
        self.addCleanup(conn.close)
        d = c.attach(c.expect("CONNECT c1 "))
        self.addCleanup(d.close)
        conn.sendall(b"from bob")
        self.assertEqual(recv_until(d, b"bob"), b"from bob")
        # and the ring on bob's host was taken back (DELETE)
        for _ in range(30):
            if not host.d.table:
                break
            time.sleep(0.1)
        self.assertEqual(host.d.table, [])

    def test_refusals_and_hangups(self):
        srv = self.server()
        c = TvChat(srv)
        self.addCleanup(c.close)
        c.say("CALL c1 bob")
        c.expect("ERR say HELLO USER first")
        c.say("HELLO has space")
        c.expect("ERR HELLO needs a user name")
        c.say("HELLO chris")
        c.expect("OK chris@cpbee")
        c.say("HELLO chris")
        c.expect("ERR already HELLO chris")
        c.say("PING")
        c.expect("PONG")
        c.say("FROB x")
        c.expect("ERR unknown or malformed: FROB x")
        c.say("CALL c1 nobody")
        c.expect("GONE c1 nobody is not logged in")
        # a tvchat call hung up before it is answered
        m = self.tv(srv, "miche")
        c.say("CALL c2 miche")
        ring = m.expect("RING ")
        c.say("HANGUP c2")
        m.expect("GONE %s hung up" % ring.split()[1])
        c.expect("GONE c2 hung up")
        # declined by every tvchat the callee has open
        c.say("CALL c3 miche")
        ring = m.expect("RING ")
        m.say("DECLINE " + ring.split()[1])
        c.expect("GONE c3 declined")

    @unittest.skipUnless(td.PKTINFO is not None, "IP_PKTINFO: Linux only")
    def test_answers_from_the_address_it_was_asked_at(self):
        # cpbee, Oct 22: Debian's talk connect()s its socket to 127.0.1.1 (the
        # host's own name); a reply from 127.0.0.1 never reached it
        d = td.TalkDaemon(logins=lambda: [], devdir=str(self.dev), hostname="cpbee")
        srv = td.Server("0.0.0.0", 0, tcp_port=0, daemon=d)
        stop = threading.Event()
        th = threading.Thread(target=srv.run, args=(stop.is_set,), daemon=True)
        th.start()
        self.addCleanup(srv.close)
        self.addCleanup(th.join, 3)
        self.addCleanup(stop.set)
        self.assertTrue(srv.pktinfo)
        for ip in ("127.0.0.1", "127.0.1.1"):
            c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.addCleanup(c.close)
            c.settimeout(3)
            c.connect((ip, srv.udp.getsockname()[1]))
            c.send(req(td.LOOK_UP, ctl=c.getsockname()))
            self.assertEqual(answer(c.recv(64))[1], td.NOT_HERE, ip)

    def test_relay_ports_come_from_the_range(self):
        for name in ("pts1", "pts2"):
            p = self.dev / name
            p.write_bytes(b"")
            p.chmod(0o620)
        probe = socket.socket()
        probe.bind(("0.0.0.0", 0))
        port = probe.getsockname()[1]            # a free port: the range is one wide
        probe.close()
        srv = self.server(users=[("bob", "pts1"), ("carol", "pts2")], relay_ports=(port, port))
        c = self.tv(srv, "chris")
        c.say("CALL c1 bob")
        c.expect("STATE c1 ringing bob")
        _t, a, _i, addr = self.talk("bob").ask(srv, td.LOOK_UP, "chris")
        self.assertEqual((a, addr[1]), (td.SUCCESS, port))
        # the one relay port is taken: a second call at once is refused
        c.say("CALL c2 carol")
        c.expect("GONE c2 too many calls at once (relay ports %d-%d all busy)" % (port, port))

    def test_allow_keeps_out_everyone_else(self):
        srv = self.server(allow=["10.0.0.0/8"])          # not 127.0.0.1
        alice = self.talk("alice")
        alice.ctl.settimeout(0.5)
        with self.assertRaises(socket.timeout):
            alice.ask(srv, td.LOOK_UP, "chris")
        s = socket.create_connection(srv.tcp.getsockname(), 5)
        self.addCleanup(s.close)
        s.sendall(b"HELLO chris\n")
        try:                                     # closed, no answer (EOF, or a
            got = recv_until(s, b"\n")           # reset: it had unread data)
        except OSError:
            got = b""
        self.assertEqual(got, b"")
        self.assertFalse(srv.relay.has_user("chris"))
        self.assertTrue(srv.allowed("10.1.2.3") and not srv.allowed("192.168.10.5"))

    def test_another_host_whose_talkd_does_not_answer(self):
        old = td.CTL_WAIT
        td.CTL_WAIT = 0.2
        self.addCleanup(setattr, td, "CTL_WAIT", old)
        dead = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        dead.bind(("127.0.0.1", 0))              # a port nobody answers on
        self.addCleanup(dead.close)
        srv = self.server()
        srv.relay.peer_port = dead.getsockname()[1]
        c = self.tv(srv, "chris")
        c.say("CALL c1 bob@127.0.0.1")
        c.expect("GONE c1 no answer from the talkd on 127.0.0.1")


if __name__ == "__main__":
    unittest.main()
