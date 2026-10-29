#!/usr/bin/env bash
#
# configure-talkd.sh
#
# Run chat-setup's talkd (../talkd/talkd.py) on this box - the LAN master -
# as the one talk(1) daemon of the LAN: plain `talk user@HOST` from any
# shell, and tvchat's talk support (tvchat connects here; laptops run no
# daemon).  Stdlib Python, no download.  The script:
#
#   1. installs talkd.py as /opt/talkd/talkd.py (root-owned; re-runs update it);
#   2. creates the 'talkd' system user (no home, no shell); the service runs
#      as it, with group tty added (to ring terminals, as talk always has)
#      and CAP_NET_BIND_SERVICE (port 518) - nothing else;
#   3. moves other talk daemons out of the way: a talk / ntalk line in
#      /etc/inetd.conf is commented out ("#chat-setup# ", backed up first)
#      and inetd reloaded; anything else holding port 518 stops the script;
#   4. installs /etc/systemd/system/talkd.service and (re)starts it:
#      ntalk on UDP 518, tvchat on TCP 518, relay ports TCP 5181-5188 (a
#      callee on another host connects to one), and --allow: loopback plus
#      lan0's subnet - talk has no passwords, so nobody else is answered;
#   5. firewall, only with --open-firewall (by default it says what is
#      needed), through ../../net-utils/lan-port: on a cmpi-router box, UDP 518
#      goes in /etc/router-setup/lan0-udp-ports and TCP 518 + the relay ports
#      in lan0-tcp-ports, then `setup-router.sh fw` reloads once and the ports
#      are checked to be open - refused (nothing changed) if that
#      setup-router.sh has no UDP list yet, or if the reload would close a
#      port open only by a runtime rule (as configure-ergo.sh does);
#      elsewhere the nft rules to add are printed (and run).
#
# Re-runnable.  Never answers the WAN: --allow, and the firewall.
#
# Usage:
#   sudo ./configure-talkd.sh [options]
#
# Options:
#   --relay-ports LO-HI  TCP ports for the relay (default: 5181-5188 - as
#                        many calls to other hosts at once)
#   --allow CIDR         who may use it, besides loopback (repeatable;
#                        default: lan0's subnet)
#   --open-firewall      open the ports as described in 5. above
#   --remove             stop and remove the service and /opt/talkd (the
#                        inetd.conf change and the firewall lists stay)
#   --firewall-plan      just print what step 5 would do, and exit - no root,
#                        nothing changed.  Reads `nft list ruleset` (or the
#                        file in $LAN_PORT_RULESET)
#   --print-unit         just print the systemd unit
#   --print-inetd FILE   just print FILE with the talk lines commented out
#   -h | --help          show this header
#
set -euo pipefail

# set -e stops at the first failing command - say where, never silently
# (twice on cpbee, Oct 22, a harmless empty grep ended it without a word);
# -E: inside functions too
set -E
trap 'rc=$?; printf "ERROR: configure-talkd.sh stopped at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# the shared helpers (log/warn/die/backup/cidr_check, OS + SUDO) are mail-setup's
. "$here/../../mail-setup/lib/common.sh"
# tests set CHAT_SETUP_SUDO= (empty) so nothing ever escalates
[ "${CHAT_SETUP_SUDO+set}" = set ] && SUDO="$CHAT_SETUP_SUDO"

PORT=518                             # talk's port: clients do not ask
RELAY=5181-5188
ALLOW=()
OPEN_FW=0
REMOVE=0
MODE=install       # install | firewall-plan | print-unit | print-inetd
PRINT_FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --relay-ports)   RELAY="${2:?}"; shift 2 ;;
    --allow)         ALLOW+=("${2:?}"); shift 2 ;;
    --open-firewall) OPEN_FW=1; shift ;;
    --remove)        REMOVE=1; shift ;;
    --firewall-plan) MODE=firewall-plan; shift ;;
    --print-unit)    MODE=print-unit; shift ;;
    --print-inetd)   MODE=print-inetd; PRINT_FROM="${2:?}"; shift 2 ;;
    -h|--help)       usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$RELAY" in
  *[!0-9-]*|-*|*-|*-*-*|'') die "--relay-ports: LO-HI, e.g. 5181-5188" ;;
  *-*) RLO=${RELAY%-*}; RHI=${RELAY#*-} ;;
  *)   RLO=$RELAY; RHI=$RELAY ;;
esac
[ "$RLO" -ge 1024 ] && [ "$RLO" -le "$RHI" ] && [ "$RHI" -le 65535 ] \
  && [ $((RHI - RLO)) -lt 64 ] || die "--relay-ports: LO-HI within 1024-65535, at most 64 ports"

PREFIX=/opt/talkd
UNIT=/etc/systemd/system/talkd.service
INETD_CONF="${CHAT_SETUP_INETD_CONF:-/etc/inetd.conf}"
IFACE="${CHAT_SETUP_IFACE:-lan0}"

# --allow: loopback always, plus the LAN - lan0's subnet unless named
lan_subnet() {
  [ -n "${CHAT_SETUP_LAN_CIDR:-}" ] && { echo "$CHAT_SETUP_LAN_CIDR"; return 0; }
  ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}' | grep .
}
if [ "${#ALLOW[@]}" = 0 ] && [ "$MODE" != print-inetd ]; then
  net=$(lan_subnet || true)
  [ -n "$net" ] || die "no IPv4 on $IFACE - name the LAN with --allow CIDR"
  ALLOW=("$net")
fi
for i in "${!ALLOW[@]}"; do
  ALLOW[$i]=$(cidr_check "${ALLOW[$i]}") || die "--allow: '${ALLOW[$i]}' is not an IPv4 CIDR"
  case "${ALLOW[$i]}" in 0.0.0.0/*) die "--allow ${ALLOW[$i]} would answer everyone - name the LAN" ;; esac
done

# --------------------------------------------------------------------------
# the unit
# --------------------------------------------------------------------------
make_unit() {
  local py allow="--allow 127.0.0.0/8" a
  py=$(command -v python3 || echo /usr/bin/python3)
  for a in "${ALLOW[@]}"; do allow="$allow --allow $a"; done
  cat <<EOF
# talkd.service - written by chat-setup/scripts/configure-talkd.sh
[Unit]
Description=talk(1) daemon for the LAN, and tvchat's talk relay (chat-setup)
After=network-online.target
Wants=network-online.target

[Service]
User=talkd
Group=talkd
# to ring a terminal (/dev/pts/N is group tty), as talk always has
SupplementaryGroups=tty
ExecStart=$py $PREFIX/talkd.py --port $PORT --relay-ports $RLO-$RHI $allow
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# --------------------------------------------------------------------------
# inetd: talk / ntalk lines commented out (both want port 518)
# --------------------------------------------------------------------------
inetd_edit() {   # inetd_edit FILE -> the file with them commented out, on stdout
  awk '/^[ \t]*(talk|ntalk)[ \t]/ { print "#chat-setup# " $0; next } { print }' "$1"
}
inetd_has_talk() { grep -Eq '^[[:space:]]*(talk|ntalk)[[:space:]]' "$1" 2>/dev/null; }

# the process (as ss names it, "name") holding UDP $PORT, other than our own
# talkd.py; empty - and success - when there is none
port_holder() {
  { ${SUDO:-} ss -lunpH "sport = :$PORT" 2>/dev/null || true; } \
    | awk '!/talkd\.py/ { if (match($0, /users:\(\("[^"]*"/)) { print substr($0, RSTART + 8, RLENGTH - 8); exit } }'
}

# --------------------------------------------------------------------------
# firewall: ../../net-utils/lan-port lists the ports (UDP 518 in lan0-udp-ports,
# the TCP ones in lan0-tcp-ports), reloads once with cmpi-router's
# setup-router.sh fw and checks they are open - or, off a cmpi-router box,
# plans the runtime nft rules.  It refuses, changing nothing, if
# setup-router.sh has no UDP list or the reload would close a port that is
# open only by a runtime rule.  Nothing here reads the ruleset or edits a list.
# fw_plan exits 0: nothing to do, 3: it would open ports, 1: it refuses.
# --------------------------------------------------------------------------
LAN_PORT_SPECS=("$PORT/udp" "talk(1), ntalk (chat-setup talkd)"
                "$PORT/tcp" "tvchat to talkd (chat-setup)"
                "$RLO-$RHI/tcp" "talkd relay (chat-setup)")
fw_plan() { LAN_PORT_IIF=$IFACE lan_port plan "${LAN_PORT_SPECS[@]}"; }
fw_add()  { LAN_PORT_IIF=$IFACE lan_port add "${LAN_PORT_SPECS[@]}"; }

# --------------------------------------------------------------------------
# the print-only modes (no root, nothing changed)
# --------------------------------------------------------------------------
case "$MODE" in
  print-unit)  make_unit; exit 0 ;;
  print-inetd) inetd_edit "$PRINT_FROM"; exit 0 ;;
  firewall-plan)
    fw_plan || true
    exit 0 ;;
esac

# --------------------------------------------------------------------------
# from here on: the real thing
# --------------------------------------------------------------------------
[ "$IS_LINUX" = 1 ] || die "Linux only"
if [ "$(id -u)" != 0 ] && [ -z "$SUDO" ]; then die "run as root (no sudo found)"; fi
[ -d /run/systemd/system ] || die "this needs systemd"

if [ "$REMOVE" = 1 ]; then
  step "removing talkd"
  $SUDO systemctl disable --now talkd 2>/dev/null || true
  $SUDO rm -f "$UNIT"
  $SUDO systemctl daemon-reload
  $SUDO rm -rf "$PREFIX"
  log "removed the service and $PREFIX"
  log "the firewall lists and $INETD_CONF are as they were - undo with: $LAN_PORT remove $PORT/udp $PORT $RLO-$RHI; and edit $INETD_CONF by hand"
  exit 0
fi

PY=$(find_python) || die "python3 (3.6 or later) is needed"
"$PY" -c 'import sys; sys.exit(sys.version_info < (3, 6))' || die "talkd needs python 3.6 or later"
SRC="$here/../talkd/talkd.py"
[ -f "$SRC" ] || die "no $SRC - run this from a chat-setup checkout"
command -v ss >/dev/null 2>&1 || die "ss (iproute2) is needed"

step "talkd on port $PORT (relay $RLO-$RHI; allowed: 127.0.0.0/8 ${ALLOW[*]})"

# 1. the program --------------------------------------------------------------
changed=0
$SUDO install -d -o root -g root -m 755 "$PREFIX"
if $SUDO cmp -s "$SRC" "$PREFIX/talkd.py" 2>/dev/null; then
  log "talkd.py    : unchanged in $PREFIX"
else
  $SUDO install -o root -g root -m 755 "$SRC" "$PREFIX/talkd.py"
  changed=1
  log "talkd.py    : installed in $PREFIX"
fi

# 2. the user -----------------------------------------------------------------
if ! getent passwd talkd >/dev/null; then
  if command -v adduser >/dev/null 2>&1 && adduser --help 2>&1 | grep -q -- --system; then
    $SUDO adduser --system --group --home /nonexistent --no-create-home --shell /usr/sbin/nologin talkd >/dev/null
  else
    $SUDO useradd --system --user-group --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin talkd
  fi
  log "user        : talkd created"
fi
getent group tty >/dev/null || die "no tty group here - talkd could not ring a terminal"

# 3. other talk daemons -------------------------------------------------------
if inetd_has_talk "$INETD_CONF"; then
  t=$(mktemp)
  inetd_edit "$INETD_CONF" > "$t"
  backup "$INETD_CONF" sudo
  $SUDO install -m 644 "$t" "$INETD_CONF"
  rm -f "$t"
  for svc in inetutils-inetd openbsd-inetd inetd xinetd; do
    if systemctl is-active -q "$svc" 2>/dev/null; then
      $SUDO systemctl reload-or-restart "$svc" && log "inetd       : talk/ntalk commented out in $INETD_CONF, $svc reloaded"
      break
    fi
  done
fi
if systemctl list-unit-files 2>/dev/null | grep -Eq '^(talkd|ntalkd|talk)\.socket'; then
  warn "a talk socket unit exists - disable it if it holds port $PORT"
fi
holder=$(port_holder)
if [ -n "$holder" ] && ! systemctl is-active -q talkd; then
  die "UDP $PORT is held by $holder - stop it first (another talkd?)"
fi

# 4. the service --------------------------------------------------------------
unit_new=$(mktemp)
make_unit > "$unit_new"
if ! cmp -s "$unit_new" "$UNIT" 2>/dev/null; then
  $SUDO install -m 644 "$unit_new" "$UNIT"
  $SUDO systemctl daemon-reload
  changed=1
fi
rm -f "$unit_new"
up() {
  ss -lunH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$PORT\$" &&
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$PORT\$"
}
$SUDO systemctl enable talkd >/dev/null 2>&1
if [ "$changed" = 1 ] || ! systemctl is-active -q talkd; then
  $SUDO systemctl restart talkd || true
fi
for _ in 1 2 3 4 5 6 7 8 9 10; do up && break; sleep 1; done
if ! up; then
  warn "talkd is not listening on UDP + TCP $PORT - the last journal lines:"
  $SUDO journalctl -u talkd -n 30 --no-pager >&2 || true
  die "talkd did not start"
fi
log "service     : talkd running - UDP $PORT (talk), TCP $PORT (tvchat), relay $RLO-$RHI"

# 5. firewall -------------------------------------------------------------------
rc=0; plan=$(fw_plan 2>&1) || rc=$?
if [ "$rc" = 0 ]; then
  log "firewall    : nothing to open"
elif [ "$OPEN_FW" != 1 ]; then
  warn "the firewall does not open talkd's ports yet: re-run with --open-firewall, which does this:"
  printf '%s\n' "$plan" | while IFS= read -r l; do warn "  $l"; done
else
  fw_add || die "the firewall was not opened (see above): talkd runs, but its ports are not open to the LAN yet"
fi

host=$(hostname -s 2>/dev/null || hostname)
cat <<EOF

== talk ==
  From any shell on the LAN:   talk $(id -un)@$host
  tvchat: [account:talk] with protocol = talk, host = $host (TUIs milestone 6, step 4).
  Log: journalctl -u talkd   (more: add --debug to ExecStart in $UNIT)
EOF
