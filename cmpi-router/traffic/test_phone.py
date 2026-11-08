#!/usr/bin/env python3
"""Offline tests for the phone counters (server.py phone_tick + phone.py) against a fake adb server. Run: python3 test_phone.py
No phone, no root, no network: a throw-away config, state directory and a fake adb server on a random local port."""
import json
import os
import socketserver
import sys
import tempfile
import threading

TMP = tempfile.mkdtemp(prefix="phonetest-")
FAKE = {"net": {}, "upstream": ["rmnet_data3"], "serial": "FAKE123", "model": "FakePhone"}


class H(socketserver.StreamRequestHandler):
    def read_service(self):
        n = self.rfile.read(4)
        if len(n) < 4:
            return None
        return self.rfile.read(int(n, 16)).decode()

    def reply(self, s):
        self.wfile.write(s.encode())
        self.wfile.flush()

    def handle(self):
        svc = self.read_service()
        if svc is None:
            return
        if svc in ("host:transport-any", "host:transport:" + FAKE["serial"]):
            self.reply("OKAY")
        else:
            m = "device '%s' not found" % svc.split(":")[-1]
            self.reply("FAIL%04x%s" % (len(m), m))
            return
        svc = self.read_service()
        self.reply("OKAY")
        if svc == "exec:cat /proc/net/dev":
            lines = ["Inter-|   Receive", " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed"]
            for name, (rx, tx) in FAKE["net"].items():
                lines.append("%6s: %d 1 0 0 0 0 0 0 %d 1 0 0 0 0 0 0" % (name, rx, tx))
            self.reply("\r\n".join(lines) + "\r\n")
        elif svc == "exec:dumpsys tethering":
            self.reply("noise\n    Current upstream interface(s): [%s]\nmore noise\n" % ", ".join(FAKE["upstream"]))
        elif svc == "exec:getprop ro.product.model":
            self.reply(FAKE["model"] + "\n")
        elif svc == "exec:getprop ro.build.version.release":
            self.reply("12\n")


class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


srv = S(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
port = srv.server_address[1]

cfgfile = os.path.join(TMP, "config.json")
json.dump({"phone": {"enabled": True, "serial": "FAKE123", "adb_socket": "tcp:127.0.0.1:%d" % port, "poll_s": 10, "upstream_poll_s": 0}}, open(cfgfile, "w"))
os.environ.update(TRAFFIC_STATE=os.path.join(TMP, "state"), TRAFFIC_CONFIG=cfgfile, TRAFFIC_ACCT=os.path.join(TMP, "none.json"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402

fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    fails += not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "   got %r want %r" % (got, want)))


def acc(iface):
    """Everything counted for a card so far: the database (after a flush) = what the graphs would show."""
    server.flush_pending()
    with server.DBLOCK:
        rx, tx = server.DB.execute("SELECT COALESCE(SUM(rx),0), COALESCE(SUM(tx),0) FROM minute WHERE iface=?", (iface,)).fetchone()
    return rx, tx


def base():
    return {"rmnet_ipa0": (1000, 500), "rmnet_data3": (100, 50), "rmnet_data1": (9000, 900), "wlan1": (0, 200), "wlan0": (77, 77), "lo": (5, 5)}


check("cards added from config", [i for i in server.IFACES if i.startswith("phone-")], ["phone-cell", "phone-tether", "phone-hotspot"])
check("local interfaces untouched", server.LOCAL_IFACES, ["wan0", "lan0", "vr180"])

state = {"prev": None, "first": True, "mono": None, "up_at": -1e9, "upstream": None}
FAKE["net"] = base()
server.phone_tick(state)
check("first tick = baseline (nothing counted)", [acc(i) for i in ("phone-cell", "phone-tether", "phone-hotspot")], [(0, 0)] * 3)
check("cards show present", [server.PRESENT[i] for i in ("phone-cell", "phone-tether", "phone-hotspot")], [True] * 3)
check("model read", (server.PHONE["connected"], server.PHONE["model"], server.PHONE["android"]), (True, "FakePhone", "12"))

FAKE["net"].update(rmnet_ipa0=(6000, 1200), rmnet_data3=(3100, 450), wlan1=(0, 2700), rmnet_data1=(9100, 950))
server.phone_tick(state)
check("cellular delta", acc("phone-cell"), (5000, 700))
check("tether delta (@upstream = rmnet_data3)", acc("phone-tether"), (3000, 400))
check("hotspot delta (down is the interface tx)", acc("phone-hotspot"), (0, 2500))

FAKE["net"].update(rmnet_ipa0=(800, 100))                      # the phone rebooted: counters restart from ~0
server.phone_tick(state)
check("counter went backwards = count from zero", acc("phone-cell"), (5000 + 800, 700 + 100))

FAKE["upstream"] = ["rmnet_data1"]                             # tethering moved to another upstream interface
FAKE["net"].update(rmnet_data1=(9600, 1000), rmnet_data3=(3200, 460))
server.phone_tick(state)
check("tether follows the new upstream (data1 +500/+50, data3 ignored)", acc("phone-tether"), (3000 + 500, 400 + 50))
check("status shows the upstream", server.PHONE["upstream"], ["rmnet_data1"])

# service restart: the last counters were saved, so bytes moved while we were down are still counted
server.flush_pending()
FAKE["net"].update(rmnet_data1=(10600, 1100), wlan1=(0, 3000), rmnet_ipa0=(1800, 300))
state2 = {"prev": None, "first": True, "mono": None, "up_at": -1e9, "upstream": None}
server.phone_tick(state2)
check("after a restart the gap bytes are counted (data1 +1000/+100)", acc("phone-tether"), (3500 + 1000, 450 + 100))
check("hotspot gap bytes (wlan1 tx +300)", acc("phone-hotspot")[1], 2500 + 300)

# a different phone (serial) starts a new baseline and does not mix with the old one's counters
server.PHONE_CFG["serial"] = None
FAKE["net"] = {"rmnet_ipa0": (50, 50), "rmnet_data3": (1, 1), "wlan1": (0, 1)}
before = acc("phone-cell")
state3 = {"prev": None, "first": True, "mono": None, "up_at": -1e9, "upstream": None}
server.phone_tick(state3)
check("unknown identity = baseline, nothing counted", acc("phone-cell"), before)

# interface appearing later (e.g. wlan1 only exists once the hotspot started): counted from zero
server.PHONE_CFG["serial"] = "FAKE123"
FAKE["net"].pop("wlan1", None)
state4 = {"prev": {}, "first": False, "mono": None, "up_at": -1e9, "upstream": ["rmnet_data3"]}
FAKE["net"] = {"rmnet_ipa0": (0, 0), "rmnet_data3": (0, 0), "wlan1": (0, 4000)}
h0 = acc("phone-hotspot")[1]
server.phone_tick(state4)
check("interface that appears after start counts in full", acc("phone-hotspot")[1], h0 + 4000)

# errors
try:
    FAKE["serial"] = "OTHER"
    server.phone_tick({"prev": None, "first": True, "mono": None, "up_at": -1e9, "upstream": None})
    check("wrong serial raises", "no error", "AdbError")
except Exception as e:
    check("wrong serial raises a clear error", "not found" in str(e), True)
FAKE["serial"] = "FAKE123"
srv.shutdown(); srv.server_close()
try:
    server.phone_tick({"prev": None, "first": True, "mono": None, "up_at": -1e9, "upstream": None})
    check("server down raises", "no error", "OSError")
except OSError as e:
    check("adb server down raises OSError", type(e).__name__, "ConnectionRefusedError")

st = server.api_config()["phone"]
check("api_config exposes phone status", sorted(st)[:3], ["android", "connected", "enabled"])
print("\n%s" % ("ALL PASSED" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
