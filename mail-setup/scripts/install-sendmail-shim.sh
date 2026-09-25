#!/usr/bin/env bash
#
# install-sendmail-shim.sh
#
# For a CLIENT box (no MTA of its own): install bin/sendmail-shim as
# /usr/sbin/sendmail.  It forwards every message straight to the master's
# SMTP port - no local queue, no retries, no auth (the master's Postfix has to
# trust this LAN via mynetworks).  Anything that calls sendmail(8) - mail(1),
# cron, tvmail in local mode - then just works.
#
# The existing /usr/sbin/sendmail, if any, is kept as sendmail.orig.<stamp>.
#
# Usage:
#   ./install-sendmail-shim.sh [--host MASTER] [--port N]
#
# Options:
#   --host NAME   the master's hostname   (default: ask, suggesting cmpi)
#   --port N      its SMTP port           (default: ask, suggesting 25)
#   -h | --help   show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../lib/common.sh"

MASTER_HOST=""
MASTER_PORT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --host)    MASTER_HOST="${2:?}"; shift 2 ;;
    --port)    MASTER_PORT="${2:?}"; shift 2 ;;
    -h|--help) usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PY="$(find_python || true)"
[ -n "$PY" ] || die "need a python3 (>= 3.6) - the shim is a Python script"

[ -n "$MASTER_HOST" ] || MASTER_HOST=$(readval "master hostname" "cmpi")
[ -n "$MASTER_PORT" ] || MASTER_PORT=$(readval "master SMTP port (25 = trusts this LAN via mynetworks, no auth)" "25")

dest="${SENDMAIL_DEST:-/usr/sbin/sendmail}"   # override: tests
tmp=$(mktemp)
sed -e "1s|.*|#!${PY}|" \
    -e "s/^RELAY_HOST = .*/RELAY_HOST = \"$MASTER_HOST\"  # set by install-sendmail-shim.sh/" \
    -e "s/^RELAY_PORT = .*/RELAY_PORT = $MASTER_PORT                     # set by install-sendmail-shim.sh/" \
    "$here/../bin/sendmail-shim" > "$tmp"
chmod 755 "$tmp"
if [ -e "$dest" ]; then
  $SUDO cp -p "$dest" "$dest.orig.$(date +%Y%m%d-%H%M%S)" 2>/dev/null \
    && log "backed up existing $dest"
fi
$SUDO install -m 0755 "$tmp" "$dest" && rm -f "$tmp"
$SUDO chown root:root "$dest" 2>/dev/null || true
log "installed $dest -> relays to $MASTER_HOST:$MASTER_PORT"
