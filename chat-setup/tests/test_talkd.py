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
        self.assertEqual(td.utmp_logins(str(tmp / "none")), [])


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


if __name__ == "__main__":
    unittest.main()
