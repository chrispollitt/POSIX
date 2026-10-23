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
#      needed): on a cmpi-router box, UDP 518 goes in
#      /etc/router-setup/lan0-udp-ports and TCP 518 + the relay ports in
#      lan0-tcp-ports, then `setup-router.sh fw` reloads - refused if that
#      setup-router.sh has no UDP list yet, or if the reload would close a
#      port open only by a runtime rule (as configure-ergo.sh does);
#      elsewhere the nft rules to add are printed.
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
#                        file in $CHAT_SETUP_NFT_RULESET)
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
LAN_PORTS_FILE="${CHAT_SETUP_LAN_PORTS:-/etc/router-setup/lan0-tcp-ports}"
LAN_UDP_PORTS_FILE="${CHAT_SETUP_LAN_UDP_PORTS:-/etc/router-setup/lan0-udp-ports}"
NFT_CONF="${CHAT_SETUP_NFT_CONF:-/etc/nftables.conf}"   # what setup-router.sh fw loads
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
# firewall: what step 5 would do, as "how<TAB>...":
#   list  FILE  PROTO  PORT   add PORT to that cmpi-router list
#   nft   COMMAND             a runtime rule (not a cmpi-router box)
# --------------------------------------------------------------------------
fw_ruleset() {
  if [ -n "${CHAT_SETUP_NFT_RULESET:-}" ]; then cat "$CHAT_SETUP_NFT_RULESET" 2>/dev/null || true
  elif command -v nft >/dev/null 2>&1; then ${SUDO:-} nft list ruleset 2>/dev/null || true
  fi
}

# The ports of PROTO that input chains accept, one per line, from an nft
# ruleset on stdin ("udp dport 518 accept", "tcp dport { 143, 993 } accept").
accepted_ports() {
  awk -v proto="$1" '
    /^[ \t]*chain / { hook = 0; next }
    /type filter hook input/ { hook = 1; next }
    hook && $0 ~ (proto " dport") && /accept/ {
      s = $0; sub(".*" proto " dport[ \t]*", "", s)
      if (s ~ /^\{/) { sub(/^\{/, "", s); sub(/\}.*/, "", s) } else sub(/[ \t].*/, "", s)
      n = split(s, a, /[ ,\t]+/)
      for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9]+$/) print a[i]
    }' | sort -u
}

drop_policy() {   # an input chain drops by default
  fw_ruleset | grep -q 'type filter hook input.*policy drop'
}

listed() { grep -Eq "^[[:space:]]*$2([[:space:]]|\$)" "$1" 2>/dev/null; }

wanted() {   # PROTO PORT, one per line: what talkd listens on
  echo "udp $PORT"
  echo "tcp $PORT"
  seq "$RLO" "$RHI" | sed 's/^/tcp /'
}

fw_plan() {
  local proto port file live
  if [ -f "$LAN_PORTS_FILE" ]; then
    wanted | while read -r proto port; do
      if [ "$proto" = udp ]; then file=$LAN_UDP_PORTS_FILE; else file=$LAN_PORTS_FILE; fi
      listed "$file" "$port" || printf 'list\t%s\t%s\t%s\n' "$file" "$proto" "$port"
    done
    return 0
  fi
  drop_policy || return 0
  live=$(fw_ruleset)
  wanted | while read -r proto port; do
    printf '%s\n' "$live" | accepted_ports "$proto" | grep -qx "$port" && continue
    printf 'nft\tnft add rule inet filter input iifname "%s" %s dport %s accept\n' "$IFACE" "$proto" "$port"
  done
}

# Ports the live firewall accepts that `setup-router.sh fw` would drop (in
# neither the file it rebuilds nor its lists), as "PROTO PORT" lines.
fw_lost_ports() {
  local proto live keep list
  for proto in tcp udp; do
    if [ "$proto" = udp ]; then list=$LAN_UDP_PORTS_FILE; else list=$LAN_PORTS_FILE; fi
    live=$(fw_ruleset | accepted_ports "$proto")
    # (a list may not exist yet - lan0-udp-ports until the first --open-firewall)
    keep=$( { if [ -n "${CHAT_SETUP_NFT_CONF:-}" ]; then cat "$NFT_CONF" 2>/dev/null
              else ${SUDO:-} cat "$NFT_CONF" 2>/dev/null; fi; } | accepted_ports "$proto"
            [ ! -f "$list" ] || awk '$1 ~ /^[0-9]+$/ { print $1 }' "$list" )
    comm -23 <(printf '%s\n' "$live" | sed '/^$/d' | sort -u) \
             <(printf '%s\n' "$keep" | sed '/^$/d' | sort -u) | sed "s/^/$proto /"
  done
}

router_script() {   # cmpi-router's setup-router.sh, if it can be found
  local u h
  [ -n "${CHAT_SETUP_ROUTER:-}" ] && { echo "$CHAT_SETUP_ROUTER"; return 0; }
  for u in "${SUDO_USER:-}" "$(id -un)"; do
    [ -n "$u" ] || continue
    h=$(getent passwd "$u" | cut -d: -f6)
    [ -x "$h/cmpi-router/bin/setup-router.sh" ] && { echo "$h/cmpi-router/bin/setup-router.sh"; return 0; }
  done
  return 1
}

# a setup-router.sh too old to read lan0-udp-ports would drop UDP 518 again
router_reads_udp() {
  local sr; sr=$(router_script) || return 1
  grep -q 'LAN_UDP_PORTS_FILE' "$sr"
}

comment_for() {   # PROTO PORT -> the comment for the list line
  case "$1 $2" in
    "udp $PORT") echo "talk(1), ntalk (chat-setup talkd)" ;;
    "tcp $PORT") echo "tvchat to talkd (chat-setup)" ;;
    *)           echo "talkd relay (chat-setup)" ;;
  esac
}

# --------------------------------------------------------------------------
# the print-only modes (no root, nothing changed)
# --------------------------------------------------------------------------
case "$MODE" in
  print-unit)  make_unit; exit 0 ;;
  print-inetd) inetd_edit "$PRINT_FROM"; exit 0 ;;
  firewall-plan)
    plan=$(fw_plan)
    printf '%s\n' "$plan" | while IFS=$'\t' read -r how a b c; do
      case "$how" in
        list) echo "add '$c  # $(comment_for "$b" "$c")' to $a" ;;
        nft)  echo "$a" ;;
      esac
    done
    if printf '%s\n' "$plan" | grep -q '^list'; then
      echo "then run setup-router.sh fw"
      printf '%s\n' "$plan" | grep -q "^list.*udp" && ! router_reads_udp \
        && echo "REFUSED: setup-router.sh has no UDP list (lan0-udp-ports) - update cmpi-router first"
      lost=$(fw_lost_ports)
      [ -z "$lost" ] || echo "REFUSED: that reload would close $(echo $lost) (opened at runtime, in no list): list them first"
    fi
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
  log "the firewall lists and $INETD_CONF are as they were - edit them by hand to undo"
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
FW=$(fw_plan)
if [ -z "$FW" ]; then
  log "firewall    : nothing to open"
elif printf '%s\n' "$FW" | grep -q '^list'; then
  if [ "$OPEN_FW" != 1 ]; then
    warn "the firewall drops talkd's ports: re-run with --open-firewall (adds them to"
    warn "  $LAN_PORTS_FILE / $LAN_UDP_PORTS_FILE and reloads with setup-router.sh fw)"
  else
    if printf '%s\n' "$FW" | grep -q "^list.*udp" && ! router_reads_udp; then
      die "not touching the firewall: cmpi-router's setup-router.sh does not read
  $LAN_UDP_PORTS_FILE yet, so UDP $PORT would stay closed.  Update cmpi-router,
  then re-run.  (talkd runs; tvchat on the LAN cannot reach it yet.)"
    fi
    lost=$(fw_lost_ports)
    if [ -n "$lost" ]; then
      die "not reloading the firewall: setup-router.sh fw rebuilds it from its lists,
  and these ports are open now only by runtime rules, so they would close:
      $(echo $lost)
  Add each to its list first (\"PORT  # what it is\", one per line), then re-run.
  (Nothing was changed: talkd runs, but its ports are not open to the LAN yet.)"
    fi
    $SUDO install -d -m 755 "$(dirname "$LAN_UDP_PORTS_FILE")"
    [ -f "$LAN_UDP_PORTS_FILE" ] || $SUDO touch "$LAN_UDP_PORTS_FILE"
    printf '%s\n' "$FW" | while IFS=$'\t' read -r how file proto port; do
      [ "$how" = list ] || continue
      printf '%s  # %s\n' "$port" "$(comment_for "$proto" "$port")" | $SUDO tee -a "$file" >/dev/null
      log "firewall    : $proto $port added to $file"
    done
    if sr=$(router_script); then
      $SUDO "$sr" fw && log "firewall    : reloaded ($sr fw)"
    else
      warn "now run 'sudo ./bin/setup-router.sh fw' in cmpi-router to load the rules"
    fi
  fi
else
  printf '%s\n' "$FW" | while IFS=$'\t' read -r how what; do
    if [ "$OPEN_FW" = 1 ]; then
      eval "$SUDO $what" && log "firewall    : $what"   # ports are numbers, the iface vetted
    else
      warn "open it: $what"
    fi
  done
  [ "$OPEN_FW" = 1 ] && warn "those rules are lost when nftables reloads - add them to your ruleset file too"
fi

host=$(hostname -s 2>/dev/null || hostname)
cat <<EOF

== talk ==
  From any shell on the LAN:   talk $(id -un)@$host
  tvchat: [account:talk] with protocol = talk, host = $host (TUIs milestone 6, step 4).
  Log: journalctl -u talkd   (more: add --debug to ExecStart in $UNIT)
EOF
