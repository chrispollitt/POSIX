#!/usr/bin/env python3
"""Router status for the cpbee web UI: WAN/LAN/VR180 link state, devices (active or not), firewall summary, diagnostics.

Stdlib only, NO privileges: everything is read from /sys, /proc, `ip -j`, `resolvectl`, `iw` and the router's own config files.
Read-only by design: nothing here changes the router. The only actions are ping, traceroute, a name lookup and an
internet check, each with a fixed command line (the target is validated; no shell is ever involved).

Used by server.py: collect() builds /api/router, diag() serves POST /api/diag, start_prober() runs the background sweep
that decides which devices are active (a device is "active" if it answers a ping or the kernel has just confirmed its ARP entry).
"""
import glob
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time

LAN, WAN, VR, VAX = "lan0", "wan0", "vr180", "vaxtap"
LEASES = os.environ.get("TRAFFIC_LEASES", "/var/lib/misc/dnsmasq.leases")
DNSMASQ_GLOB = os.environ.get("TRAFFIC_DNSMASQ_GLOB", "/etc/dnsmasq.d/*.conf")
SETUP_DIR = os.environ.get("TRAFFIC_SETUP_DIR", "/etc/router-setup")
SWEEP_S = int(os.environ.get("TRAFFIC_SWEEP_S", "30"))     # how often devices are probed
SETTLE_S = 6                                               # ARP re-validation (DELAY 5 s -> PROBE) needs this long to finish
PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV = {"LC_ALL": "C", "PATH": PATH}
MAC = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", re.I)
HOST = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$")


def which(name):
    return shutil.which(name, path=PATH)


def run(cmd, timeout=4):
    """(returncode, stdout) of a fixed argv list; (None, "") when it cannot run or times out."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, env=ENV)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, ""


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def ip_json(*args):
    rc, out = run(["ip", "-j"] + list(args))
    try:
        return json.loads(out) if rc == 0 and out.strip() else []
    except ValueError:
        return []


# ---------------------------------------------------------------- links
def link_info(name, addrs):
    d = "/sys/class/net/" + name
    if not os.path.isdir(d):
        return {"name": name, "present": False}
    try:
        speed = int(read(d + "/speed", "-1"))
    except ValueError:
        speed = -1
    dev = os.path.realpath(d + "/device") if os.path.exists(d + "/device") else ""
    drv = os.path.basename(os.path.realpath(d + "/device/driver")) if os.path.exists(d + "/device/driver") else ""
    bus = "wifi" if os.path.isdir(d + "/wireless") else "usb" if "/usb" in dev else "pci" if dev else "virtual"
    return {"name": name, "present": True, "state": read(d + "/operstate"), "carrier": read(d + "/carrier") == "1",
            "speed_mbit": speed if speed > 0 else None, "duplex": read(d + "/duplex") or None,
            "mac": read(d + "/address"), "mtu": int(read(d + "/mtu", "0") or 0), "driver": drv, "bus": bus,
            "addrs": addrs.get(name, [])}


def address_map():
    m = {}
    for i in ip_json("-4", "addr", "show"):
        lst = m.setdefault(i.get("ifname"), [])
        for a in i.get("addr_info", []):
            if a.get("family") != "inet":
                continue
            vl = a.get("valid_life_time")
            lst.append({"ip": a["local"], "prefix": a["prefixlen"], "dynamic": bool(a.get("dynamic")),
                        "lease_s": None if vl in (None, 4294967295) else vl})
    return m


def default_routes():
    return [{"gw": r.get("gateway"), "dev": r.get("dev"), "metric": r.get("metric"), "proto": r.get("protocol")}
            for r in ip_json("-4", "route", "show", "default")]


def link_dns(name):
    rc, out = run(["resolvectl", "dns", name])
    if rc != 0 or ":" not in out:
        return []
    return [t for t in out.split(":", 1)[1].split() if re.match(r"^[0-9a-fA-F.:]+$", t)]


def wifi_info(name):
    iw = which("iw")
    if not iw:
        return None
    rc, out = run([iw, "dev", name, "link"])
    if rc != 0 or "Connected" not in out:
        return {"connected": False}
    g = lambda pat: (re.search(pat, out) or [None, None])[1]
    return {"connected": True, "ssid": g(r"SSID: (.*)"), "signal_dbm": int(g(r"signal: (-?\d+)") or 0) or None,
            "freq_mhz": int(g(r"freq: (\d+)") or 0) or None, "bitrate": g(r"tx bitrate: (.*)")}


def private(addr):
    try:
        return ipaddress.ip_address(addr).is_private
    except ValueError:
        return False


# ---------------------------------------------------------------- dnsmasq data
def dnsmasq_lines():
    for fn in sorted(glob.glob(DNSMASQ_GLOB)):
        for line in read(fn).splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                yield line


def static_leases():
    out = []
    for line in dnsmasq_lines():
        if line.startswith("dhcp-host="):
            toks = [t.strip() for t in line[len("dhcp-host="):].split(",")]
            mac = next((t for t in toks if MAC.match(t)), None)
            ip = next((t for t in toks if re.match(r"^\d+\.\d+\.\d+\.\d+$", t)), None)
            name = next((t for t in toks if t and t != mac and t != ip and not t.startswith(("set:", "id:", "tag:", "ignore"))
                         and not re.match(r"^(\d+[smhd]?|infinite)$", t)), None)
            if ip:
                out.append({"mac": (mac or "").lower(), "ip": ip, "name": name or ""})
    return out


def host_records():
    """name -> ip from dnsmasq host-record lines (first name wins)."""
    out = {}
    for line in dnsmasq_lines():
        if line.startswith("host-record="):
            toks = line[len("host-record="):].split(",")
            ip = toks[-1].strip()
            if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip) and toks[:-1]:
                out[toks[0].strip()] = ip
    return out


def dhcp_range():
    for line in dnsmasq_lines():
        if line.startswith("dhcp-range="):
            t = line[len("dhcp-range="):].split(",")
            if len(t) >= 2:
                return {"from": t[0], "to": t[1], "lease": t[3] if len(t) > 3 else None}
    return None


def current_leases():
    out = {}
    for line in read(LEASES).splitlines():
        p = line.split()                    # expiry mac ip hostname clientid
        if len(p) >= 4:
            out[p[2]] = {"expires": int(p[0]) if p[0].isdigit() else None, "mac": p[1].lower(), "name": "" if p[3] == "*" else p[3]}
    return out


def arp_table():
    out = {}
    for line in read("/proc/net/arp").splitlines()[1:]:
        p = line.split()
        if len(p) >= 6 and p[2] == "0x2":
            out[p[0]] = {"mac": p[3].lower(), "dev": p[5]}
    return out


# ---------------------------------------------------------------- prober: which devices are active
class Prober:
    """Every SWEEP_S seconds: ping each known address once, wait for the kernel's ARP re-validation, then record who answered."""

    def __init__(self):
        self.lock = threading.Lock()
        self.result = {}            # ip -> bool
        self.at = None
        self.stop = threading.Event()

    def targets(self, lan_prefix):
        t = set()
        for s in static_leases():
            t.add(s["ip"])
        t.update(current_leases())
        t.update(ip for ip, v in arp_table().items() if v["dev"] == LAN)
        t = {ip for ip in t if ip_in(ip, lan_prefix)}
        for name, ip in host_records().items():            # building/VAX hosts that dnsmasq knows by name
            if ip_in(ip, "192.168.123.0/24") or ip_in(ip, "192.168.20.0/24"):
                t.add(ip)
        return sorted(t)

    def sweep(self):
        lan = next((a for a in address_map().get(LAN, [])), None)
        prefix = "%s/%d" % (lan["ip"], lan["prefix"]) if lan else "192.168.10.0/24"
        ips = self.targets(prefix)
        ping = which("ping")
        procs = {}
        if ping:
            for ip in ips:
                try:
                    procs[ip] = subprocess.Popen([ping, "-n", "-c", "1", "-W", "1", ip], stdout=subprocess.DEVNULL,
                                                 stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, env=ENV)
                except OSError:
                    pass
        ok = {}
        for ip, p in procs.items():
            try:
                ok[ip] = p.wait(timeout=4) == 0
            except subprocess.TimeoutExpired:
                p.kill()
                ok[ip] = False
        self.stop.wait(SETTLE_S)                           # ICMP may be blocked by the device's firewall: the ARP state still tells
        for n in ip_json("neigh", "show"):
            if "REACHABLE" in (n.get("state") or []) and n.get("dst") in ips:
                ok[n["dst"]] = True
        with self.lock:
            self.result = {ip: ok.get(ip, False) for ip in ips}
            self.at = time.time()

    def loop(self):
        while not self.stop.is_set():
            try:
                self.sweep()
            except Exception as e:                         # a bad sweep must never kill the thread
                print("router sweep error:", e, flush=True)
            self.stop.wait(SWEEP_S)

    def get(self):
        with self.lock:
            return dict(self.result), self.at


PROBER = Prober()


def start_prober():
    threading.Thread(target=PROBER.loop, daemon=True).start()


def ip_in(ip, net):
    try:
        return ipaddress.ip_address(ip) in ipaddress.ip_network(net, strict=False)
    except ValueError:
        return False


# ---------------------------------------------------------------- collect
def uptime():
    try:
        s = float(read("/proc/uptime").split()[0])
    except (ValueError, IndexError):
        s = None
    try:
        la = [float(x) for x in read("/proc/loadavg").split()[:3]]
    except ValueError:
        la = None
    osr = {}
    for line in read("/etc/os-release").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            osr[k] = v.strip('"')
    return {"up_s": s, "load": la, "os": osr.get("PRETTY_NAME"), "kernel": os.uname().release}


UPNP_DIR = os.environ.get("TRAFFIC_UPNP_DIR", "/var/lib/miniupnpd")


def upnp():
    """UPnP for the LAN (setup-router.sh upnp): is it on, and the live mappings with whether the upstream router forwards them."""
    if not os.path.exists(os.path.join(SETUP_DIR, "upnp")):
        return {"enabled": False, "summary": "not provided", "mappings": []}
    rc, out = run([which("systemctl") or "systemctl", "is-active", "miniupnpd"])
    running = out.strip() == "active"
    forwarded = set(read(os.path.join(UPNP_DIR, "cmrouter.mapped")).splitlines())
    now = time.time()
    maps = []
    for line in read(os.path.join(UPNP_DIR, "upnp.leases")).splitlines():
        f = line.split(":", 5)
        if len(f) < 5 or f[0] not in ("TCP", "UDP") or not f[1].isdigit() or not f[4].isdigit():
            continue
        exp = int(f[4])
        if exp and exp <= now:
            continue
        maps.append({"port": int(f[1]), "proto": f[0].lower(), "client": f[2] + ":" + f[3], "what": f[5] if len(f) > 5 else "",
                     "left_s": int(exp - now) if exp else None, "upstream": (f[0].lower() + " " + f[1]) in forwarded})
    maps.sort(key=lambda m: (m["port"], m["proto"]))
    summary = ("on, for the home network (UPnP and NAT-PMP); opened ports are passed on to the upstream router" if running
               else "set up, but the service is not running")
    return {"enabled": True, "running": running, "summary": summary, "mappings": maps}


def firewall():
    ports = []
    for line in read(os.path.join(SETUP_DIR, "lan0-tcp-ports")).splitlines():
        m = re.match(r"^\s*(\d{1,5})\s*(?:#\s*(.*))?$", line)
        if m:
            ports.append({"port": int(m.group(1)), "what": (m.group(2) or "").strip()})
    ssh_from = read(os.path.join(SETUP_DIR, "vr180-ssh-from")).split()
    fwd = read("/proc/sys/net/ipv4/ip_forward") == "1"
    up = upnp()
    return {"source": "configuration files (the live ruleset needs root to read)", "ip_forward": fwd,
            "inbound_from_wan": "blocked (default drop; only replies to our own traffic come in)",
            "upnp": up["summary"], "upnp_mappings": up["mappings"], "upnp_running": up["enabled"] and up["running"], "nat": "masquerade out of wan0 and vr180",
            "lan_open_ports": ports, "vr180_ssh_from": ssh_from, "vax_zone": os.path.exists(os.path.join(SETUP_DIR, "vax-zone")),
            "building_to_lan": "blocked except replies and the ssh/ping hosts listed above"}


def collect(usage=None, rates=None):
    """usage: {ip: {"down": bytes, "up": bytes}} for today on the WAN; rates: {iface: (down_Bps, up_Bps)} (both from server.py)."""
    usage, rates = usage or {}, rates or {}
    addrs = address_map()
    routes = default_routes()
    wan = link_info(WAN, addrs)
    if wan["present"]:
        wr = [r for r in routes if r["dev"] == WAN]
        wan["gateway"] = wr[0]["gw"] if wr else None
        wan["default_route"] = bool(wr)
        wan["dns"] = link_dns(WAN)
        a4 = wan["addrs"][0] if wan["addrs"] else None
        wan["method"] = ("DHCP" if a4 and a4["dynamic"] else "static") if a4 else None
        wan["behind_nat"] = bool(a4 and private(a4["ip"]))
        wan["rate"] = rates.get(WAN)
    lan = link_info(LAN, addrs)
    lan["dhcp"] = dhcp_range()
    lan["rate"] = rates.get(LAN)
    vr = link_info(VR, addrs)
    if vr["present"]:
        vr["wifi"] = wifi_info(VR)
        vr["default_route"] = any(r["dev"] == VR for r in routes)
        vr["rate"] = rates.get(VR)
    vax = link_info(VAX, addrs)

    active, checked = PROBER.get()
    leases, arp, static = current_leases(), arp_table(), static_leases()
    prefix = "192.168.10.0/24"
    if lan.get("addrs"):
        prefix = "%s/%d" % (lan["addrs"][0]["ip"], lan["addrs"][0]["prefix"])
    rows = {}
    for s in static:
        rows[s["ip"]] = {"ip": s["ip"], "name": s["name"], "mac": s["mac"], "kind": "reserved", "expires": None}
    for ip, l in leases.items():
        r = rows.setdefault(ip, {"ip": ip, "name": "", "mac": l["mac"], "kind": "dynamic", "expires": None})
        r["name"] = r["name"] or l["name"]
        r["mac"] = r["mac"] or l["mac"]
        r["expires"] = l["expires"]
    for ip, a in arp.items():
        if a["dev"] == LAN and ip_in(ip, prefix):
            r = rows.setdefault(ip, {"ip": ip, "name": "", "mac": a["mac"], "kind": "not in DHCP", "expires": None})
            r["mac"] = r["mac"] or a["mac"]
    for ip, r in rows.items():
        r["active"] = active.get(ip) if checked else None
        r["today"] = usage.get(ip)
    devices = sorted(rows.values(), key=lambda r: tuple(int(x) for x in r["ip"].split(".")))

    others = []                                             # hosts on the building network and the VAX, by dnsmasq name
    for name, ip in sorted(host_records().items()):
        if ip_in(ip, "192.168.123.0/24") or ip_in(ip, "192.168.20.0/24"):
            others.append({"name": name, "ip": ip, "net": "vr180" if ip.startswith("192.168.123.") else "vax",
                           "active": active.get(ip) if checked else None})
    return {"now": time.time(), "host": socket.gethostname().split(".")[0], "system": uptime(),
            "wan": wan, "lan": lan, "vr180": vr, "vax": vax, "devices": devices, "others": others,
            "devices_checked_at": checked, "sweep_s": SWEEP_S, "firewall": firewall()}


# ---------------------------------------------------------------- diagnostics
_DIAG = threading.Lock()
_last = [0.0]
TOOLS = ("ping", "traceroute", "lookup", "internet")


def valid_target(t):
    t = (t or "").strip()
    if not t or len(t) > 253 or t.startswith("-"):
        return None
    try:
        return str(ipaddress.ip_address(t))
    except ValueError:
        pass
    return t if HOST.match(t) else None


def diag(tool, target):
    """-> (http_status, {"ok": bool, "output": str}). One run at a time, at least 2 s apart; the target never reaches a shell."""
    if tool not in TOOLS:
        return 400, {"ok": False, "output": "unknown tool"}
    tgt = valid_target(target) if tool != "internet" else "-"
    if tgt is None:
        return 400, {"ok": False, "output": "that is not a valid host name or IP address"}
    if not _DIAG.acquire(blocking=False):
        return 429, {"ok": False, "output": "another test is still running"}
    try:
        wait = 2 - (time.time() - _last[0])
        if wait > 0:
            return 429, {"ok": False, "output": "please wait a moment between tests"}
        t0 = time.time()
        if tool == "ping":
            exe = which("ping")
            rc, out = run([exe, "-n", "-c", "4", "-W", "2", tgt], 20) if exe else (None, "ping is not installed")
        elif tool == "traceroute":
            exe = which("traceroute")
            rc, out = run([exe, "-n", "-m", "15", "-q", "1", "-w", "1", tgt], 40) if exe else (None, "traceroute is not installed")
        elif tool == "lookup":
            # ask the router's own DNS server (dnsmasq on the LAN address): that is the answer LAN devices get
            lan = next(iter(address_map().get(LAN, [])), None)
            dig = which("dig")
            if lan and dig:
                res = []
                for rr in ("A", "AAAA"):
                    _, o = run([dig, "+short", "+time=2", "+tries=1", "@" + lan["ip"], tgt, rr], 8)
                    res += [x for x in o.split() if x]
                rc = 0 if res else 1
                out = ("%s, as answered by this router's DNS (%s):\n  %s" % (tgt, lan["ip"], "\n  ".join(res))) if res \
                    else "%s: no answer from this router's DNS (%s)" % (tgt, lan["ip"])
            else:
                try:
                    infos = socket.getaddrinfo(tgt, None, proto=socket.IPPROTO_TCP)
                    rc, out = 0, "%s resolves to:\n  %s\n(this router's own resolver; dig is not installed)" % (tgt, "\n  ".join(sorted({i[4][0] for i in infos})))
                except OSError as e:
                    rc, out = 1, "%s: %s" % (tgt, e.strerror or e)
        else:
            lines, good = [], True
            try:
                t1 = time.time()
                ip = socket.getaddrinfo("example.com", 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
                lines.append("DNS   example.com -> %s (%.0f ms)" % (ip, (time.time() - t1) * 1000))
            except OSError as e:
                lines.append("DNS   FAILED: %s" % (e.strerror or e)); good = False
            for host in ("1.1.1.1", "9.9.9.9"):
                try:
                    t1 = time.time()
                    socket.create_connection((host, 443), 4).close()
                    lines.append("TCP   %s:443 connected (%.0f ms)" % (host, (time.time() - t1) * 1000))
                except OSError as e:
                    lines.append("TCP   %s:443 FAILED: %s" % (host, e.strerror or e)); good = False
            lines.append("(ICMP ping to the internet is often blocked upstream, so this uses DNS and TCP.)")
            rc, out = (0 if good else 1), "\n".join(lines)
        _last[0] = time.time()
        return 200, {"ok": rc == 0, "output": (out or "no output").strip()[-6000:]}
    finally:
        _DIAG.release()
