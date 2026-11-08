#!/usr/bin/env python3
"""cpbee traffic graphs: samples /proc/net/dev, keeps rollups in SQLite, serves a small web UI + JSON API.

Stdlib only (no pip, no internet needed). Config via environment:
  TRAFFIC_BIND    address to listen on          (default 127.0.0.1; the installer sets the lan0 address)
  TRAFFIC_PORT    port                          (default 8080)
  TRAFFIC_STATE   directory for traffic.db      (default ./state)
  TRAFFIC_CONFIG  JSON config (interfaces, monthly cap)   (default ./config.json next to this file, optional)
  TRAFFIC_ACCT    per-device byte counters exported by trafficgraph-acct (default /run/trafficgraph/acct.json)
  TRAFFIC_LEASES  dnsmasq lease file, for device names  (default /var/lib/misc/dnsmasq.leases)
  TRAFFIC_DNSMASQ_GLOB  dnsmasq config files, for static dhcp-host names (default /etc/dnsmasq.d/*.conf)

Per-device accounting: nftables (table `ip acct`) counts WAN bytes per LAN client IP; those counters are stored here as
pseudo-interfaces named "h/<ip>" (and "h/router" for cpbee itself) in the same minute/hour/day tables, with rx = bytes the
device downloaded and tx = bytes it uploaded.
"""
import calendar
import collections
import glob
import json
import os
import re
import signal
import smtplib
import socket
import ssl
import sqlite3
import sys
import threading
import time
import urllib.request
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import router                                            # router status page + diagnostics (read-only, see router.py)
import phone as phonemod                                 # Android phone counters over adb (FINAL: the phone is the WAN; see phone.py)
BIND = os.environ.get("TRAFFIC_BIND", "127.0.0.1")
PORT = int(os.environ.get("TRAFFIC_PORT", "8080"))
STATE = os.environ.get("TRAFFIC_STATE", os.path.join(HERE, "state"))
CONFIG = os.environ.get("TRAFFIC_CONFIG", os.path.join(HERE, "config.json"))
ACCT = os.environ.get("TRAFFIC_ACCT", "/run/trafficgraph/acct.json")
LEASES = os.environ.get("TRAFFIC_LEASES", "/var/lib/misc/dnsmasq.leases")
DNSMASQ_GLOB = os.environ.get("TRAFFIC_DNSMASQ_GLOB", "/etc/dnsmasq.d/*.conf")

SAMPLE_S = 2          # /proc/net/dev poll interval
HOST_S = int(os.environ.get("TRAFFIC_HOST_S", "5"))    # per-device counter poll interval (matches the exporter)
ACCT_STALE_S = 60     # ignore an export older than this (exporter stopped)
LIVE_POINTS = 300     # 10 minutes of live history in memory
FLUSH_S = int(os.environ.get("TRAFFIC_FLUSH_S", "10"))   # write accumulated deltas to SQLite this often (also flushed on SIGTERM)
KEEP_MINUTE = 8 * 86400
KEEP_HOUR = 800 * 86400

# "down"/"up" say which kernel counter is the user's download: on the WAN, received bytes are downloads; on the LAN
# side the router *transmits* to clients, so a client's download is the router's tx.
DEFAULT_CONFIG = {
    "interfaces": [
        {"id": "wan0", "label": "WAN", "sub": "wan0 · internet", "down": "rx", "up": "tx",
         "metered": True, "note": "Metered: this is the only link that counts against the mobile data plan."},
        {"id": "lan0", "label": "LAN", "sub": "lan0 · home network", "down": "tx", "up": "rx",
         "note": "Not metered. Internet traffic from LAN devices is counted on the WAN."},
        {"id": "vr180", "label": "VR180", "sub": "vr180 · building Wi-Fi", "down": "rx", "up": "tx",
         "note": "Not metered. Building network only: VR180 has no direct internet access."},
    ],
    "monthly_cap_gb": None,   # e.g. 50 -> shows a usage meter for cap_iface
    "cap_iface": "wan0",
    "billing_day": 1,         # day of month the data plan resets
    "devices": {},            # optional names by address, e.g. {"192.168.10.77": "cmdesktop"} (beats DHCP names)
    # data plan (all of these except `interfaces` are re-read from the config file within ~5 s, no restart needed)
    "cap_source": "interface",     # "interface" = wan0 counters (a few % high: includes link framing, conservative);
                                   # "devices" = IP-level per-device counts (closest to what the carrier counts)
    "alert_thresholds": [50, 75, 90, 100],   # percent of the cap; each fires once per billing cycle
    "pace_alert": True,            # one alert per cycle when the projection says the cap will be exceeded
    "alert_email": None,           # address or list of addresses (delivered through smtp_host)
    "alert_from": None,            # sender; with a relay login this defaults to smtp_user (relays usually require it)
    "smtp_host": "localhost",      # a local MTA, or a relay such as mail.example.com
    "smtp_port": None,             # default by security: 25 none, 587 starttls, 465 ssl
    "smtp_security": "none",       # "none" | "starttls" | "ssl"; a password is never sent without TLS (except to localhost)
    "smtp_user": None,             # relay login; the password is NOT stored here but in smtp_password_file
    "smtp_password_file": "/etc/trafficgraph/smtp-password",   # one line, root:trafficgraph 0640 (written by `plan --smtp-password-prompt`)
    "smtp_cafile": None,           # extra CA bundle to trust (private CA); normally unnecessary
    "smtp_tls_verify": True,       # certificate + hostname checks; turning this off is NOT recommended
    "alert_webhook": None,         # POSTed as plain text, ntfy-compatible (e.g. "https://ntfy.sh/<secret-topic>")
    "cycle_offset_gb": None,       # usage before recording started, counted only for the cycle named below
    "cycle_offset_cycle": None,    # epoch of that cycle's start (set by `setup-router.sh plan --used`)
    # An Android phone as the WAN (FINAL): its byte counters are read over adb (see phone.py and bin/setup-phone.sh) and shown as
    # extra cards. Needs a service restart. For the plan meter set "cap_iface": "phone-cell" (what the carrier counts).
    "phone": {
        "enabled": False,
        "serial": None,                                          # adb serial; None = the only attached device
        "adb_socket": "localfilesystem:/run/adbphone/server.sock",   # or tcp:127.0.0.1:5037
        "poll_s": 10,                                            # counter reads
        "upstream_poll_s": 60,                                   # how often to ask which interface the tethering uses
    },
}

# Cards added when phone.enabled. "phone_ifaces" = interface names on the PHONE whose counters are summed; "@upstream" = whatever
# interface the phone's tethering currently uses as its upstream (it can change). Directions follow the same rule as local interfaces.
PHONE_IFACES = [
    {"id": "phone-cell", "label": "Phone: cellular", "sub": "rmnet_ipa0 · the whole mobile link", "phone_ifaces": ["rmnet_ipa0"],
     "down": "rx", "up": "tx", "metered": True,
     "note": "Read from the phone over adb. Everything on the carrier link: the phone's own use plus all tethered traffic. The closest figure to what the carrier counts."},
    {"id": "phone-tether", "label": "Phone: tethered", "sub": "tethering upstream · USB link + Wi-Fi hotspot", "phone_ifaces": ["@upstream"],
     "down": "rx", "up": "tx", "metered": True,
     "note": "Traffic that went through the phone's tethering: cpbee's USB link and any hotspot clients together."},
    {"id": "phone-hotspot", "label": "Phone: Wi-Fi hotspot", "sub": "wlan1 · devices on the phone's own Wi-Fi", "phone_ifaces": ["wlan1"],
     "down": "tx", "up": "rx", "metered": True,
     "note": "Devices on the phone's hotspot (they bypass cpbee). This driver reports no uploads here: see 'tethered' for upload."},
]


def load_config():
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    try:
        with open(CONFIG) as f:
            cfg.update(json.load(f))
    except FileNotFoundError:
        pass
    cfg["phone"] = {**DEFAULT_CONFIG["phone"], **(cfg.get("phone") or {})}
    if cfg["phone"].get("enabled"):
        have = {i["id"] for i in cfg["interfaces"]}
        cfg["interfaces"] = cfg["interfaces"] + [json.loads(json.dumps(i)) for i in PHONE_IFACES if i["id"] not in have]
    ids = [i["id"] for i in cfg["interfaces"]]
    if len(set(ids)) != len(ids):
        sys.exit("duplicate interface id in config")
    return cfg


CFG = load_config()
IFACES = [i["id"] for i in CFG["interfaces"]]
PHONE_CFG = CFG["phone"]
PHONE_SPECS = {i["id"]: list(i["phone_ifaces"]) for i in CFG["interfaces"] if i.get("phone_ifaces")}   # card id -> names on the phone
LOCAL_IFACES = [i for i in IFACES if i not in PHONE_SPECS]       # read from this machine's /proc/net/dev
DIR = {i["id"]: (i.get("down", "rx"), i.get("up", "tx")) for i in CFG["interfaces"]}

os.makedirs(STATE, exist_ok=True)
DB = sqlite3.connect(os.path.join(STATE, "traffic.db"), check_same_thread=False)
DB.execute("PRAGMA journal_mode=WAL")
DB.execute("PRAGMA synchronous=NORMAL")
for _t in ("minute", "hour", "day"):
    DB.execute(f"CREATE TABLE IF NOT EXISTS {_t}(ts INTEGER NOT NULL, iface TEXT NOT NULL, "
               "rx INTEGER NOT NULL, tx INTEGER NOT NULL, PRIMARY KEY(ts, iface)) WITHOUT ROWID")
DB.execute("CREATE TABLE IF NOT EXISTS hostprev(key TEXT PRIMARY KEY, bytes INTEGER NOT NULL) WITHOUT ROWID")
DB.execute("CREATE TABLE IF NOT EXISTS alerts(cycle INTEGER NOT NULL, key TEXT NOT NULL, ts INTEGER NOT NULL, "
           "delivered INTEGER NOT NULL, tries INTEGER NOT NULL, last_try INTEGER NOT NULL, subject TEXT, body TEXT, "
           "PRIMARY KEY(cycle, key)) WITHOUT ROWID")
DB.commit()
DBLOCK = threading.Lock()

_CFG_LIVE = {"mtime": None, "t": 0.0, "cfg": CFG}


def cfg_live():
    """CFG, but the data-plan keys follow edits to the config file (checked at most every 5 s). Interfaces stay as at start."""
    now = time.time()
    if now - _CFG_LIVE["t"] < 5:
        return _CFG_LIVE["cfg"]
    _CFG_LIVE["t"] = now
    try:
        m = os.stat(CONFIG).st_mtime
    except OSError:
        m = None
    if m != _CFG_LIVE["mtime"]:
        _CFG_LIVE["mtime"] = m
        try:
            c = load_config()
            c["interfaces"] = CFG["interfaces"]
            _CFG_LIVE["cfg"] = c
        except (Exception, SystemExit) as e:             # a half-edited file must not break the running service
            print("config reload failed, keeping the previous one:", e, file=sys.stderr, flush=True)
    return _CFG_LIVE["cfg"]

LIVE = {i: collections.deque(maxlen=LIVE_POINTS) for i in IFACES}   # (ts, rx_Bps, tx_Bps)
PRESENT = {i: False for i in IFACES}
LIVELOCK = threading.Lock()
ACC = {}                 # {(minute_ts, iface): [rx, tx]} not yet written to SQLite
PREVS = {}               # {"up|ip": bytes} last-seen nftables counters, written together with ACC
ACCLOCK = threading.Lock()


def local_midnight(ts):
    t = time.localtime(ts)
    return int(time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1)))


def cycle_start(now, bday, back=0):
    """Epoch of the start of the billing cycle containing `now` (or `back` cycles earlier)."""
    t = time.localtime(now)
    y, m = t.tm_year, t.tm_mon
    if t.tm_mday < bday:
        m -= 1
    m -= back
    while m < 1:
        m += 12
        y -= 1
    while m > 12:
        m -= 12
        y += 1
    d = min(bday, calendar.monthrange(y, m)[1])
    return int(time.mktime((y, m, d, 0, 0, 0, 0, 0, -1)))


def read_proc():
    out = {}
    with open("/proc/net/dev") as f:
        for line in f.readlines()[2:]:
            name, _, rest = line.partition(":")
            name = name.strip()
            if name in LOCAL_IFACES:
                p = rest.split()
                out[name] = (int(p[0]), int(p[8]))
    return out


def flush(acc, prevs):
    """acc: {(minute_ts, iface): [rx, tx]} -> upsert into minute/hour/day tables; prevs -> hostprev, one transaction."""
    if not acc and not prevs:
        return
    up = "INSERT INTO {t}(ts,iface,rx,tx) VALUES(?,?,?,?) ON CONFLICT(ts,iface) DO UPDATE SET rx=rx+excluded.rx, tx=tx+excluded.tx"
    with DBLOCK:
        try:
            for (mts, iface), (rx, tx) in acc.items():
                DB.execute(up.format(t="minute"), (mts, iface, rx, tx))
                DB.execute(up.format(t="hour"), (mts // 3600 * 3600, iface, rx, tx))
                DB.execute(up.format(t="day"), (local_midnight(mts), iface, rx, tx))
            for k, v in prevs.items():
                DB.execute("INSERT OR REPLACE INTO hostprev(key, bytes) VALUES(?,?)", (k, v))
            DB.commit()
        except Exception:
            DB.rollback()
            raise


def flush_pending():
    global ACC, PREVS
    with ACCLOCK:
        acc, ACC = ACC, {}
        prevs, PREVS = PREVS, {}
    try:
        flush(acc, prevs)
    except Exception:
        with ACCLOCK:                                    # keep the counts for the next attempt
            for k, (rx, tx) in acc.items():
                a = ACC.setdefault(k, [0, 0])
                a[0] += rx
                a[1] += tx
            for k, v in prevs.items():
                PREVS.setdefault(k, v)
        raise


def prune(now):
    with DBLOCK:
        DB.execute("DELETE FROM minute WHERE ts < ?", (now - KEEP_MINUTE,))
        DB.execute("DELETE FROM hour WHERE ts < ?", (now - KEEP_HOUR,))
        DB.commit()


SAMPLER = {"prev": {}, "first": True, "prev_mono": None, "last_flush": time.time(), "last_prune": time.time()}
SAMPLELOCK = threading.Lock()


def sample():
    """Read the kernel counters once, add the deltas to the accumulator and the live ring."""
    with SAMPLELOCK:
        st = SAMPLER
        prev = st["prev"]
        now = time.time()
        mono = time.monotonic()
        cur = read_proc()
        dt = (mono - st["prev_mono"]) if st["prev_mono"] else None
        for iface in LOCAL_IFACES:
            present = iface in cur
            with LIVELOCK:
                PRESENT[iface] = present
            if not present:
                prev.pop(iface, None)
                continue
            crx, ctx = cur[iface]
            if iface in prev:
                prx, ptx = prev[iface]
                # a counter that went backwards means the interface was recreated (replug/rename): count from 0
                drx = crx - prx if crx >= prx else crx
                dtx = ctx - ptx if ctx >= ptx else ctx
            elif st["first"]:
                drx = dtx = 0                           # baseline: do not count what happened before we started
            else:
                drx, dtx = crx, ctx                     # interface appeared after start (e.g. USB NIC plugged in)
            prev[iface] = (crx, ctx)
            key = (int(now) // 60 * 60, iface)
            with ACCLOCK:
                a = ACC.setdefault(key, [0, 0])
                a[0] += drx
                a[1] += dtx
            if dt and dt > 0:
                with LIVELOCK:
                    LIVE[iface].append((now, drx / dt, dtx / dt))
        st["first"] = False
        st["prev_mono"] = mono
        if now - st["last_flush"] >= FLUSH_S:
            flush_pending()
            st["last_flush"] = now
        if now - st["last_prune"] >= 3600:
            prune(now)
            st["last_prune"] = now


def collector():
    nxt = time.monotonic()
    while True:
        try:
            sample()
        except Exception as e:                           # keep sampling no matter what
            print("collector error:", e, file=sys.stderr, flush=True)
        nxt += SAMPLE_S
        time.sleep(max(0.0, nxt - time.monotonic()))
        if nxt < time.monotonic() - 10:                  # clock jump / suspend: resync
            nxt = time.monotonic()


# ---------------------------------------------------------------- phone counters (FINAL: an Android phone is the WAN)
# Deltas are computed per PHYSICAL phone interface (rmnet_data3, rmnet_ipa0, wlan1, ...) and then summed into the cards. The last
# counter seen is saved (table hostprev, keys "phone|<serial>|<iface>|rx/tx") so a restart of this service does not lose the bytes
# moved meanwhile; a counter that went backwards means the phone rebooted (count from zero), same rule as the local interfaces.
PHONE = {"enabled": bool(PHONE_CFG.get("enabled")), "connected": False, "error": None, "model": None, "android": None,
         "last_ok": None, "upstream": None, "serial": PHONE_CFG.get("serial"), "poll_s": PHONE_CFG.get("poll_s", 10)}
PHONELOCK = threading.Lock()
RMNET_DATA = re.compile(r"^rmnet_data\d+$")


def phone_status():
    with PHONELOCK:
        return dict(PHONE)


def phone_load_prev(ident):
    out = {}
    with DBLOCK:
        rows = DB.execute("SELECT key, bytes FROM hostprev WHERE key LIKE ?", (f"phone|{ident}|%",)).fetchall()
    for k, v in rows:
        parts = k.split("|")
        out.setdefault(parts[-2], {})[parts[-1]] = v
    return {n: (d["rx"], d["tx"]) for n, d in out.items() if "rx" in d and "tx" in d}


def phone_tick(state):
    spec, serial = PHONE_CFG["adb_socket"], PHONE_CFG.get("serial") or ""
    ident = serial or "any"
    if state["prev"] is None:
        state["prev"] = phone_load_prev(ident)
    cur = phonemod.counters(spec, serial)
    now, mono = time.time(), time.monotonic()
    if mono - state["up_at"] >= PHONE_CFG.get("upstream_poll_s", 60):
        state["up_at"] = mono
        try:
            up = phonemod.upstream(spec, serial)
            if up is not None:
                state["upstream"] = up
        except (OSError, phonemod.AdbError, ValueError):
            pass                                         # keep the last known upstream
    wanted = {n for names in PHONE_SPECS.values() for n in names if n != "@upstream"}
    if any("@upstream" in names for names in PHONE_SPECS.values()):
        wanted |= {n for n in cur if RMNET_DATA.match(n)}
    deltas, persist = {}, {}
    for n in wanted & set(cur):
        crx, ctx = cur[n]
        p = state["prev"].get(n)
        if p is not None:
            drx = crx - p[0] if crx >= p[0] else crx
            dtx = ctx - p[1] if ctx >= p[1] else ctx
        elif state["first"]:
            drx = dtx = 0                                # baseline: do not count what happened before we started
        else:
            drx, dtx = crx, ctx                          # interface appeared after start (e.g. USB tether switched on)
        state["prev"][n] = (crx, ctx)
        deltas[n] = (drx, dtx)
        persist[f"phone|{ident}|{n}|rx"] = crx
        persist[f"phone|{ident}|{n}|tx"] = ctx
    dt = (mono - state["mono"]) if state["mono"] else None
    gap = dt is not None and dt > 3 * PHONE_CFG.get("poll_s", 10)       # phone was away: bytes still counted, but no rate point
    for iface, names in PHONE_SPECS.items():
        rx = tx = 0
        for nm in names:
            for real in (state["upstream"] or []) if nm == "@upstream" else [nm]:
                d = deltas.get(real)
                if d:
                    rx += d[0]
                    tx += d[1]
        with LIVELOCK:
            PRESENT[iface] = True
        with ACCLOCK:
            a = ACC.setdefault((int(now) // 60 * 60, iface), [0, 0])
            a[0] += rx
            a[1] += tx
        if dt and dt > 0 and not gap:
            with LIVELOCK:
                LIVE[iface].append((now, rx / dt, tx / dt))
    with ACCLOCK:
        PREVS.update(persist)
    state["mono"], state["first"] = mono, False
    with PHONELOCK:
        was = PHONE["connected"]
        PHONE.update(connected=True, error=None, last_ok=now, upstream=state["upstream"])
    if not was or not PHONE["model"]:
        try:
            ident_info = phonemod.identity(spec, serial)
            with PHONELOCK:
                PHONE.update(ident_info)
        except (OSError, phonemod.AdbError, ValueError):
            pass
        if not was:
            print("phone connected: %s (android %s)" % (PHONE["model"], PHONE["android"]), file=sys.stderr, flush=True)


def phoneloop():
    state = {"prev": None, "first": True, "mono": None, "up_at": -1e9, "upstream": None}
    while True:
        try:
            phone_tick(state)
        except Exception as e:                           # no phone / unauthorised / adb server down: show it, keep trying
            msg = str(e) or type(e).__name__
            with PHONELOCK:
                was = PHONE["connected"] or PHONE["error"] is None
                PHONE.update(connected=False, error=msg)
            for iface in PHONE_SPECS:
                with LIVELOCK:
                    PRESENT[iface] = False
            if was:
                print("phone not reachable:", msg, file=sys.stderr, flush=True)
        time.sleep(PHONE_CFG.get("poll_s", 10))


# ---------------------------------------------------------------- per-device accounting
IPV4 = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
HOSTPREV = {}            # "up|ip" / "down|ip" -> last nftables byte counter we turned into a delta


def load_hostprev():
    with DBLOCK:
        for k, v in DB.execute("SELECT key, bytes FROM hostprev"):
            HOSTPREV[k] = v


def read_acct():
    with open(ACCT) as f:
        d = json.load(f)
    if time.time() - float(d.get("t", 0)) > ACCT_STALE_S:
        return None
    return d


def hostsample():
    """Turn the counters exported by trafficgraph-acct into per-device byte deltas (rx = download, tx = upload)."""
    try:
        d = read_acct()
    except (OSError, ValueError):
        return                                           # exporter not running (yet): nothing to count
    if not d:
        return
    mts = int(time.time()) // 60 * 60
    counters = {}
    for direction in ("up", "down"):
        for ip, b in (d.get(direction) or {}).items():
            if IPV4.match(ip):
                counters[(direction, ip)] = int(b)
    r = d.get("router") or {}
    counters[("up", "router")] = int(r.get("up", 0))
    counters[("down", "router")] = int(r.get("down", 0))
    with ACCLOCK:
        for (direction, ip), b in counters.items():
            key = f"{direction}|{ip}"
            prev = HOSTPREV.get(key)
            # a new element, or counters reset by a firewall reload (value went backwards): count from zero
            delta = b if prev is None or b < prev else b - prev
            HOSTPREV[key] = b
            PREVS[key] = b
            if delta:
                a = ACC.setdefault((mts, "h/" + ip), [0, 0])
                a[0 if direction == "down" else 1] += delta


def hostloop():
    try:
        load_hostprev()
    except Exception as e:
        print("hostprev load error:", e, file=sys.stderr, flush=True)
    while True:
        try:
            hostsample()
        except Exception as e:
            print("hostsample error:", e, file=sys.stderr, flush=True)
        time.sleep(HOST_S)


_NAMES = {"t": 0.0, "m": {}}


def device_names():
    """ip -> name. Priority: config "devices" > static dhcp-host lines > current DHCP leases."""
    now = time.time()
    if now - _NAMES["t"] < 30:
        return _NAMES["m"]
    m = {}
    try:
        with open(LEASES) as f:
            for line in f:
                p = line.split()                         # expiry mac ip hostname clientid
                if len(p) >= 4 and IPV4.match(p[2]) and p[3] != "*":
                    m[p[2]] = p[3]
    except OSError:
        pass
    for fn in sorted(glob.glob(DNSMASQ_GLOB)):
        try:
            with open(fn) as f:
                for line in f:
                    line = line.strip()
                    if not line.startswith("dhcp-host="):
                        continue
                    toks = line[len("dhcp-host="):].split(",")
                    ip = next((t for t in toks if IPV4.match(t)), None)
                    name = next((t for t in toks if t and not IPV4.match(t) and ":" not in t
                                 and not re.match(r"^(\d+[smhd]?|infinite)$", t)
                                 and not t.startswith(("set:", "id:", "tag:"))), None)
                    if ip and name:
                        m[ip] = name
        except OSError:
            pass
    for k, v in (cfg_live().get("devices") or {}).items():
        m[str(k)] = str(v)
    _NAMES["t"], _NAMES["m"] = now, m
    return m


def host_label(key):
    if key == "router":
        return socket.gethostname().split(".")[0] + " (this router)"
    return device_names().get(key, "")


def host_sums(table, a, b=None):
    q = f"SELECT iface, SUM(rx), SUM(tx) FROM {table} WHERE iface LIKE 'h/%' AND ts>=?"
    args = [a]
    if b is not None:
        q += " AND ts<?"
        args.append(b)
    q += " GROUP BY iface"
    with DBLOCK:
        return {r[0][2:]: (r[1], r[2]) for r in DB.execute(q, args)}


def wan_sum(table, a, b=None):
    wan = next((i for i in IFACES if i == cfg_live().get("cap_iface", "wan0")), IFACES[0])
    q = f"SELECT COALESCE(SUM(rx),0), COALESCE(SUM(tx),0) FROM {table} WHERE iface=? AND ts>=?"
    args = [wan, a]
    if b is not None:
        q += " AND ts<?"
        args.append(b)
    with DBLOCK:
        rx, tx = DB.execute(q, args).fetchone()
    return (rx, tx) if DIR[wan][0] == "rx" else (tx, rx)       # (down, up)


# ---------------------------------------------------------------- API
RANGES = {   # name: (table, group seconds, span seconds)
    "1h": ("minute", 60, 3600),
    "6h": ("minute", 300, 6 * 3600),
    "24h": ("minute", 300, 86400),
    "7d": ("hour", 3600, 7 * 86400),
    "30d": ("hour", 3600, 30 * 86400),
    "90d": ("day", 86400, 90 * 86400),
    "1y": ("day", 86400, 365 * 86400),
}


def api_config():
    c = cfg_live()
    return {"interfaces": CFG["interfaces"], "monthly_cap_gb": c.get("monthly_cap_gb"),
            "cap_iface": c.get("cap_iface", "wan0"), "billing_day": c.get("billing_day", 1),
            "host": socket.gethostname(), "now": time.time(), "phone": phone_status()}


def api_live():
    out = {"interval": SAMPLE_S, "now": time.time(), "ifaces": {}}
    with LIVELOCK:
        for iface in IFACES:
            d_is_rx = DIR[iface][0] == "rx"
            pts = list(LIVE[iface])
            out["ifaces"][iface] = {
                "present": PRESENT[iface],
                "t": [round(p[0], 1) for p in pts],
                "down": [round(p[1] if d_is_rx else p[2]) for p in pts],
                "up": [round(p[2] if d_is_rx else p[1]) for p in pts],
            }
    return out


def api_series(rng):
    if rng not in RANGES:
        return None
    table, group, span = RANGES[rng]
    now = time.time()
    start = int((now - span) // group * group)
    out = {"range": rng, "step": group, "now": now, "ifaces": {}}
    with DBLOCK:
        for iface in IFACES:
            if table == "day":
                q = "SELECT ts, rx, tx FROM day WHERE iface=? AND ts>=? ORDER BY ts"
            else:
                q = (f"SELECT ts/{group}*{group} AS b, SUM(rx), SUM(tx) FROM {table} "
                     "WHERE iface=? AND ts>=? GROUP BY b ORDER BY b")
            rows = {r[0]: (r[1], r[2]) for r in DB.execute(q, (iface, start))}
            ts, down, up, down_b, up_b = [], [], [], [], []
            d_is_rx = DIR[iface][0] == "rx"
            if table == "day":
                # local-midnight buckets are not a fixed 86400 apart across DST: walk by calendar day
                t = local_midnight(start)
                if t < start:
                    t = local_midnight(start + 86400 + 3600)
                seq = []
                while t <= now:
                    seq.append(t)
                    t = local_midnight(t + 86400 + 3600)
            else:
                seq = list(range(start, int(now) + 1, group))
            for b in seq:
                r = rows.get(b)
                ts.append(b)
                if r is None:
                    down.append(None); up.append(None); down_b.append(None); up_b.append(None)
                    continue
                dn, upv = (r[0], r[1]) if d_is_rx else (r[1], r[0])
                width = max(1.0, min(group, now - b))      # the newest bucket is still filling
                down.append(round(dn / width)); up.append(round(upv / width))
                down_b.append(dn); up_b.append(upv)
            out["ifaces"][iface] = {"t": ts, "down": down, "up": up, "down_b": down_b, "up_b": up_b}
    return out


def sum_days(iface, a, b=None):
    q = "SELECT COALESCE(SUM(rx),0), COALESCE(SUM(tx),0) FROM day WHERE iface=? AND ts>=?"
    args = [iface, a]
    if b is not None:
        q += " AND ts<?"
        args.append(b)
    with DBLOCK:
        rx, tx = DB.execute(q, args).fetchone()
    return rx, tx


def api_totals():
    now = time.time()
    bday = int(cfg_live().get("billing_day", 1) or 1)
    today = local_midnight(now)
    yesterday = local_midnight(today - 3600)
    c0 = cycle_start(now, bday)
    p0 = cycle_start(now, bday, back=1)
    with DBLOCK:
        first = DB.execute("SELECT MIN(ts) FROM day").fetchone()[0]
    out = {"now": now, "since": first, "cycle_start": c0, "prev_cycle_start": p0, "ifaces": {}}
    for iface in IFACES:
        d_is_rx = DIR[iface][0] == "rx"

        def du(r):
            return {"down": r[0] if d_is_rx else r[1], "up": r[1] if d_is_rx else r[0]}
        out["ifaces"][iface] = {
            "today": du(sum_days(iface, today)),
            "yesterday": du(sum_days(iface, yesterday, today)),
            "cycle": du(sum_days(iface, c0)),
            "prev_cycle": du(sum_days(iface, p0, c0)),
        }
    periods = {"today": (today, None), "yesterday": (yesterday, today), "cycle": (c0, None), "prev_cycle": (p0, c0)}
    hosts = {}
    for pname, (a, b) in periods.items():
        for key, (rx, tx) in host_sums("day", a, b).items():
            h = hosts.setdefault(key, {"key": key, "name": host_label(key)})
            h[pname] = {"down": rx, "up": tx}
    for h in hosts.values():
        for pname in periods:
            h.setdefault(pname, {"down": 0, "up": 0})
    out["hosts"] = sorted(hosts.values(), key=lambda h: -(h["cycle"]["down"] + h["cycle"]["up"]))
    return out


def api_hosts(rng):
    """Per-device WAN bytes over the same ranges as the charts ('live' uses the last hour)."""
    if rng == "live":
        rng = "1h"
    if rng not in RANGES:
        return None
    table, _, span = RANGES[rng]
    now = time.time()
    start = int(now - span)
    wan_down, wan_up = wan_sum(table, start)
    with DBLOCK:
        since = DB.execute("SELECT MIN(ts) FROM day WHERE iface LIKE 'h/%'").fetchone()[0]
    rows = [{"key": k, "router": k == "router", "name": host_label(k), "down": rx, "up": tx}
            for k, (rx, tx) in host_sums(table, start).items()]
    return {"range": rng, "start": start, "now": now, "since": since,
            "wan": {"down": wan_down, "up": wan_up}, "hosts": rows}


def api_router():
    """Router status: router.collect() plus today's WAN bytes per device and the current rate of each link."""
    usage = {k: {"down": rx, "up": tx} for k, (rx, tx) in host_sums("day", local_midnight(time.time())).items()}
    rates = {}
    with LIVELOCK:
        for iface in IFACES:
            if LIVE[iface]:
                _, rx, tx = LIVE[iface][-1]
                rates[iface] = (round(rx), round(tx)) if DIR[iface][0] == "rx" else (round(tx), round(rx))   # (down, up)
    d = router.collect(usage, rates)
    d["phone"] = phone_status()
    return d


# ---------------------------------------------------------------- data plan: pacing + alerts
def cycle_used(cfg, a, b=None):
    """(down, up) bytes of the metered link in [a, b), from the configured source."""
    if cfg.get("cap_source") == "devices":
        rows = host_sums("day", a, b)
        return sum(r[0] for r in rows.values()), sum(r[1] for r in rows.values())
    return wan_sum("day", a, b)


def plan_since(cfg):
    """First day we have data for the metered link, or None."""
    with DBLOCK:
        if cfg.get("cap_source") == "devices":
            return DB.execute("SELECT MIN(ts) FROM day WHERE iface LIKE 'h/%'").fetchone()[0]
        wan = cfg.get("cap_iface", "wan0")
        return DB.execute("SELECT MIN(ts) FROM day WHERE iface=?", (wan,)).fetchone()[0]


def api_plan(now=None):
    cfg = cfg_live()
    cap = cfg.get("monthly_cap_gb")
    if not cap:
        return {"enabled": False}
    now = time.time() if now is None else now
    bday = int(cfg.get("billing_day", 1) or 1)
    c0, c1 = cycle_start(now, bday), cycle_start(now, bday, back=-1)
    total, elapsed = c1 - c0, now - c0
    down, up = cycle_used(cfg, c0)
    offset = 0.0
    if cfg.get("cycle_offset_gb") and int(cfg.get("cycle_offset_cycle") or 0) == c0:
        offset = float(cfg["cycle_offset_gb"]) * 1e9
    used = down + up + offset
    tdown, tup = cycle_used(cfg, local_midnight(now))
    cap_b = float(cap) * 1e9
    since = plan_since(cfg)
    # recording may have started mid-cycle: project from the window we actually have (unless an offset covers the gap)
    start = c0 if (offset or since is None or since <= c0) else since
    window = now - start
    projected = used / window * total if window >= 86400 and used > 0 else None
    pace = cap_b * elapsed / total
    remaining = max(0.0, cap_b - used)
    days_left = max((c1 - now) / 86400, 0.01)
    pct = used / cap_b * 100
    if pct >= 100:
        status = "over"
    elif pct >= 90:
        status = "crit"
    elif pct >= 75:
        status = "warn"
    elif projected is not None and projected > cap_b:
        status = "pace"
    elif used > pace:
        status = "ahead"
    else:
        status = "ok"
    with DBLOCK:
        alerts = [{"key": r[0], "ts": r[1], "delivered": bool(r[2])} for r in DB.execute(
            "SELECT key, ts, delivered FROM alerts WHERE cycle=? ORDER BY ts", (c0,))]
    return {"enabled": True, "cap_gb": float(cap), "cap_bytes": cap_b, "source": cfg.get("cap_source", "interface"),
            "iface": cfg.get("cap_iface", "wan0"), "now": now, "cycle_start": c0, "cycle_end": c1,
            "days_total": total / 86400, "days_elapsed": elapsed / 86400, "days_left": days_left,
            "used": used, "down": down, "up": up, "offset": offset, "offset_set_at": cfg.get("cycle_offset_set_at") if offset else None, "pct": pct,
            "today": tdown + tup, "pace_expected": pace, "ahead": used - pace, "projected": projected,
            "remaining": remaining, "per_day_left": remaining / days_left,
            "recording_since": since if (since and since > c0 and not offset) else None,
            "status": status, "thresholds": sorted(int(t) for t in (cfg.get("alert_thresholds") or [])),
            "alerts": alerts, "email": bool(cfg.get("alert_email")), "webhook": bool(cfg.get("alert_webhook"))}


def gb(b):
    return "%.1f GB" % (b / 1e9)


def alert_body(p, headline):
    top = sorted(host_sums("day", p["cycle_start"]).items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:3]
    names = ", ".join("%s %s" % (host_label(k) or k, gb(v[0] + v[1])) for k, v in top) or "no per-device data"
    d = lambda t: time.strftime("%b %d", time.localtime(t))
    lines = [headline, "",
             "Used %s of %.0f GB (%.0f%%) on %s (down %s, up %s), counted from %s." % (
                 gb(p["used"]), p["cap_gb"], p["pct"], p["iface"], gb(p["down"]), gb(p["up"]),
                 "interface counters" if p["source"] == "interface" else "per-device counts"),
             "Cycle %s to %s: day %.0f of %.0f. Expected by now at an even pace: %s." % (
                 d(p["cycle_start"]), d(p["cycle_end"] - 1), p["days_elapsed"] + 1, p["days_total"], gb(p["pace_expected"]))]
    if p["projected"] is not None:
        lines.append("Projected at cycle end: %s (%.0f%% of the cap)." % (gb(p["projected"]), p["projected"] / p["cap_bytes"] * 100))
    lines.append("Remaining: %s = %s per day for the %.0f days left." % (gb(p["remaining"]), gb(p["per_day_left"]), p["days_left"]))
    lines.append("Top devices this cycle: " + names)
    if p["recording_since"]:
        lines.append("Note: recording only began on %s; usage before that is not included." % d(p["recording_since"]))
    lines += ["", os.environ.get("TRAFFIC_URL") or "http://%s/" % socket.getfqdn()]
    return "\n".join(lines)


def smtp_send(msg, cfg):
    """Send through the configured server: a local MTA, or a relay with TLS and a login (password read from a root-only file)."""
    host = cfg.get("smtp_host") or "localhost"
    sec = str(cfg.get("smtp_security") or "none").lower()
    if sec not in ("none", "starttls", "ssl"):
        raise ValueError("smtp_security must be none, starttls or ssl (got %r)" % sec)
    port = int(cfg.get("smtp_port") or {"ssl": 465, "starttls": 587}.get(sec, 25))
    user = cfg.get("smtp_user")
    local = host in ("localhost", "127.0.0.1", "::1")
    if user and sec == "none" and not local:
        raise RuntimeError("refusing to send a password to %s without TLS (set smtp_security to starttls or ssl)" % host)
    ctx = None
    if sec in ("starttls", "ssl"):
        ctx = ssl.create_default_context(cafile=cfg.get("smtp_cafile") or None)
        if cfg.get("smtp_tls_verify") is False:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
    password = None
    if user:
        pf = cfg.get("smtp_password_file") or "/etc/trafficgraph/smtp-password"
        try:
            with open(pf) as f:
                password = f.readline().rstrip("\r\n")
        except OSError as e:
            raise RuntimeError("cannot read the SMTP password file %s (%s); create it with: sudo ./bin/setup-router.sh plan --smtp-password-prompt" % (pf, e.strerror))
        if not password:
            raise RuntimeError("the SMTP password file %s is empty" % pf)
    where = "%s:%d (%s)" % (host, port, sec)
    try:
        smtp = smtplib.SMTP_SSL(host, port, timeout=15, context=ctx) if sec == "ssl" else smtplib.SMTP(host, port, timeout=15)
        with smtp as s:
            if sec == "starttls":
                s.ehlo()
                s.starttls(context=ctx)
                s.ehlo()
            if user:
                s.login(user, password)
            s.send_message(msg)
    except ssl.SSLCertVerificationError as e:
        raise RuntimeError("the certificate presented by %s is not valid for the name '%s' (%s). Use a host name that appears in the "
                           "certificate as smtp_host, or add its CA with smtp_cafile; do not turn verification off" % (where, host, e.verify_message))
    except smtplib.SMTPAuthenticationError as e:
        raise RuntimeError("%s refused the login for %s: %s" % (where, user, e.smtp_error.decode(errors="replace") if isinstance(e.smtp_error, bytes) else e.smtp_error))
    except smtplib.SMTPServerDisconnected as e:           # smtplib reports a read timeout as a disconnect
        if "timed out" in str(e):
            raise RuntimeError("timed out talking to %s. Mobile and other networks often block port 587 (and 2525); try the server's port 465 "
                               "with smtp_security ssl, or whatever alternative port it offers" % where)
        raise RuntimeError("%s closed the connection unexpectedly (%s)" % (where, e))
    except smtplib.SMTPException:
        raise                                             # other server replies already say what happened
    except (TimeoutError, socket.timeout):
        raise RuntimeError("timed out talking to %s. Mobile and other networks often block port 587 (and 2525); try the server's port 465 "
                           "with smtp_security ssl, or whatever alternative port it offers" % where)
    except OSError as e:
        raise RuntimeError("cannot reach %s: %s" % (where, e.strerror or e))


def notify(subject, body, cfg):
    """Journal always; email and/or webhook if configured. True if delivered (or if nothing but the journal is configured)."""
    print("ALERT:", subject, flush=True)
    ok, configured = False, False
    rcpt = cfg.get("alert_email")
    if rcpt:
        configured = True
        try:
            to = [rcpt] if isinstance(rcpt, str) else list(rcpt)
            user = cfg.get("smtp_user")
            sender = cfg.get("alert_from") or (user if user and "@" in user else "trafficgraph@" + socket.getfqdn())
            msg = EmailMessage()
            msg["Subject"], msg["To"], msg["From"] = subject, ", ".join(to), sender
            msg["Date"] = formatdate(localtime=True)
            msg["Message-ID"] = make_msgid(domain=sender.rsplit("@", 1)[-1] or None)
            msg.set_content(body)
            smtp_send(msg, cfg)
            ok = True
        except Exception as e:
            print("alert email failed:", e, file=sys.stderr, flush=True)
    hook = cfg.get("alert_webhook")
    if hook:
        configured = True
        try:
            req = urllib.request.Request(hook, data=body.encode(), method="POST",
                                         headers={"Title": subject.encode("ascii", "replace").decode(), "Content-Type": "text/plain; charset=utf-8"})
            with urllib.request.urlopen(req, timeout=15) as r:
                ok = ok or (200 <= r.status < 300)
        except Exception as e:
            print("alert webhook failed:", e, file=sys.stderr, flush=True)
    return ok if configured else True


def alert_check(now=None):
    """Record newly crossed thresholds (once per cycle) and the pace projection; deliver anything undelivered."""
    cfg = cfg_live()
    p = api_plan(now)
    if not p["enabled"]:
        return
    c0, ts = p["cycle_start"], int(time.time() if now is None else now)
    with DBLOCK:
        sent = {r[0] for r in DB.execute("SELECT key FROM alerts WHERE cycle=?", (c0,))}
    new = [t for t in p["thresholds"] if p["pct"] >= t and "t%d" % t not in sent]
    rows = []
    if new:
        top = max(new)
        for t in new:                                     # several crossed at once: only the highest is sent
            if t == top:
                head = ("Data plan at %d%% (limit %.0f GB)" % (t, p["cap_gb"])) if t < 100 else "Data plan cap reached (%.0f GB)" % p["cap_gb"]
                subj = "[%s] %s" % (socket.gethostname().split(".")[0], head)
                if len(new) > 1:
                    head += " (also passed " + ", ".join("%d%%" % x for x in new if x != top) + ")"
                rows.append(("t%d" % t, 0, subj, alert_body(p, head)))
            else:
                rows.append(("t%d" % t, 1, "(folded into the %d%% alert)" % top, ""))
    if (cfg.get("pace_alert", True) and "pace" not in sent and p["projected"] is not None
            and p["projected"] > p["cap_bytes"] and p["days_elapsed"] >= 3 and p["pct"] < 100):
        head = "On pace to exceed the data plan: %s projected vs %.0f GB" % (gb(p["projected"]), p["cap_gb"])
        rows.append(("pace", 0, "[%s] %s" % (socket.gethostname().split(".")[0], head), alert_body(p, head)))
    if rows:
        with DBLOCK:
            for key, delivered, subj, body in rows:
                DB.execute("INSERT OR IGNORE INTO alerts(cycle,key,ts,delivered,tries,last_try,subject,body) VALUES(?,?,?,?,0,0,?,?)",
                           (c0, key, ts, delivered, subj, body))
            DB.commit()
    with DBLOCK:
        todo = DB.execute("SELECT cycle, key, subject, body FROM alerts WHERE delivered=0 AND tries<5 AND last_try<?",
                          (ts - 600,)).fetchall()
    for cycle, key, subj, body in todo:
        ok = notify(subj, body, cfg)
        with DBLOCK:
            DB.execute("UPDATE alerts SET delivered=?, tries=tries+1, last_try=? WHERE cycle=? AND key=?",
                       (1 if ok else 0, ts, cycle, key))
            DB.commit()


def alertloop():
    time.sleep(20)                                        # let the collectors fill in first
    while True:
        try:
            alert_check()
        except Exception as e:
            print("alert check error:", e, file=sys.stderr, flush=True)
        time.sleep(60)


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "trafficgraph"

    def log_message(self, *a):
        pass

    def send_body(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, code=200):
        self.send_body(code, json.dumps(obj, separators=(",", ":")).encode(), "application/json")

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if u.path in ("/", "/index.html"):
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    self.send_body(200, f.read(), "text/html; charset=utf-8")
            elif u.path == "/api/config":
                self.send_json(api_config())
            elif u.path == "/api/live":
                self.send_json(api_live())
            elif u.path == "/api/series":
                r = api_series(q.get("range", ["24h"])[0])
                self.send_json(r if r else {"error": "bad range"}, 200 if r else 400)
            elif u.path == "/api/totals":
                self.send_json(api_totals())
            elif u.path == "/api/hosts":
                r = api_hosts(q.get("range", ["24h"])[0])
                self.send_json(r if r else {"error": "bad range"}, 200 if r else 400)
            elif u.path == "/api/plan":
                self.send_json(api_plan())
            elif u.path in ("/router", "/router.html"):
                with open(os.path.join(HERE, "router.html"), "rb") as f:
                    self.send_body(200, f.read(), "text/html; charset=utf-8")
            elif u.path == "/api/router":
                self.send_json(api_router())
            else:
                self.send_json({"error": "not found"}, 404)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            print("request error:", self.path, e, file=sys.stderr, flush=True)
            self.send_json({"error": "internal error"}, 500)

    def do_POST(self):
        """Only /api/diag. A browser page on another site cannot send the custom header without a CORS preflight, which is never granted."""
        u = urlparse(self.path)
        try:
            if u.path != "/api/diag":
                self.send_json({"error": "not found"}, 404)
                return
            if self.headers.get("X-Requested-With") != "cpbee-router":
                self.send_json({"error": "forbidden"}, 403)
                return
            n = int(self.headers.get("Content-Length") or 0)
            if n > 2048:
                self.send_json({"error": "too large"}, 413)
                return
            try:
                req = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                self.send_json({"error": "bad json"}, 400)
                return
            if not isinstance(req, dict):
                self.send_json({"error": "bad json"}, 400)
                return
            code, body = router.diag(str(req.get("tool", "")), str(req.get("target", "")))
            self.send_json(body, code)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            print("request error:", self.path, e, file=sys.stderr, flush=True)
            self.send_json({"error": "internal error"}, 500)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        # IP_FREEBIND: bind even if the LAN address is not up yet at boot
        try:
            self.socket.setsockopt(socket.SOL_IP, 15, 1)
        except OSError:
            pass
        super().server_bind()


def main():
    if "--test-alert" in sys.argv:                        # send a test through the configured channels and exit
        c = cfg_live()
        rcpt = c.get("alert_email")
        rcpt = ", ".join([rcpt] if isinstance(rcpt, str) else rcpt) if rcpt else "not configured"
        via = ("%s:%s (%s)" % (c.get("smtp_host") or "localhost", c.get("smtp_port") or "default", c.get("smtp_security") or "none")) if c.get("alert_email") else "-"
        ok = notify("[%s] test alert from the data plan monitor" % socket.gethostname().split(".")[0],
                    "This is a test. If you can read it, alerts reach you.\nsent to: %s\nvia:     %s\nwebhook: %s" % (
                        rcpt, via, "set" if c.get("alert_webhook") else "not configured"), c)
        print("delivered" if ok else "FAILED (see messages above)")
        sys.exit(0 if ok else 1)
    threading.Thread(target=collector, daemon=True).start()
    threading.Thread(target=hostloop, daemon=True).start()
    threading.Thread(target=alertloop, daemon=True).start()
    router.start_prober()
    if PHONE["enabled"]:
        threading.Thread(target=phoneloop, daemon=True).start()
    srv = Server((BIND, PORT), Handler)
    print(f"trafficgraph listening on {BIND}:{PORT}, state {STATE}, interfaces {IFACES}", flush=True)
    def term(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, term)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    try:
        sample()                                         # one last read so the final <2 s of traffic is counted
    except Exception:
        pass
    flush_pending()                                      # do not lose the last few seconds on restart/shutdown
    print("trafficgraph stopped, pending counts flushed", flush=True)


if __name__ == "__main__":
    main()
