#!/usr/bin/env bash
#
# configure-inn.sh
#
# Run a Usenet server for the LAN on this box (the master, cpbee): INN2, the real thing,
# with no peers and no feeds - a news server nobody outside can reach, whose articles are
# the ones you import (news-import, ../bin) and what the LAN posts to lan.*.  Read it with
# tvmail's Usenet service (tvmail.conf [news] host), or any newsreader.  The script:
#
#   1. installs the inn2 package (apt);
#   2. sets what it needs in /etc/news - and nothing else:
#        inn.conf      organization, pathhost, artcutoff 0 (an article of 1987 is not "too old"),
#                      maxartsize, verifycancels off.  Only these keys change; the rest of the
#                      file the package wrote stays.
#        readers.conf  who may read and post: this machine and the --allow networks (default:
#                      lan0's subnet) may read everything and post to lan.* only; everyone else
#                      is refused.  A re-run rewrites this file.
#        incoming.conf no peers, except this machine itself (127.0.0.1) - news-import feeds the
#                      archive to innd with IHAVE from there.  A re-run rewrites this file.
#        expire.ctl    nothing ever expires.  A re-run rewrites this file.
#      (each file that changes is backed up first: BAK/ beside it, the 3 newest kept);
#   3. restarts inn2 if a file changed, and waits for port 119;
#   4. creates the local groups (lan.misc lan.talk lan.test; --local-groups) with posting allowed.
#      Archive groups are made by create-groups.sh, read-only ("n": only a feed can add to them);
#   5. the firewall, only with --open-firewall (by default it says what is needed): TCP 119, for
#      the LAN only, through ../../net-utils/lan-port - on a cmpi-router box listed in
#      /etc/router-setup/lan0-tcp-ports, the firewall reloaded once, the port checked.
#      THIS IS AN EXPOSURE CHANGE: it lets the LAN talk to the news server.  --firewall-plan shows it.
#
# Re-runnable.  Linux with systemd (Debian, Ubuntu, Raspberry Pi OS).  Never answers the WAN.
#
# Usage:
#   sudo ./configure-inn.sh [options]
#
# Options:
#   --pathhost NAME     the name put in the Path: of every article (default: the full hostname)
#   --organization TXT  the Organization: header of local posts (default: "LAN news")
#   --allow CIDR        a network that may read, besides loopback (repeatable; default: lan0's subnet)
#   --local-groups L    comma list of the groups people may post to (default: lan.misc,lan.talk,lan.test)
#   --open-firewall     open TCP 119 for the LAN as described in 5. above
#   --config-only       just write the files of 2. (into $NEWS_SETUP_ETC, /etc/news): no package, no
#                       service, no groups, no firewall
#   --firewall-plan     print what step 5 would do and exit - no root, nothing changed
#   --print-config WHAT print a file and exit - no root, nothing changed: inn.conf (the package's
#                       file is the next argument: FILE), readers.conf, incoming.conf, expire.ctl
#   -h | --help         show this header
#
set -euo pipefail

# set -e stops at the first failing command - say where, never silently; -E: inside functions too
set -E
trap 'rc=$?; printf "ERROR: configure-inn.sh stopped at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# the shared helpers (log/warn/die/step/pkg_install/cidr_check, OS + SUDO) are mail-setup's
. "$here/../../mail-setup/lib/common.sh"
# tests set NEWS_SETUP_SUDO= (empty) so nothing ever escalates
[ "${NEWS_SETUP_SUDO+set}" = set ] && SUDO="$NEWS_SETUP_SUDO"

ETC="${NEWS_SETUP_ETC:-/etc/news}"
DB="${NEWS_SETUP_DB:-/var/lib/news}"
UNIT="${NEWS_SETUP_UNIT:-inn2}"
CTLINND="${NEWS_SETUP_CTLINND:-/usr/lib/news/bin/ctlinnd}"
IFACE="${NEWS_SETUP_IFACE:-lan0}"
PORT=119

PATHHOST=""
ORG="LAN news"
ALLOW=()
LOCAL_GROUPS="lan.misc,lan.talk,lan.test"
OPEN_FW=0
CONFIG_ONLY=0
MODE=install       # install | print-config | firewall-plan
PRINT_WHAT=""; PRINT_FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pathhost)      PATHHOST="${2:?}"; shift 2 ;;
    --organization)  ORG="${2:?}"; shift 2 ;;
    --allow)         ALLOW+=("${2:?}"); shift 2 ;;
    --local-groups)  LOCAL_GROUPS="${2:?}"; shift 2 ;;
    --open-firewall) OPEN_FW=1; shift ;;
    --config-only)   CONFIG_ONLY=1; shift ;;
    --firewall-plan) MODE=firewall-plan; shift ;;
    --print-config)  MODE=print-config; PRINT_WHAT="${2:?}"; shift 2
                     if [ "$PRINT_WHAT" = inn.conf ]; then PRINT_FROM="${1:?--print-config inn.conf FILE: which inn.conf to start from}"; shift; fi ;;
    -h|--help)       usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PATHHOST" ] || PATHHOST=$(hostname -f 2>/dev/null || hostname)
case "$PATHHOST" in *[!A-Za-z0-9.-]*|'') die "--pathhost: '$PATHHOST' is not a host name" ;; esac
case "$ORG" in *'"'*|*$'\n'*) die "--organization: no quotes or newlines" ;; esac
case "$LOCAL_GROUPS" in
  *[!A-Za-z0-9.,_+-]*|'') die "--local-groups: a comma list of group names, e.g. lan.misc,lan.talk" ;;
esac

lan_subnet() {
  [ -n "${NEWS_SETUP_LAN_CIDR:-}" ] && { echo "$NEWS_SETUP_LAN_CIDR"; return 0; }
  ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}' | grep .
}
if [ "${#ALLOW[@]}" = 0 ]; then
  net=$(lan_subnet || true)
  if [ -n "$net" ]; then ALLOW=("$net")
  elif [ "$MODE" = print-config ] && [ "$PRINT_WHAT" != readers.conf ]; then ALLOW=()
  else die "no IPv4 on $IFACE - name the LAN with --allow CIDR"; fi
fi
for i in "${!ALLOW[@]}"; do
  ALLOW[$i]=$(cidr_check "${ALLOW[$i]}") || die "--allow: '${ALLOW[$i]}' is not an IPv4 CIDR"
  case "${ALLOW[$i]}" in 0.0.0.0/*) die "--allow ${ALLOW[$i]} would let everyone read - name the LAN" ;; esac
done

# --------------------------------------------------------------------------
# the files
# --------------------------------------------------------------------------
# set_key FILE KEY VALUE -> FILE with "KEY: VALUE" in place of its (uncommented) KEY line, or added at the end
set_key() {
  awk -v k="$2" -v v="$3" '
    BEGIN { done = 0 }
    $0 ~ "^[ \t]*" k "[ \t]*:" { if (!done) { print k ": " v; done = 1 } ; next }
    { print }
    END { if (!done) print k ": " v }' "$1"
}

make_inn_conf() {   # make_inn_conf FILE -> FILE with our keys set, on stdout
  local t1 t2
  t1=$(mktemp); t2=$(mktemp)
  cp "$1" "$t1"
  set_key "$t1" organization "\"$ORG\""      > "$t2"; cp "$t2" "$t1"
  set_key "$t1" pathhost "$PATHHOST"         > "$t2"; cp "$t2" "$t1"
  set_key "$t1" artcutoff 0                  > "$t2"; cp "$t2" "$t1"
  set_key "$t1" maxartsize 4000000           > "$t2"; cp "$t2" "$t1"
  set_key "$t1" verifycancels false          > "$t2"; cp "$t2" "$t1"
  cat "$t1"
  rm -f "$t1" "$t2"
}

make_readers_conf() {
  local hosts="127.0.0.1, ::1" a
  for a in "${ALLOW[@]}"; do hosts="$hosts, $a"; done
  cat <<EOF
# readers.conf - written by news-setup/scripts/configure-inn.sh (a re-run overwrites this file).
# The LAN may read everything and post to lan.* only; a machine in no auth group below is refused.
# (The archive groups are read-only anyway: the server takes articles for them only from a feed.)
auth "lan" {
    hosts: "$hosts"
    default: "<LAN>"
}

access "lan" {
    users: "<LAN>"
    read: "*"
    post: "lan.*"
}
EOF
}

make_incoming_conf() {
  cat <<'EOF'
# incoming.conf - written by news-setup/scripts/configure-inn.sh (a re-run overwrites this file).
# No peers: nobody feeds this server and it feeds nobody.  The one exception is the machine itself,
# so that news-import can hand it the archive with IHAVE from 127.0.0.1.
peer localhost {
    hostname: "127.0.0.1"
    patterns: "*"
}
EOF
}

make_expire_ctl() {
  cat <<'EOF'
# expire.ctl - written by news-setup/scripts/configure-inn.sh (a re-run overwrites this file).
# Nothing expires: the archive is the point.
/remember/:14
*:A:never:never:never
EOF
}

case "$MODE" in
  print-config)
    case "$PRINT_WHAT" in
      inn.conf)      [ -r "$PRINT_FROM" ] || die "cannot read $PRINT_FROM"; make_inn_conf "$PRINT_FROM" ;;
      readers.conf)  make_readers_conf ;;
      incoming.conf) make_incoming_conf ;;
      expire.ctl)    make_expire_ctl ;;
      *) die "--print-config: inn.conf FILE, readers.conf, incoming.conf or expire.ctl" ;;
    esac
    exit 0 ;;
esac

# --------------------------------------------------------------------------
# firewall: ../../net-utils/lan-port (see configure-talkd.sh): on a cmpi-router box the port goes in
# lan0-tcp-ports and the firewall is reloaded once; elsewhere the runtime nft rule is planned.
# fw_plan exits 0: nothing to do, 3: it would open the port, 1: it refuses.
# --------------------------------------------------------------------------
LAN_PORT_SPECS=("$PORT/tcp" "Usenet NNTP (news-setup, INN2)")
fw_plan() { LAN_PORT_IIF=$IFACE lan_port plan "${LAN_PORT_SPECS[@]}"; }
fw_add()  { LAN_PORT_IIF=$IFACE lan_port add "${LAN_PORT_SPECS[@]}"; }
if [ "$MODE" = firewall-plan ]; then fw_plan || true; exit 0; fi

# --------------------------------------------------------------------------
# from here on: the real thing
# --------------------------------------------------------------------------
if [ "$CONFIG_ONLY" != 1 ]; then
  [ "$IS_LINUX" = 1 ] || die "Linux only"
  if [ "$(id -u)" != 0 ] && [ -z "$SUDO" ]; then die "run as root (no sudo found)"; fi
  [ -d /run/systemd/system ] || die "this needs systemd"
fi

# keep_backups FILE: BAK/ beside FILE holds copies of what we replaced; only the 3 newest stay
backup_keep3() {
  local f="$1" d b
  [ -e "$f" ] || return 0
  d=$(dirname "$f")/BAK; b=$(basename "$f")
  $SUDO mkdir -p "$d"
  $SUDO cp -p "$f" "$d/$b.bak-$(date +%Y%m%d-%H%M%S)"
  # shellcheck disable=SC2012
  ls -1t "$d/$b".bak-* 2>/dev/null | tail -n +4 | while IFS= read -r old; do $SUDO rm -f "$old"; done
}

# put_file NAME NEWFILE: install NEWFILE as $ETC/NAME if it differs (backed up first); sets `changed`
put_file() {
  local dest="$ETC/$1"
  if $SUDO cmp -s "$2" "$dest" 2>/dev/null; then
    log "$1: unchanged"
  else
    backup_keep3 "$dest"
    $SUDO install -d -m 755 "$ETC"
    $SUDO install -m 644 "$2" "$dest"
    # INN reads its files as the news user: keep the group the package gave the directory, if there is one
    if getent group news >/dev/null 2>&1; then $SUDO chgrp news "$dest" 2>/dev/null || true; fi
    changed=1
    log "$1: written"
  fi
}

step "INN2 for the LAN (path: $PATHHOST; read from 127.0.0.1 ${ALLOW[*]}; post to lan.*)"

# 1. the package -------------------------------------------------------------------
if [ "$CONFIG_ONLY" != 1 ]; then
  if ! dpkg -s inn2 >/dev/null 2>&1; then
    [ "$PKG" = apt ] || die "this installs inn2 with apt (Debian, Ubuntu, Raspberry Pi OS); install INN2 by hand and re-run with --config-only"
    pkg_install inn2
    log "package     : inn2 installed"
  else
    log "package     : inn2 is installed"
  fi
fi

# 2. the files ---------------------------------------------------------------------
changed=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -r "$ETC/inn.conf" ]; then base="$ETC/inn.conf"; else base=/dev/null; fi
make_inn_conf "$base" > "$tmp/inn.conf"
make_readers_conf    > "$tmp/readers.conf"
make_incoming_conf   > "$tmp/incoming.conf"
make_expire_ctl      > "$tmp/expire.ctl"
for f in inn.conf readers.conf incoming.conf expire.ctl; do put_file "$f" "$tmp/$f"; done
[ "$CONFIG_ONLY" = 1 ] && { log "(--config-only: the files are in $ETC; nothing else was done)"; exit 0; }

# 3. the service -------------------------------------------------------------------
$SUDO systemctl enable "$UNIT" >/dev/null 2>&1 || true
if [ "$changed" = 1 ] || ! systemctl is-active -q "$UNIT"; then
  $SUDO systemctl restart "$UNIT" || true
fi
up() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$PORT\$"; }
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do up && break; sleep 1; done
if ! up; then
  warn "innd is not listening on TCP $PORT - the last journal lines:"
  $SUDO journalctl -u "$UNIT" -n 30 --no-pager >&2 || true
  die "$UNIT did not start - the old files are in $ETC/BAK"
fi
log "service     : $UNIT running on TCP $PORT"

# 4. the local groups --------------------------------------------------------------
as_news() {   # run a command as the news user
  if [ "${NEWS_SETUP_AS_NEWS+set}" = set ]; then $NEWS_SETUP_AS_NEWS "$@"
  elif [ "$(id -u)" = 0 ]; then runuser -u news -- "$@"
  else $SUDO -u news "$@"; fi
}
for g in ${LOCAL_GROUPS//,/ }; do
  if grep -q "^$g " "$DB/active" 2>/dev/null; then
    log "group       : $g exists"
  else
    as_news "$CTLINND" newgroup "$g" y "news@$PATHHOST" >/dev/null
    printf '%s\tLocal discussion (LAN only)\n' "$g" | $SUDO tee -a "$DB/newsgroups" >/dev/null
    log "group       : $g created (posting allowed)"
  fi
done

# 5. the firewall ------------------------------------------------------------------
rc=0; plan=$(fw_plan 2>&1) || rc=$?
if [ "$rc" = 0 ]; then
  log "firewall    : nothing to open"
elif [ "$OPEN_FW" != 1 ]; then
  warn "the firewall does not open the news port yet (this is what lets the LAN reach the server):"
  warn "re-run with --open-firewall, which does this:"
  printf '%s\n' "$plan" | while IFS= read -r l; do warn "  $l"; done
else
  fw_add || die "the firewall was not opened (see above): innd runs, but the LAN cannot reach it yet"
fi

host=$(hostname -s 2>/dev/null || hostname)
cat <<EOF

== Usenet ==
  Check:        printf 'LIST ACTIVE lan.*\r\nQUIT\r\n' | nc $host $PORT
  Archive:      ./create-groups.sh groups.d/classic.list      (read-only groups), then
                news-import --groups groups.d/classic.list ARCHIVE...      (see README.md)
  tvmail:       ./configure-tvmail-news.sh --host $host        (on each client)
  Log:          journalctl -u $UNIT ; /var/log/news/
EOF
