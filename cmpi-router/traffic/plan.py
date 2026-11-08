#!/usr/bin/env python3
"""Set up the data plan for the traffic graphs (called by `sudo ./bin/setup-router.sh plan ...`).

Writes the plan keys into /etc/trafficgraph/config.json (the running service picks the change up within ~5 s).

  plan --gb 199.76 --day 11 --used 14.87 --email you@example.com
  plan --show

  --gb N        monthly high-speed data allowance (the pool your carrier shows, e.g. 199.76)
  --day D       day of the month the cycle starts (a cycle of Sep 11 - Oct 10 means 11)
  --used N      the carrier's used figure RIGHT NOW. The part cpbee did not see (other phones sharing the plan,
                usage before recording began) is stored as an offset for this cycle only; run it again any time to
                re-sync with the carrier's number
  --email A     alert address (repeat or comma-separate); --email none removes it
  --webhook U   POST alerts to this URL (ntfy-compatible); --webhook none removes it
  --source S    interface (default, conservative) or devices (IP-level, closest to the carrier's count)
  --thresholds  comma-separated percentages, default 50,75,90,100

  Sending alert email through a relay (instead of a local mail system):
  --smtp-host H           relay host, e.g. mail.u-l.ca
  --smtp-security S       starttls (port 587) or ssl (port 465); none = plain, only acceptable to localhost
  --smtp-port N           only if the relay uses a non-standard port
  --smtp-user U           the relay login, usually the full mailbox address; "none" removes it
  --smtp-password-prompt  asks for the mailbox password WITHOUT echoing and stores it in /etc/trafficgraph/smtp-password
                          (root:trafficgraph, mode 0640). It is never put on the command line or in config.json
  --alert-from A          sender address (defaults to the login; most relays insist it is that mailbox)
  --smtp-cafile F         extra CA certificate to trust (normally not needed)
  Test it:  sudo ./bin/setup-router.sh plan --test-alert    (sends a test message through the saved settings)
"""
import argparse
import getpass
import grp
import calendar
import json
import os
import re
import sqlite3
import sys
import time

CONFIG = os.environ.get("TRAFFIC_CONFIG", "/etc/trafficgraph/config.json")
STATE = os.environ.get("TRAFFIC_STATE", "/var/lib/trafficgraph")
DEFAULT_PASSFILE = "/etc/trafficgraph/smtp-password"
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")
EMAIL = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


def write_password(path, password):
    """Store the relay password where only root and the service group can read it. Never printed, never in config.json."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)      # starts private, loosened only after the content is in
    with os.fdopen(fd, "w") as f:
        f.write(password + "\n")
    note = ""
    try:
        os.chown(tmp, -1, grp.getgrnam("trafficgraph").gr_gid)
    except KeyError:
        note = "group 'trafficgraph' does not exist yet (run `setup-router.sh graphs` first): the service cannot read the file until it does"
    except PermissionError:
        note = "not root: could not give the file to group 'trafficgraph', so the service cannot read it until you re-run this as root"
    os.chmod(tmp, 0o640)
    os.replace(tmp, path)
    return note


def ask_password(user):
    if sys.stdin.isatty():
        p1 = getpass.getpass("Password for %s (not shown): " % user)
        if getpass.getpass("Again: ") != p1:
            sys.exit("the two entries differ; nothing was changed")
    else:
        p1 = sys.stdin.readline().rstrip("\r\n")                          # non-interactive use (pipe)
    if not p1:
        sys.exit("empty password; nothing was changed")
    return p1


def cycle_start(now, bday, back=0):
    """Same rule as server.py: epoch of the start of the billing cycle containing `now`."""
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


def recorded_bytes(cfg, c0):
    """Bytes the monitor itself counted in the current cycle, from the configured source."""
    db = os.path.join(STATE, "traffic.db")
    if not os.path.exists(db):
        return 0
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    try:
        if cfg.get("cap_source") == "devices":
            row = con.execute("SELECT COALESCE(SUM(rx+tx),0) FROM day WHERE iface LIKE 'h/%' AND ts>=?", (c0,)).fetchone()
        else:
            row = con.execute("SELECT COALESCE(SUM(rx+tx),0) FROM day WHERE iface=? AND ts>=?",
                              (cfg.get("cap_iface", "wan0"), c0)).fetchone()
        return row[0]
    finally:
        con.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gb", type=float)
    ap.add_argument("--day", type=int)
    ap.add_argument("--used", type=float)
    ap.add_argument("--email", action="append")
    ap.add_argument("--webhook")
    ap.add_argument("--source", choices=["interface", "devices"])
    ap.add_argument("--thresholds")
    ap.add_argument("--smtp-host")
    ap.add_argument("--smtp-port", type=int)
    ap.add_argument("--smtp-security", choices=["none", "starttls", "ssl"])
    ap.add_argument("--smtp-user")
    ap.add_argument("--smtp-password-prompt", action="store_true")
    ap.add_argument("--smtp-cafile")
    ap.add_argument("--alert-from")
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()

    try:
        with open(CONFIG) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        cfg = {}
    except ValueError as e:
        sys.exit("%s is not valid JSON (%s); fix it first" % (CONFIG, e))

    changed = False
    if a.gb is not None:
        if a.gb <= 0:
            sys.exit("--gb must be positive")
        cfg["monthly_cap_gb"] = a.gb
        changed = True
    if a.day is not None:
        if not 1 <= a.day <= 28:
            sys.exit("--day must be 1-28 (cycles starting on the 29th-31st are not supported)")
        cfg["billing_day"] = a.day
        changed = True
    if a.source:
        cfg["cap_source"] = a.source
        changed = True
    if a.email:
        addrs = [x.strip() for v in a.email for x in v.split(",") if x.strip()]
        cfg["alert_email"] = None if addrs == ["none"] else addrs
        changed = True
    if a.webhook:
        cfg["alert_webhook"] = None if a.webhook == "none" else a.webhook
        changed = True
    if a.thresholds:
        try:
            cfg["alert_thresholds"] = sorted({int(x) for x in a.thresholds.split(",") if x.strip()})
        except ValueError:
            sys.exit("--thresholds must be comma-separated whole numbers")
        changed = True

    # ---- relay for alert email
    new_pw = None
    if a.smtp_host:
        cfg["smtp_host"] = a.smtp_host
        changed = True
    if a.smtp_security:
        cfg["smtp_security"] = a.smtp_security
        if a.smtp_port is None:
            cfg["smtp_port"] = None                                       # fall back to the standard port for that security
        changed = True
    if a.smtp_port is not None:
        if not 1 <= a.smtp_port <= 65535:
            sys.exit("--smtp-port must be 1-65535")
        cfg["smtp_port"] = a.smtp_port
        changed = True
    if a.smtp_user:
        cfg["smtp_user"] = None if a.smtp_user == "none" else a.smtp_user
        changed = True
    if a.alert_from:
        if not re.match(EMAIL, a.alert_from):
            sys.exit("--alert-from must be an email address")
        cfg["alert_from"] = a.alert_from
        changed = True
    if a.smtp_cafile:
        if a.smtp_cafile != "none" and not os.path.isfile(a.smtp_cafile):
            sys.exit("--smtp-cafile: %s not found" % a.smtp_cafile)
        cfg["smtp_cafile"] = None if a.smtp_cafile == "none" else a.smtp_cafile
        changed = True
    if a.smtp_password_prompt:
        if not cfg.get("smtp_user"):
            sys.exit("set the login first: --smtp-user <mailbox address>")
        cfg.setdefault("smtp_password_file", DEFAULT_PASSFILE)
        new_pw = ask_password(cfg["smtp_user"])
        changed = True
    if cfg.get("smtp_user") and str(cfg.get("smtp_security") or "none") == "none" and (cfg.get("smtp_host") or "localhost") not in LOCAL_HOSTS:
        sys.exit("a login for %s must use TLS: add --smtp-security starttls (or ssl). Nothing was changed." % cfg.get("smtp_host"))
    if a.used is not None:
        bday = int(cfg.get("billing_day") or 1)
        c0 = cycle_start(time.time(), bday)
        rec = recorded_bytes(cfg, c0)
        off = a.used * 1e9 - rec
        if off < 0:
            print("note: the monitor has already counted %.2f GB, more than the carrier's %.2f GB; no offset needed "
                  "(the monitor reads high because of link framing)." % (rec / 1e9, a.used))
            off = 0
        cfg["cycle_offset_gb"] = round(off / 1e9, 3)
        cfg["cycle_offset_cycle"] = c0
        cfg["cycle_offset_set_at"] = int(time.time())
        changed = True
        print("recorded by the monitor this cycle: %.2f GB; carrier says %.2f GB; offset stored: %.2f GB "
              "(cycle starting %s)" % (rec / 1e9, a.used, off / 1e9, time.strftime("%b %d", time.localtime(c0))))

    if new_pw is not None:
        pf = cfg.get("smtp_password_file") or DEFAULT_PASSFILE
        warn = write_password(pf, new_pw)
        print("stored the relay password in %s (not shown here, not in config.json)" % pf)
        if warn:
            print("warning:", warn)
    if changed:
        tmp = CONFIG + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cfg, f, indent=2, sort_keys=True)
            f.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, CONFIG)
        print("wrote", CONFIG)
    if a.show or not changed:
        keys = ["monthly_cap_gb", "billing_day", "cap_iface", "cap_source", "alert_thresholds", "pace_alert", "alert_email",
                "alert_from", "alert_webhook", "smtp_host", "smtp_security", "smtp_port", "smtp_user", "smtp_cafile",
                "cycle_offset_gb", "cycle_offset_cycle"]
        print("current plan settings in %s:" % CONFIG)
        for k in keys:
            print("  %-20s %s" % (k, cfg.get(k)))
        pf = cfg.get("smtp_password_file") or DEFAULT_PASSFILE
        if cfg.get("smtp_user"):
            try:
                st = os.stat(pf)
                print("  %-20s %s (present, mode %o; contents not shown)" % ("smtp password", pf, st.st_mode & 0o777))
            except OSError:
                print("  %-20s %s (MISSING: run with --smtp-password-prompt)" % ("smtp password", pf))
    if changed:
        print("The page and alerts use the new values within a few seconds (no restart needed).")


if __name__ == "__main__":
    main()
