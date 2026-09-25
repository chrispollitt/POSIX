#!/usr/bin/env bash
#
# configure-mail-pull.sh
#
# Set up a pull of remote mail (POP3S) into the local mailbox.  Portable:
# Linux (incl. Raspberry Pi / WSL), macOS, the BSDs, and Cygwin.
#
# Installs the small, dependency-free Python puller bin/pop-pull, which:
#   * connects to the incoming server over implicit TLS (port 995)
#   * reads the mailbox password LIVE from Postfix's own /etc/postfix/sasl_passwd
#     (the same file configure-sendmail-relay.sh already wrote)
#   * hands each message to sendmail as a local submission -> /var/mail/<user>
#   * by default KEEPs mail on the server and remembers what it has already
#     fetched (UIDL list in ~/.local/state/mailpull.seen); --delete removes it
#
# Also (re)writes the mail-pull wrapper to run pop-pull - see lib/pull.sh.
# (configure-getmail.sh is the alternative: same job, done by getmail.)
#
# On-demand by default: run 'mail-pull' (or 'pop-pull') when you want mail.
# --timer N installs a systemd --user timer that pulls every N minutes.
#
# Usage:
#   ./configure-mail-pull.sh --relay-file /path/to/smtp-relay.txt [options]
#
# Options:
#   --relay-file FILE   cPanel-style config text -> Incoming Server / Username.
#   --pop-user NAME     remote mailbox login  (default: from file / sasl_passwd)
#   --pwfile PATH       override the password file (default: Postfix's own
#                       /etc/postfix/sasl_passwd, format "[host]:port user:pass").  0600.
#   --local-user NAME   deliver into this account            (default: you)
#   --delete            delete messages from the server after delivery
#   --no-verify         skip TLS certificate verification
#   --timer N           systemd --user timer: pull every N minutes
#   --test              run one fetch right after configuring
#   -h | --help         show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../lib/common.sh"
. "$here/../lib/pull.sh"

RELAY_FILE=""
POP_USER=""
LOCAL_USER="$(id -un)"
KEEP=1
VERIFY=1
DO_TEST=0
PWFILE_OPT=""
TIMER_MIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --relay-file) RELAY_FILE="${2:?}"; shift 2 ;;
    --pop-user)   POP_USER="${2:?}";   shift 2 ;;
    --pwfile)     PWFILE_OPT="${2:?}"; shift 2 ;;
    --local-user) LOCAL_USER="${2:?}"; shift 2 ;;
    --delete)     KEEP=0; shift ;;
    --no-verify)  VERIFY=0; shift ;;
    --test)       DO_TEST=1; shift ;;
    --timer)      TIMER_MIN="${2:?}"; shift 2 ;;
    -h|--help)    usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$OS" in
  Linux|CYGWIN*|MSYS*|MINGW*|Darwin|*BSD|DragonFly|SunOS) : ;;
  *) warn "untested OS - continuing anyway" ;;
esac

PY="$(find_python || true)"
[ -n "$PY" ] && "$PY" -c 'import ssl,poplib' 2>/dev/null \
  || die "need a python3 with ssl+poplib
    Debian/Pi:  sudo apt install python3
    Cygwin:     setup-x86_64.exe -q -P python39"

# local delivery agent (the puller pipes each fetched message to it)
MDA="$(find_mda || true)"
[ -n "$MDA" ] || die "no sendmail MDA found - run configure-sendmail-relay.sh first"

# where the SMTP/POP password lives - Postfix's own sasl_passwd, the same
# file configure-sendmail-relay.sh already wrote (format: "[host]:port user:pass")
PWFILE="${PWFILE_OPT:-/etc/postfix/sasl_passwd}"
[ -r "$PWFILE" ] || warn "$PWFILE is not readable - run configure-sendmail-relay.sh, pass --pwfile, or add one by hand"

# --------------------------------------------------------------------------
# settings
# --------------------------------------------------------------------------
IN_SERVER=""
if [ -n "$RELAY_FILE" ] && [ -f "$RELAY_FILE" ]; then
  IN_SERVER="$(relay_field "$RELAY_FILE" 'Incoming Server')"
  [ -n "$POP_USER" ] || POP_USER="$(relay_field "$RELAY_FILE" Username)"
fi
: "${IN_SERVER:=u-l.ca}"
: "${POP_USER:=cwp@u-l.ca}"

[ -r "$PWFILE" ] && { grep -qF -- " ${POP_USER}:" "$PWFILE" \
  || warn "no line for '${POP_USER}' in $PWFILE - pop-pull will fail until one exists"; }

CA=""
for c in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-bundle.crt \
         /etc/ssl/certs/ca-certificates.crt; do
  [ -f "$c" ] && { CA="$c"; break; }
done
[ "$VERIFY" = 1 ] || CA=""

log "python      : $PY"
log "remote      : ${POP_USER} @ ${IN_SERVER}  POP3S:995"
log "deliver to  : ${LOCAL_USER}  ->  /var/mail/${LOCAL_USER}   (via ${MDA})"
log "server copy : $( [ "$KEEP" = 1 ] && echo 'KEEP + remember seen UIDs' || echo 'DELETE after delivery' )"
log "TLS verify  : $( [ "$VERIFY" = 1 ] && echo "yes (${CA:-system})" || echo 'NO' )"

# --------------------------------------------------------------------------
# ~/.config/mailpull.conf
# --------------------------------------------------------------------------
CFG="$HOME/.config/mailpull.conf"
install -d -m 0755 "$(dirname "$CFG")"
backup "$CFG"
cat > "$CFG" <<EOF
# ~/.config/mailpull.conf - generated $(date) by configure-mail-pull.sh
[mailpull]
server     = ${IN_SERVER}
port       = 995
user       = ${POP_USER}
local_user = ${LOCAL_USER}
keep       = $( [ "$KEEP" = 1 ] && echo true || echo false )
verify     = $( [ "$VERIFY" = 1 ] && echo true || echo false )
cafile     = ${CA}
mda        = ${MDA}
pwfile     = ${PWFILE}
EOF
log "wrote $CFG"

# --------------------------------------------------------------------------
# pop-pull (the puller), pinned to the python found above, + mail-pull
# --------------------------------------------------------------------------
BIN="$(user_bindir)"; install -d -m 0755 "$BIN"
POP="$BIN/pop-pull"
sed "1s|.*|#!${PY}|" "$here/../bin/pop-pull" > "$POP"
chmod 755 "$POP"
log "installed $POP"

# keep the earlier name working too
ln -sf pop-pull "$BIN/pull-mail" 2>/dev/null && log "linked $BIN/pull-mail -> pop-pull" || true

write_mail_pull "$BIN" "exec \"$POP\" \"\$@\""

case ":$PATH:" in
  *":$BIN:"*) : ;;
  *) warn "$BIN is not on \$PATH - add  export PATH=\"$BIN:\$PATH\"  to your shell rc" ;;
esac

install_pull_timer "$TIMER_MIN" "$BIN"

# --------------------------------------------------------------------------
# optional test
# --------------------------------------------------------------------------
if [ "$DO_TEST" = 1 ]; then
  echo
  log "running one fetch ..."
  before="$(wc -c < "/var/mail/${LOCAL_USER}" 2>/dev/null || echo 0)"
  "$POP" -v || true
  after="$(wc -c < "/var/mail/${LOCAL_USER}" 2>/dev/null || echo 0)"
  log "mailbox /var/mail/${LOCAL_USER}: ${before} -> ${after} bytes"
  log "read it with:  mail"
fi

echo
log "Done.  Fetch on demand:   mail-pull -v      (dry run: mail-pull -n -v)"
log "Config:  $CFG      Seen-UID cache:  ~/.local/state/mailpull.seen"
log "Switch keep<->delete or verify: re-run this script with/without --delete / --no-verify"
