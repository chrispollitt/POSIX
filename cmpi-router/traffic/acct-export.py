#!/usr/bin/env python3
"""trafficgraph-acct: tiny root-only helper for the traffic graphs.

Reads the per-device byte counters kept by nftables (table `ip acct`, see setup-router.sh) and writes them as a small
JSON file that the unprivileged web service can read. Only reading `nft` needs privilege; the web UI never gets it.

  {"t": <epoch>, "up": {"192.168.10.50": <bytes>, ...}, "down": {...}, "router": {"up": <bytes>, "down": <bytes>}}

Run with --once to export a single snapshot (for testing); otherwise loops every INTERVAL (5) seconds.
"""
import json
import os
import subprocess
import sys
import time

OUT = os.environ.get("ACCT_OUT", "/run/trafficgraph/acct.json")
NFT = os.environ.get("NFT", "/usr/sbin/nft")
INTERVAL = 5


def snapshot():
    r = subprocess.run([NFT, "-j", "list", "table", "ip", "acct"], capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "nft failed")
    out = {"t": time.time(), "up": {}, "down": {}, "router": {"up": 0, "down": 0}}
    for item in json.loads(r.stdout).get("nftables", []):
        s = item.get("set")
        if s and s.get("name") in ("up", "down"):
            for e in s.get("elem", []):
                el = e.get("elem", e)
                val, c = el.get("val"), el.get("counter") or {}
                if isinstance(val, str):
                    out[s["name"]][val] = int(c.get("bytes", 0))
        c = item.get("counter")
        if c and c.get("name") in ("router_up", "router_down"):
            out["router"][c["name"][len("router_"):]] = int(c.get("bytes", 0))
    return out


def write(d):
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, separators=(",", ":"))
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)                                  # atomic: readers never see a half-written file


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    once = "--once" in sys.argv
    while True:
        try:
            write(snapshot())
        except Exception as e:                            # keep going: a missing table just means no fresh export
            print("acct-export:", e, file=sys.stderr, flush=True)
            if once:
                sys.exit(1)
        if once:
            return
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
