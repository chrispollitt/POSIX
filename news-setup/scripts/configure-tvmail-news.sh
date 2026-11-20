#!/usr/bin/env bash
#
# configure-tvmail-news.sh
#
# The client half of configure-inn.sh: point tvmail at a news server on the LAN, so Usenet
# appears in its Services pane.  Run it as yourself on the client machine - no root.  The script:
#
#   1. asks the server (NNTP, plain, as tvmail does): the greeting, and how many groups LIST ACTIVE
#      gives - so a wrong host or a closed firewall is found here, not in tvmail;
#   2. writes into ~/.config/tvmail/tvmail.conf (or $TVMAIL_CONF): [news] host, port, window and
#      subscribed, and `news` in [services] order (after the services already there; `mail` first
#      if the key is new).  Added or replaced, every other section and comment is kept, and the
#      file is backed up first (BAK/ beside it, the 3 newest kept).
#
# Re-runnable.  No password is involved (the LAN's server lets the LAN read, and post to lan.*).
#
# Usage:
#   ./configure-tvmail-news.sh [options]
#
# Options:
#   --host HOST        the news server (default: cpbee)
#   --port N           (default: 119)
#   --window N         how many of a group's newest articles tvmail lists (default: 500)
#   --subscribed LIST  the groups to start with, comma-separated (default: lan.misc)
#   --no-check         skip the connection check (offline)
#   -h | --help        show this header
#
set -euo pipefail
set -E
trap 'rc=$?; printf "ERROR: configure-tvmail-news.sh stopped at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../../mail-setup/lib/common.sh"

HOST=cpbee; PORT=119; WINDOW=500; SUBSCRIBED=lan.misc; CHECK=1
while [ $# -gt 0 ]; do
  case "$1" in
    --host)       HOST="${2:?}"; shift 2 ;;
    --port)       PORT="${2:?}"; shift 2 ;;
    --window)     WINDOW="${2:?}"; shift 2 ;;
    --subscribed) SUBSCRIBED="${2:?}"; shift 2 ;;
    --no-check)   CHECK=0; shift ;;
    -h|--help)    usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$HOST" in *[!A-Za-z0-9._-]*|'') die "--host: '$HOST' is not a host name" ;; esac
case "$PORT$WINDOW" in *[!0-9]*|'') die "--port and --window are numbers" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port out of range"
[ "$WINDOW" -ge 1 ] || die "--window must be at least 1"
case "$SUBSCRIBED" in *[!A-Za-z0-9.,_+-]*) die "--subscribed: a comma list of group names" ;; esac

PY=$(find_python) || die "python3 (3.6 or later) is needed"
CONF="${TVMAIL_CONF:-$HOME/.config/tvmail/tvmail.conf}"

step "tvmail's Usenet service: $HOST:$PORT"

# 1. the server ---------------------------------------------------------------------
if [ "$CHECK" = 1 ]; then
  out=$("$PY" - "$HOST" "$PORT" <<'PYEOF'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
try:
    s = socket.create_connection((host, port), 10)
except OSError as e:
    print("cannot connect: %s" % e); sys.exit(1)
f = s.makefile("rb")
greet = f.readline().decode("utf-8", "replace").strip()
if not greet[:3] in ("200", "201"):
    print("unexpected greeting: %s" % greet); sys.exit(1)
s.sendall(b"MODE READER\r\n"); f.readline()
s.sendall(b"LIST ACTIVE\r\n")
head = f.readline().decode("utf-8", "replace").strip()
n = 0
if head[:3] == "215":
    while f.readline().rstrip(b"\r\n") != b".":
        n += 1
s.sendall(b"QUIT\r\n")
print("%s - %s - %d groups" % (greet[:60], "posting allowed" if greet[:3] == "200" else "read only", n))
PYEOF
  ) || die "the news server at $HOST:$PORT: $out (is TCP $PORT open for this machine? see configure-inn.sh --firewall-plan on the server)"
  log "server      : $out"
else
  log "server      : not checked (--no-check)"
fi

# 2. tvmail.conf --------------------------------------------------------------------
mkdir -p "$(dirname "$CONF")"
if [ -e "$CONF" ]; then
  d=$(dirname "$CONF")/BAK; b=$(basename "$CONF")
  mkdir -p "$d"
  cp -p "$CONF" "$d/$b.bak-$(date +%Y%m%d-%H%M%S)"
  ls -1t "$d/$b".bak-* 2>/dev/null | tail -n +4 | while IFS= read -r old; do rm -f "$old"; done
fi
"$PY" - "$CONF" "$HOST" "$PORT" "$WINDOW" "$SUBSCRIBED" <<'PYEOF'
# Text edit, not configparser.write(): that would drop every comment.
import os, re, sys
path, host, port, window, subscribed = sys.argv[1:6]
text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
lines = text.split("\n")
if lines and lines[-1] == "":
    lines.pop()


def section_range(name):
    """(start, end) of the lines of [name]: the header line to just before the next header, or None."""
    start = None
    for i, l in enumerate(lines):
        m = re.match(r"^\s*\[([^\]]+)\]\s*$", l)
        if m:
            if start is not None:
                return start, i
            if m.group(1).strip().lower() == name:
                start = i
    return (start, len(lines)) if start is not None else None


def set_key(section, key, value):
    r = section_range(section)
    if r is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend(["[%s]" % section, "%s = %s" % (key, value)])
        return
    s, e = r
    for i in range(s + 1, e):
        if re.match(r"^\s*%s\s*[=:]" % re.escape(key), lines[i], re.I):
            lines[i] = "%s = %s" % (key, value)
            return
    at = e
    while at > s + 1 and not lines[at - 1].strip():
        at -= 1                                   # before the blank lines that end the section
    lines.insert(at, "%s = %s" % (key, value))


def get_key(section, key):
    r = section_range(section)
    if r:
        for i in range(r[0] + 1, r[1]):
            m = re.match(r"^\s*%s\s*[=:]\s*(.*?)\s*$" % re.escape(key), lines[i], re.I)
            if m:
                return m.group(1)
    return None


order = get_key("services", "order")
names = [n for n in re.split(r"[,\s]+", order or "mail") if n]
if "news" not in [n.lower() for n in names]:
    names.append("news")
set_key("services", "order", ", ".join(names))
set_key("news", "host", host)
set_key("news", "port", port)
set_key("news", "window", window)
set_key("news", "subscribed", subscribed.replace(",", ", "))
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
os.replace(tmp, path)
PYEOF
log "tvmail.conf : [services] order and [news] set in $CONF"

cat <<EOF

== tvmail ==
  Start tvmail: Usenet is in the Services pane (View > Services pane if it is hidden).
  Message > Usenet > All groups... lists what the server has; Subscribe adds a group.
EOF
