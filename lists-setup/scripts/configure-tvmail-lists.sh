#!/usr/bin/env bash
#
# configure-tvmail-lists.sh
#
# The client half of configure-lists.sh: point tvmail at the LAN's mailing lists, so Lists appears in its Services
# pane.  Run it as yourself on the client machine - no root.  The script writes into ~/.config/tvmail/tvmail.conf
# (or $TVMAIL_CONF): [lists] address (and prefix, realname, wait when given) and `lists` in [services] order (before
# `news` if that is there, else after the services already there; `mail` first if the key is new).  Added or replaced,
# every other section and comment is kept, and the file is backed up first (BAK/ beside it, the 3 newest kept).
#
# tvmail reads list mail over IMAP, with the login of the Mail service, so it needs [service] mode = remote and the
# [imap] / [smtp] sections (tvmail's own setup writes them).  The script says so when the mode is local.  Nothing is
# mailed or contacted: the first thing to do is Message > Lists > Available lists... in tvmail.
#
# Re-runnable.
#
# Usage:
#   ./configure-tvmail-lists.sh --address listserv@HOST [options]
#
# Options:
#   --address ADDR     the list server's address (required, e.g. listserv@cpbee.cmnet)
#   --realname NAME    the "First Last" put in SUBSCRIBE (default: your login name)
#   --prefix NAME      the IMAP folder the lists are under (default Lists; set only when different)
#   --wait SECONDS     how long tvmail waits for the server's answer mail (default 20; set only when given)
#   -h | --help        show this header
#
set -euo pipefail
set -E
trap 'rc=$?; printf "ERROR: configure-tvmail-lists.sh stopped at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../../mail-setup/lib/common.sh"

ADDRESS=""; REALNAME=""; PREFIX=""; WAIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --address)  ADDRESS="${2:?}"; shift 2 ;;
    --realname) REALNAME="${2:?}"; shift 2 ;;
    --prefix)   PREFIX="${2:?}"; shift 2 ;;
    --wait)     WAIT="${2:?}"; shift 2 ;;
    -h|--help)  usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ADDRESS" ] || die "--address is required (the list server's address, e.g. listserv@cpbee.cmnet)"
case "$ADDRESS" in *[!A-Za-z0-9._@+-]*|*@*@*|@*|*@) die "--address: '$ADDRESS' is not a mail address" ;; esac
case "$ADDRESS" in *@*.*|*@*) ;; *) die "--address: '$ADDRESS' is not a mail address" ;; esac
case "$REALNAME" in *$'\n'*|*'='*) die "--realname: one line, no =" ;; esac
case "$PREFIX" in *[!A-Za-z0-9._-]*) die "--prefix: letters, digits . _ - only" ;; esac
case "$WAIT" in *[!0-9]*) die "--wait: seconds" ;; esac

PY=$(find_python) || die "python3 (3.6 or later) is needed"
CONF="${TVMAIL_CONF:-$HOME/.config/tvmail/tvmail.conf}"

step "tvmail's Lists service: $ADDRESS"

mkdir -p "$(dirname "$CONF")"
if [ -e "$CONF" ]; then
  d=$(dirname "$CONF")/BAK; b=$(basename "$CONF")
  mkdir -p "$d"
  cp -p "$CONF" "$d/$b.bak-$(date +%Y%m%d-%H%M%S)"
  ls -1t "$d/$b".bak-* 2>/dev/null | tail -n +4 | while IFS= read -r old; do rm -f "$old"; done
fi
"$PY" - "$CONF" "$ADDRESS" "$REALNAME" "$PREFIX" "$WAIT" <<'PYEOF'
# Text edit, not configparser.write(): that would drop every comment.
import os, re, sys
path, address, realname, prefix, wait = sys.argv[1:6]
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
if "lists" not in [n.lower() for n in names]:
    low = [n.lower() for n in names]
    names.insert(low.index("news"), "lists") if "news" in low else names.append("lists")
set_key("services", "order", ", ".join(names))
set_key("lists", "address", address)
if realname:
    set_key("lists", "realname", realname)
if prefix:
    set_key("lists", "prefix", prefix)
if wait:
    set_key("lists", "wait", wait)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
os.replace(tmp, path)
mode = (get_key("service", "mode") or "local").lower()
sys.stdout.write("mode=%s\n" % mode)
PYEOF
mode=$("$PY" - "$CONF" <<'PYEOF'
import re, sys
mode = "local"
sec = None
for l in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"^\s*\[([^\]]+)\]\s*$", l)
    if m:
        sec = m.group(1).strip().lower()
    elif sec == "service":
        m = re.match(r"^\s*mode\s*[=:]\s*(\S+)", l, re.I)
        if m:
            mode = m.group(1).lower()
print(mode)
PYEOF
)
log "tvmail.conf : [services] order and [lists] set in $CONF"
if [ "$mode" != remote ]; then
  warn "tvmail.conf has [service] mode = $mode: Lists reads list mail over IMAP, so it only shows in remote mode (set mode = remote, with [imap] and [smtp] for the mail server)"
fi

cat <<EOF

== tvmail ==
  Start tvmail: Lists is in the Services pane (View > Services pane if it is hidden).
  Message > Lists > Available lists... asks $ADDRESS what there is; Enter on one subscribes.
  A list shows in the Lists pane once you are on it; Ctrl-R and Ctrl-N write to the list.
EOF
