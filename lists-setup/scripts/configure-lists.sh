#!/usr/bin/env bash
#
# configure-lists.sh
#
# Run LISTSERV-style mailing lists for the LAN on this box (the mail master: Postfix + Dovecot, set up with
# mail-setup).  The lists are mlmmj lists; people join and leave by mailing commands to listserv@HOST (SUBSCRIBE,
# SIGNOFF, SET ... DIGEST, LIST ...), and list mail arrives in each member's own IMAP folder Lists/NAME, which tvmail's
# Lists service reads.  The script:
#
#   1. checks what it builds on: Postfix, Dovecot and mail-setup's Sieve step (mail delivered through dovecot-lda) -
#      it stops with the script to run first if one is missing;
#   2. installs the mlmmj package and its user (mlmmj, who owns the lists and runs the Postfix pipes), unless --no-install;
#   3. installs listserv, listctl and list-import (/usr/local/bin) and writes /etc/lists-setup/lists.conf;
#   4. Postfix, as mlmmj's README.postfix says: tables /var/spool/mlmmj/virtual and transport (listctl writes them),
#      added to virtual_alias_maps / transport_maps (and virtual to local_recipient_maps, so the SMTP server accepts list
#      addresses in a local domain), recipient_delimiter +, and two pipe services in master.cf: `mlmmj`
#      (a list address -> mlmmj-receive) and `listserv` (listserv@HOST -> the command handler).  main.cf and master.cf
#      are backed up first (BAK/ beside them, the 3 newest kept); `postfix check` must pass or the old files are put back;
#   5. Dovecot: ONE global Sieve script that files mail with a List-Id of NAME.DOMAIN into Lists/NAME (and stops, so the
#      members' own filters, a vacation reply included, do not answer list mail), declared in a drop-in
#      /etc/dovecot/conf.d/96-lists-setup-sieve.conf (Dovecot 2.3 and 2.4 syntax), compiled with sievec, checked with
#      doveconf (the old state is put back if it is rejected);
#   6. a cron entry for mlmmj-maintd (digests, bounces, retries) every 10 minutes;
#   7. makes the lists named with --list NAME[:description] (listctl create).
#
# No port is opened: list mail uses the SMTP the box already accepts from the LAN.  Re-runnable.  Linux only.
#
# Usage:
#   sudo ./configure-lists.sh [options]
#
# Options:
#   --domain D          list addresses are NAME@D (default: Postfix's myhostname, as the box's own users' are)
#   --list SPEC         make a list now: NAME or NAME:description (repeatable)
#   --owner ADDR        the owner of the lists made now (default postmaster@DOMAIN)
#   --spool DIR         mlmmj's spool (default /var/spool/mlmmj)
#   --prefix NAME       the IMAP folder the lists are filed under (default Lists; tvmail's [lists] prefix)
#   --separator C       the folder separator of the mail store (default: what doveconf says, else /)
#   --no-install        do not install packages or create the mlmmj user (mlmmj is installed some other way; tests)
#   --no-reload         do not reload or restart Postfix and Dovecot
#   --print-config WHAT print one thing and exit - no root, nothing changed: lists.conf, postfix-main, postfix-master,
#                       sieve-script, dovecot-dropin (with --dovecot-version 2.3|2.4), cron
#   --dovecot-version V with --print-config dovecot-dropin: 2.3 or 2.4
#   -h | --help         show this header
#
set -euo pipefail
set -E
trap 'rc=$?; printf "ERROR: configure-lists.sh stopped at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
L=$(CDPATH= cd -- "$here/.." && pwd)
. "$here/../../mail-setup/lib/common.sh"
# tests set LISTS_SETUP_SUDO= (empty) so nothing ever escalates
[ "${LISTS_SETUP_SUDO+set}" = set ] && SUDO="$LISTS_SETUP_SUDO"

PC="${LISTS_SETUP_POSTCONF:-postconf}"
PF="${LISTS_SETUP_POSTFIX:-postfix}"
DC="${LISTS_SETUP_DOVECONF:-doveconf}"
DV="${LISTS_SETUP_DOVECOT:-dovecot}"
SIEVEC="${LISTS_SETUP_SIEVEC:-sievec}"
CONFDIR="${LISTS_SETUP_CONFDIR:-/etc/lists-setup}"
BINDIR="${LISTS_SETUP_BINDIR:-/usr/local/bin}"
LIBDIR="${LISTS_SETUP_LIBDIR:-/usr/local/lib/lists-setup}"
DOVECOT_ETC="${LISTS_SETUP_DOVECOT_ETC:-/etc/dovecot}"
CRON_DIR="${LISTS_SETUP_CRON:-/etc/cron.d}"
SPOOL="${LISTS_SETUP_SPOOL:-/var/spool/mlmmj}"
MLMMJ_USER=mlmmj

DOMAIN=""; OWNER=""; PREFIX=Lists; SEP=""; INSTALL=1; RELOAD=1
LISTS=(); PRINT=""; DVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)         DOMAIN="${2:?}"; shift 2 ;;
    --list)           LISTS+=("${2:?}"); shift 2 ;;
    --owner)          OWNER="${2:?}"; shift 2 ;;
    --spool)          SPOOL="${2:?}"; shift 2 ;;
    --prefix)         PREFIX="${2:?}"; shift 2 ;;
    --separator)      SEP="${2:?}"; shift 2 ;;
    --no-install)     INSTALL=0; shift ;;
    --no-reload)      RELOAD=0; shift ;;
    --print-config)   PRINT="${2:?}"; shift 2 ;;
    --dovecot-version) DVER="${2:?}"; shift 2 ;;
    -h|--help)        usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$DOMAIN" ]; then
  DOMAIN=$($PC -h myhostname 2>/dev/null || true)
  [ -n "$DOMAIN" ] || DOMAIN=$(hostname -f 2>/dev/null || hostname)
fi
case "$DOMAIN" in *[!A-Za-z0-9.-]*|'') die "--domain: '$DOMAIN' is not a domain name" ;; esac
case "$PREFIX" in *[!A-Za-z0-9._-]*|'') die "--prefix: letters, digits . _ - only" ;; esac
case "$SPOOL" in /*) ;; *) die "--spool: an absolute path" ;; esac
case "$SEP" in ''|/|.) ;; *) die "--separator: / or ." ;; esac
[ -n "$OWNER" ] || OWNER="postmaster@$DOMAIN"
case "$OWNER" in *@*) ;; *) die "--owner: an address" ;; esac
for spec in ${LISTS[@]+"${LISTS[@]}"}; do
  n=${spec%%:*}
  case "$n" in *[!a-z0-9._-]*|''|-*) die "--list $spec: a list name is lowercase letters, digits, . _ -" ;; esac
done

MLMMJ_BIN="${LISTS_SETUP_MLMMJ_BIN:-}"
if [ -z "$MLMMJ_BIN" ]; then
  MLMMJ_BIN=$(dirname "$(command -v mlmmj-receive 2>/dev/null || echo /usr/bin/mlmmj-receive)")
fi

# --------------------------------------------------------------------------
# what gets written
# --------------------------------------------------------------------------
print_lists_conf() {
  cat <<EOF
# lists.conf - generated $(date) by lists-setup's configure-lists.sh.  Re-run that script rather than editing this by hand.
# Read by listserv and listctl; every key can be overridden by an environment variable LISTS_SETUP_KEY.
DOMAIN = $DOMAIN
ADDRESS = listserv@$DOMAIN
SPOOL = $SPOOL
MLMMJ_BIN = $MLMMJ_BIN
MLMMJ_USER = $MLMMJ_USER
SENDMAIL = /usr/sbin/sendmail
POSTMAP = postmap
POSTFIX = postfix
REMOVED = /var/backups/lists-setup
EOF
}

# the two pipe services of master.cf, one line each (postconf -M takes the whole line)
MLMMJ_LINE() { printf 'mlmmj unix - n n - - pipe flags=ORhu user=%s argv=%s/mlmmj-receive -F -L %s/$nexthop' "$MLMMJ_USER" "$MLMMJ_BIN" "$SPOOL"; }
LISTSERV_LINE() { printf 'listserv unix - n n - - pipe flags=R user=%s argv=%s/listserv --sender=${sender}' "$MLMMJ_USER" "$BINDIR"; }

print_postfix_main() {
  cat <<EOF
# main.cf: added or kept by configure-lists.sh (virtual_alias_maps and transport_maps keep what they had)
recipient_delimiter = +
propagate_unmatched_extensions = (must include virtual; today's value plus virtual)
virtual_alias_maps = (today's value), hash:$SPOOL/virtual
transport_maps = (today's value), hash:$SPOOL/transport
local_recipient_maps = (today's value, if it is not empty), hash:$SPOOL/virtual
mlmmj_destination_recipient_limit = 1
listserv_destination_recipient_limit = 1
EOF
}

print_postfix_master() {
  echo "# master.cf: two pipe services (the second line of each is the argv)"
  echo "$(MLMMJ_LINE)"
  echo "$(LISTSERV_LINE)"
}

# the Sieve rule: mail with List-Id <NAME.DOMAIN> goes to PREFIX/NAME and nothing else touches it
print_sieve_script() {
  local dre=${DOMAIN//./\\\\.}
  cat <<EOF
# 90-lists.sieve - generated $(date) by lists-setup's configure-lists.sh (global, runs before every user's own script).
# Mail of a list this server runs has the header  List-Id: <NAME.$DOMAIN>  (listctl puts it in the list's custom headers).
# It is filed into the member's folder $PREFIX${SEP:-/}NAME, created on the first mail, and then nothing else runs: the
# member's own filters - a vacation reply above all - must not answer list mail.
require ["fileinto", "mailbox", "regex", "variables"];

if header :regex "List-Id" "<([a-z0-9._-]+)\\\\.$dre>" {
    fileinto :create "$PREFIX${SEP:-/}\${1}";
    stop;
}
EOF
}

print_dovecot_dropin() {
  local ver=$1
  cat <<EOF
# 96-lists-setup-sieve.conf - generated $(date) by lists-setup's configure-lists.sh (Dovecot $ver).
# Re-run that script rather than editing this by hand.  A global Sieve script, run before each user's own, files
# mailing-list mail into Lists/NAME (see $DOVECOT_ETC/sieve-before.d/90-lists.sieve).

EOF
  case "$ver" in
    2.3*) cat <<EOF
plugin {
  sieve_before = $DOVECOT_ETC/sieve-before.d
}
EOF
    ;;
    *) cat <<EOF
sieve_script lists {
  type = before
  driver = file
  path = $DOVECOT_ETC/sieve-before.d
}
EOF
    ;;
  esac
}

print_cron() {
  cat <<EOF
# lists-setup: mlmmj's housekeeping (digests, bounces, resending, stale requests) for every list, every 10 minutes
*/10 * * * * $MLMMJ_USER $MLMMJ_BIN/mlmmj-maintd -F -d $SPOOL
EOF
}

if [ -n "$PRINT" ]; then
  [ -n "$SEP" ] || SEP=/
  case "$PRINT" in
    lists.conf)      print_lists_conf ;;
    postfix-main)    print_postfix_main ;;
    postfix-master)  print_postfix_master ;;
    sieve-script)    print_sieve_script ;;
    dovecot-dropin)  [ -n "$DVER" ] || die "--print-config dovecot-dropin needs --dovecot-version 2.3 or 2.4"
                     case "$DVER" in 2.3*|2.4*) ;; *) die "--dovecot-version: 2.3 or 2.4" ;; esac
                     print_dovecot_dropin "$DVER" ;;
    cron)            print_cron ;;
    *) die "--print-config: lists.conf, postfix-main, postfix-master, sieve-script, dovecot-dropin or cron" ;;
  esac
  exit 0
fi

# --------------------------------------------------------------------------
# the box
# --------------------------------------------------------------------------
# (the tests run on any OS and as any user, with fake postconf / doveconf: they set LISTS_SETUP_ANY_OS and LISTS_SETUP_SUDO=)
[ "$IS_LINUX" = 1 ] || [ -n "${LISTS_SETUP_ANY_OS:-}" ] || die "Linux only - run this on the mail master (Postfix + Dovecot)"
if [ "${LISTS_SETUP_SUDO+set}" != set ] && [ "$(id -u)" != 0 ] && [ -z "$SUDO" ]; then die "run as root (no sudo found)"; fi
step "mailing lists for the LAN: @$DOMAIN (spool $SPOOL, folders $PREFIX/)"

# 1. what this builds on ------------------------------------------------------------
command -v "$PC" >/dev/null 2>&1 || die "Postfix (postconf) is not installed here: run mail-setup's configure-sendmail-relay.sh first"
command -v "$DV" >/dev/null 2>&1 || die "Dovecot is not installed here: run mail-setup's configure-dovecot.sh first"
command -v "$SIEVEC" >/dev/null 2>&1 || die "Dovecot's Sieve (Pigeonhole) is not installed: run mail-setup's configure-sieve.sh first"
case "$($PC -h mailbox_command 2>/dev/null)" in
  *dovecot-lda*) ;;
  *) die "Postfix does not deliver through dovecot-lda (mailbox_command), so Sieve would not run: run mail-setup's configure-sieve.sh first" ;;
esac
DOVER="${LISTS_SETUP_DOVECOT_VERSION:-$($DV --version 2>/dev/null | awk '{print $1}')}"
case "$DOVER" in 2.3*|2.4*) ;; *) die "unsupported Dovecot version '${DOVER:-?}' (need 2.3 or 2.4)" ;; esac
log "postfix     : $($PC -h mail_version 2>/dev/null || echo ok)"
log "dovecot     : $DOVER"
if [ -z "$SEP" ]; then
  SEP=$($DC -n 2>/dev/null | awk -F= '/^[[:space:]]*separator[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' || true)
  [ -n "$SEP" ] || SEP=/
fi
case "$SEP" in /|.) ;; *) die "--separator: / or ." ;; esac
log "folders     : $PREFIX$SEP<list>"

# backup_keep3 FILE: BAK/ beside FILE keeps copies of what we replace; only the 3 newest stay
backup_keep3() {
  local f="$1" d b
  [ -e "$f" ] || return 0
  d=$(dirname "$f")/BAK; b=$(basename "$f")
  $SUDO mkdir -p "$d"
  $SUDO cp -p "$f" "$d/$b.bak-$(date +%Y%m%d-%H%M%S)"
  # shellcheck disable=SC2012
  ls -1t "$d/$b".bak-* 2>/dev/null | tail -n +4 | while IFS= read -r old; do $SUDO rm -f "$old"; done
}
# put_file DEST MODE SRC: install SRC as DEST if it differs (backed up first); echoes 1 when it changed
put_file() {
  local dest="$1" mode="$2" src="$3"
  if $SUDO cmp -s "$src" "$dest" 2>/dev/null; then log "$dest: unchanged"; return 1; fi
  backup_keep3 "$dest"
  $SUDO install -d -m 755 "$(dirname "$dest")"
  $SUDO install -m "$mode" "$src" "$dest"
  log "$dest: written"
  return 0
}

# 2. mlmmj and its user --------------------------------------------------------------
if [ "$INSTALL" = 1 ]; then
  if ! command -v mlmmj-receive >/dev/null 2>&1; then
    [ "$PKG" = apt ] || die "this installs mlmmj with apt (Debian, Ubuntu, Raspberry Pi OS); install it by hand and re-run with --no-install"
    pkg_install mlmmj
    log "package     : mlmmj installed"
  else
    log "package     : mlmmj is installed"
  fi
  MLMMJ_BIN=$(dirname "$(command -v mlmmj-receive)")
  if ! getent passwd "$MLMMJ_USER" >/dev/null 2>&1; then
    $SUDO useradd --system --home-dir "$SPOOL" --shell /usr/sbin/nologin --user-group "$MLMMJ_USER"
    log "user        : $MLMMJ_USER created"
  fi
fi
$SUDO install -d -m 750 -o "$MLMMJ_USER" -g "$MLMMJ_USER" "$SPOOL" 2>/dev/null || $SUDO install -d -m 750 "$SPOOL"

# 3. listserv, listctl, lists.conf --------------------------------------------------
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
put_file "$BINDIR/listserv" 755 "$L/bin/listserv" || true
put_file "$BINDIR/listctl" 755 "$L/bin/listctl" || true
put_file "$BINDIR/list-import" 755 "$L/bin/list-import" || true
put_file "$LIBDIR/listlib.py" 644 "$L/bin/listlib.py" || true
print_lists_conf > "$tmp/lists.conf"
# the generated date makes every run "differ": compare without the second line
if ! diff <(sed 1,2d "$tmp/lists.conf") <(sed 1,2d "$CONFDIR/lists.conf" 2>/dev/null) >/dev/null 2>&1; then
  put_file "$CONFDIR/lists.conf" 644 "$tmp/lists.conf" || true
else
  log "$CONFDIR/lists.conf: unchanged"
fi
LISTCTL=("$BINDIR/listctl" --conf "$CONFDIR/lists.conf")
[ "$INSTALL" = 1 ] || LISTCTL=("$L/bin/listctl" --conf "$CONFDIR/lists.conf")

# 4. Postfix --------------------------------------------------------------------------
# the tables first (postmap'ed), so main.cf never names a table that is not there
"${LISTCTL[@]}" --no-postfix sync >/dev/null
for t in virtual transport; do $SUDO postmap "$SPOOL/$t" 2>/dev/null || true; done
MAINCF=$($PC -h config_directory 2>/dev/null || echo /etc/postfix)/main.cf
MASTERCF=$(dirname "$MAINCF")/master.cf
backup_keep3 "$MAINCF"; backup_keep3 "$MASTERCF"
BAKMAIN=$(ls -1t "$(dirname "$MAINCF")"/BAK/main.cf.bak-* 2>/dev/null | head -1 || true)
BAKMASTER=$(ls -1t "$(dirname "$MASTERCF")"/BAK/master.cf.bak-* 2>/dev/null | head -1 || true)

delim=$($PC -h recipient_delimiter 2>/dev/null || true)
case "$delim" in
  '') $SUDO $PC -e "recipient_delimiter=+" ;;
  +)  ;;
  *)  die "recipient_delimiter is '$delim': mlmmj's list addresses use '+' (set it to + or give each list a delimiter file)" ;;
esac
unmatched=$($PC -h propagate_unmatched_extensions 2>/dev/null || true)
case ",$(echo "$unmatched" | tr -d ' ')," in
  *,virtual,*) ;;
  *) $SUDO $PC -e "propagate_unmatched_extensions=${unmatched:+$unmatched, }virtual" ;;
esac
add_map() {   # add_map PARAM hash:FILE: append to a map list unless it is there
  local cur; cur=$($PC -h "$1" 2>/dev/null || true)
  case " $cur," in
    *" $2,"*|*" $2") log "$1: has $2" ;;
    *) $SUDO $PC -e "$1=${cur:+$cur, }$2"; log "$1: + $2" ;;
  esac
}
add_map virtual_alias_maps "hash:$SPOOL/virtual"
add_map transport_maps "hash:$SPOOL/transport"
# Postfix's SMTP server checks a recipient in a LOCAL domain (cpbee.cmnet is one) against local_recipient_maps, before any
# virtual alias is looked at: without this a mail to a list address - from tvmail, or mlmmj's own bounces - is refused
# "User unknown".  The virtual table's left-hand side is every list address (and listserv@); an empty
# local_recipient_maps means "accept everything" and is left alone.
[ -z "$($PC -h local_recipient_maps 2>/dev/null)" ] || add_map local_recipient_maps "hash:$SPOOL/virtual"
$SUDO $PC -e "mlmmj_destination_recipient_limit=1" "listserv_destination_recipient_limit=1"
set_service() {   # set_service SERVICE/TYPE "the whole master.cf line"
  local cur; cur=$($PC -M "$1" 2>/dev/null | tr -s ' \t' ' ' || true)
  if [ "$cur" = "$(echo "$2" | tr -s ' \t' ' ')" ]; then log "master.cf: $1 unchanged"
  else $SUDO $PC -M "$1=$2"; log "master.cf: $1 set"; fi
}
set_service mlmmj/unix "$(MLMMJ_LINE)"
set_service listserv/unix "$(LISTSERV_LINE)"
if ! err=$($SUDO $PF check 2>&1); then
  [ -n "$BAKMAIN" ] && $SUDO cp -p "$BAKMAIN" "$MAINCF"
  [ -n "$BAKMASTER" ] && $SUDO cp -p "$BAKMASTER" "$MASTERCF"
  die "postfix check rejected the new configuration (the old main.cf and master.cf are back):
$err"
fi
[ "$RELOAD" = 0 ] || $SUDO $PF reload >/dev/null 2>&1 || warn "postfix reload failed: reload it yourself"
log "postfix     : configured ($MAINCF, $MASTERCF)"

# 5. Dovecot ---------------------------------------------------------------------------
SIEVE_DIR="$DOVECOT_ETC/sieve-before.d"
DROPIN="$DOVECOT_ETC/conf.d/96-lists-setup-sieve.conf"
print_sieve_script > "$tmp/90-lists.sieve"
print_dovecot_dropin "$DOVER" > "$tmp/dropin.conf"
sieve_changed=0
if ! diff <(sed 1d "$tmp/90-lists.sieve") <(sed 1d "$SIEVE_DIR/90-lists.sieve" 2>/dev/null) >/dev/null 2>&1; then
  put_file "$SIEVE_DIR/90-lists.sieve" 644 "$tmp/90-lists.sieve" && sieve_changed=1 || true
else log "$SIEVE_DIR/90-lists.sieve: unchanged"; fi
$SUDO "$SIEVEC" "$SIEVE_DIR/90-lists.sieve" 2>/dev/null || warn "sievec did not compile $SIEVE_DIR/90-lists.sieve (Dovecot compiles it itself when it runs)"
dropin_old=""
if $SUDO test -e "$DROPIN"; then dropin_old="$tmp/dropin.old"; $SUDO cp -p "$DROPIN" "$dropin_old"; fi
if ! diff <(sed 1d "$tmp/dropin.conf") <(sed 1d "$DROPIN" 2>/dev/null) >/dev/null 2>&1; then
  put_file "$DROPIN" 644 "$tmp/dropin.conf" || true
  if ! err=$($SUDO $DC -n 2>&1 >/dev/null); then
    if [ -n "$dropin_old" ]; then $SUDO cp -p "$dropin_old" "$DROPIN"; else $SUDO rm -f "$DROPIN"; fi
    die "doveconf rejected the new drop-in (the old state is back):
$err"
  fi
  [ "$RELOAD" = 0 ] || { $SUDO systemctl reload dovecot >/dev/null 2>&1 || warn "could not reload dovecot: reload it yourself"; }
else
  log "$DROPIN: unchanged"
fi

# 6. mlmmj's housekeeping -----------------------------------------------------------------
print_cron > "$tmp/cron"
if ! diff <(sed 1d "$tmp/cron") <(sed 1d "$CRON_DIR/lists-setup" 2>/dev/null) >/dev/null 2>&1; then
  put_file "$CRON_DIR/lists-setup" 644 "$tmp/cron" || true
else log "$CRON_DIR/lists-setup: unchanged"; fi

# 7. the lists asked for -------------------------------------------------------------------
for spec in ${LISTS[@]+"${LISTS[@]}"}; do
  n=${spec%%:*}; d=""; case "$spec" in *:*) d=${spec#*:} ;; esac
  if "${LISTCTL[@]}" show "$n" >/dev/null 2>&1; then log "list        : $n exists"
  else "${LISTCTL[@]}" create "$n" ${d:+--description "$d"} --owner "$OWNER" | sed 's/^/  list        : /'; fi
done

echo
log "done.  Make a list:   sudo listctl create NAME --description 'what it is'"
log "A member joins with a mail to listserv@$DOMAIN (SUBSCRIBE NAME); in tvmail: Message > Lists > Available lists."
log "On each client:  lists-setup/scripts/configure-tvmail-lists.sh --address listserv@$DOMAIN"
