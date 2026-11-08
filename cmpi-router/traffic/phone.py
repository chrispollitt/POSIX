#!/usr/bin/env python3
"""Read network byte counters from an Android phone (the FINAL-stage WAN tether) through an adb server. Stdlib only.

Why not the `adb` program: the traffic service must not spawn adb servers, needs no HOME directory, and may run only ONE fixed
command on the phone. So this speaks the adb "smart socket" protocol to an already running server itself:
    send  <4 hex digits of length><service>      e.g. "0012host:transport:SERIAL"
    read  "OKAY" (or "FAIL" + 4 hex digits + message)
and then the connection is a stream to the phone. The only services ever requested are the fixed ones below.

The adb server (see bin/setup-phone.sh) listens on a Unix socket that only the `adbphone` and `trafficgraph` users can open,
so nothing else on the router (PHP, nginx, LibreNMS) can get a shell on the phone.
"""
import re
import socket
import time

NETDEV = "exec:cat /proc/net/dev"
UPSTREAM = "exec:dumpsys tethering"
MODEL = "exec:getprop ro.product.model"
VERSION = "exec:getprop ro.build.version.release"
UPSTREAM_RE = re.compile(r"Current upstream interface\(s\): \[([^\]]*)\]")
MAX_BYTES = 2 * 1024 * 1024          # a reply larger than this is not what we asked for


class AdbError(Exception):
    pass


def connect(spec, timeout):
    """spec: tcp:HOST:PORT | tcp:PORT | localfilesystem:/path | local:/path | unix:/path"""
    kind, _, rest = spec.partition(":")
    if kind in ("localfilesystem", "local", "unix"):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(rest)
        return s
    if kind == "tcp":
        host, _, port = rest.rpartition(":")
        return socket.create_connection((host or "127.0.0.1", int(port)), timeout)
    raise AdbError("unsupported adb socket spec %r" % spec)


def _recv_exact(s, n, deadline):
    buf = b""
    while len(buf) < n:
        s.settimeout(max(0.1, deadline - time.monotonic()))
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise AdbError("adb server closed the connection")
        buf += chunk
    return buf


def _send_service(s, service, deadline):
    data = service.encode()
    s.sendall(b"%04x" % len(data) + data)
    status = _recv_exact(s, 4, deadline)
    if status == b"OKAY":
        return
    if status == b"FAIL":
        n = int(_recv_exact(s, 4, deadline), 16)
        raise AdbError(_recv_exact(s, n, deadline).decode("utf-8", "replace"))
    raise AdbError("unexpected reply from the adb server: %r" % status)


def run(spec, serial, service, timeout=8):
    """Open a transport to the phone (`serial`, or the only device if empty), run ONE fixed service, return its output as text."""
    deadline = time.monotonic() + timeout
    s = connect(spec, timeout)
    try:
        _send_service(s, "host:transport:%s" % serial if serial else "host:transport-any", deadline)
        _send_service(s, service, deadline)
        out = b""
        while len(out) <= MAX_BYTES:
            s.settimeout(max(0.1, deadline - time.monotonic()))
            chunk = s.recv(65536)
            if not chunk:
                break
            out += chunk
        else:
            raise AdbError("reply too large")
        return out.decode("utf-8", "replace").replace("\r\n", "\n")
    except socket.timeout:
        raise AdbError("timed out waiting for the phone")
    finally:
        s.close()


def parse_netdev(text):
    """/proc/net/dev -> {name: (rx_bytes, tx_bytes)}"""
    out = {}
    for line in text.splitlines()[2:]:
        name, sep, rest = line.partition(":")
        p = rest.split()
        if sep and len(p) >= 9 and p[0].isdigit() and p[8].isdigit():
            out[name.strip()] = (int(p[0]), int(p[8]))
    return out


def parse_upstream(text):
    """`dumpsys tethering` -> list of upstream interface names ([] if none; None if the line is missing)."""
    m = UPSTREAM_RE.search(text)
    if not m:
        return None
    return [x.strip() for x in m.group(1).split(",") if x.strip()]


def counters(spec, serial, timeout=8):
    return parse_netdev(run(spec, serial, NETDEV, timeout))


def upstream(spec, serial, timeout=10):
    return parse_upstream(run(spec, serial, UPSTREAM, timeout))


def identity(spec, serial, timeout=6):
    return {"model": run(spec, serial, MODEL, timeout).strip() or None, "android": run(spec, serial, VERSION, timeout).strip() or None}
