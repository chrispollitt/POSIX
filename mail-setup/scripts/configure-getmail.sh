#!/usr/bin/env bash
#
# configure-getmail.sh
#
# The getmail alternative to configure-mail-pull.sh: fetch remote mail into
# the local mailbox with getmail (getmail6), POP3S or IMAPS.  Portable
# wherever getmail6 installs (distro package, or pip on Cygwin/macOS).
#
#   * installs getmail6 if it's missing (apt/dnf/pacman, else pip --user)
#   * writes <getmaildir>/getmailrc: one retriever -> MDA_external sendmail,
#     so every message lands in /var/mail/<user> exactly as pop-pull's do
#   * the password is never in getmailrc - password_command runs bin/sasl-pass,
#     which reads it LIVE from Postfix's /etc/postfix/sasl_passwd (same file
#     configure-sendmail-relay.sh wrote, same one pop-pull reads)
#   * KEEPs mail on the server by default (getmail remembers what it has
#     seen in its oldmail-* file); --delete removes it after delivery
#   * (re)writes the mail-pull wrapper to run getmail - see lib/pull.sh
#
# Plus-address routing: with  --plus-base cwp@u-l.ca --plus-users chris,miche
# the [destination] becomes a getmail MultiGuesser: a message whose
# Delivered-To / Envelope-To / To / Cc (getmail checks them in that order, the
# first header that has addresses wins) names cwp+chris@u-l.ca goes to chris,
# cwp+miche@... to miche, anything else to --local-user.  (MultiSorter would
# need a multidrop retriever and an envelope-recipient header; MultiGuesser
# works with the plain retriever.)  Unlike pop-pull, a message addressed to
# several tags is delivered to each of them.  Run it as root or a service
# account so it can deliver for every user, e.g.
#   sudo ./configure-getmail.sh --plus-base cwp@u-l.ca --plus-users chris,miche \
#        --local-user chris
#
# Usage:
#   ./configure-getmail.sh --relay-file /path/to/smtp-relay.txt [options]
#
# Options:
#   --relay-file FILE   cPanel-style config text -> Incoming Server / Username.
#   --user NAME         remote mailbox login          (default: from file)
#   --imap              IMAPS:993 (INBOX) instead of POP3S:995
#   --pwfile PATH       password file (default /etc/postfix/sasl_passwd)
#   --local-user NAME   deliver into this account     (default: you)
#   --plus-base ADDR    plain shared address (cwp@u-l.ca) for tag routing
#   --plus-users LIST   comma-separated local users that get cwp+USER@... mail
#   --delete            delete messages from the server after delivery
#   --timer N          systemd --user timer: pull every N minutes
#   --test              run one fetch right after configuring
#   -y, --yes           install getmail without asking
#   -h | --help         show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../lib/common.sh"
. "$here/../lib/pull.sh"

RELAY_FILE=""
REMOTE_USER=""
PROTO=pop3
PWFILE="/etc/postfix/sasl_passwd"
LOCAL_USER="$(id -un)"
KEEP=1
TIMER_MIN=0
PLUS_BASE=""
PLUS_USERS=""
DO_TEST=0
ASSUME="${ASSUME:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --relay-file) RELAY_FILE="${2:?}"; shift 2 ;;
    --user)       REMOTE_USER="${2:?}"; shift 2 ;;
    --imap)       PROTO=imap; shift ;;
    --pwfile)     PWFILE="${2:?}"; shift 2 ;;
    --local-user) LOCAL_USER="${2:?}"; shift 2 ;;
    --plus-base)  PLUS_BASE="${2:?}"; shift 2 ;;
    --plus-users) PLUS_USERS="${2:?}"; shift 2 ;;
    --delete)     KEEP=0; shift ;;
    --timer)      TIMER_MIN="${2:?}"; shift 2 ;;
    --test)       DO_TEST=1; shift ;;
    -y|--yes)     ASSUME=yes; shift ;;
    -h|--help)    usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PLUS_LIST=""
if [ -n "$PLUS_BASE$PLUS_USERS" ]; then
  [ -n "$PLUS_BASE" ] && [ -n "$PLUS_USERS" ] || die "--plus-base and --plus-users go together"
  case "$PLUS_BASE" in
    *+*|*[[:space:]]*|*@*@*|@*|*@) die "--plus-base must be a plain address like cwp@u-l.ca, not '$PLUS_BASE'" ;;
    *@*) : ;;
    *)   die "--plus-base must be a plain address like cwp@u-l.ca, not '$PLUS_BASE'" ;;
  esac
  for u in $(echo "$PLUS_USERS" | tr ',' ' '); do
    case "$u" in
      *[!a-z0-9._-]*|-*) die "--plus-users: '$u' isn't a plain lower-case login name" ;;
    esac
    PLUS_LIST="$PLUS_LIST $u"
  done
fi

PY="$(find_python || true)"
[ -n "$PY" ] || die "need a python3 (>= 3.6) with ssl"

MDA="$(find_mda || true)"
[ -n "$MDA" ] || die "no sendmail MDA found - run configure-sendmail-relay.sh first"

# --------------------------------------------------------------------------
# getmail itself
# --------------------------------------------------------------------------
# MAIL_SETUP_GETMAIL= (set but empty) pretends there's none - for the tests
GETMAIL="${MAIL_SETUP_GETMAIL-$(command -v getmail 2>/dev/null || true)}"
if [ -z "$GETMAIL" ]; then
  log "getmail: not found"
  ask "Install getmail6 now?" || die "getmail is required - or use configure-mail-pull.sh (pop-pull) instead"
  case "$PKG" in
    apt)    pkg_install getmail6 ;;
    dnf|yum) pkg_install getmail6 || pkg_install getmail ;;
    pacman) pkg_install getmail6 || true ;;
    *)      : ;;
  esac
  GETMAIL="$(command -v getmail 2>/dev/null || true)"
  if [ -z "$GETMAIL" ]; then
    log "no distro package - trying pip:  $PY -m pip install --user getmail6"
    "$PY" -m pip install --user getmail6 || die "pip install failed - install getmail6 by hand (https://getmail6.org)"
    hash -r
    GETMAIL="$(command -v getmail 2>/dev/null || true)"
    [ -n "$GETMAIL" ] || GETMAIL="$("$PY" -c 'import site;print(site.USER_BASE)')/bin/getmail"
    [ -x "$GETMAIL" ] || die "getmail installed but not found - is ~/.local/bin on \$PATH?"
  fi
fi
log "getmail     : $GETMAIL ($("$GETMAIL" --version 2>/dev/null | head -1 || echo '?'))"

# --------------------------------------------------------------------------
# settings
# --------------------------------------------------------------------------
IN_SERVER=""
if [ -n "$RELAY_FILE" ] && [ -f "$RELAY_FILE" ]; then
  IN_SERVER="$(relay_field "$RELAY_FILE" 'Incoming Server')"
  [ -n "$REMOTE_USER" ] || REMOTE_USER="$(relay_field "$RELAY_FILE" Username)"
fi
: "${IN_SERVER:=u-l.ca}"
: "${REMOTE_USER:=cwp@u-l.ca}"

if [ "$PROTO" = imap ]; then RTYPE=SimpleIMAPSSLRetriever; PORT=993
else                         RTYPE=SimplePOP3SSLRetriever; PORT=995; fi

[ -r "$PWFILE" ] || warn "$PWFILE is not readable by $(id -un) - re-run configure-sendmail-relay.sh
  --user $(id -un) (it makes it root:<your group> 0640), or pass --pwfile"
[ -r "$PWFILE" ] && { grep -qF -- " ${REMOTE_USER}:" "$PWFILE" \
  || warn "no line for '${REMOTE_USER}' in $PWFILE - getmail will fail until one exists"; }

BIN="$(user_bindir)"; install -d -m 0755 "$BIN"
SASL="$BIN/sasl-pass"
sed "1s|.*|#!${PY}|" "$here/../bin/sasl-pass" > "$SASL"
chmod 755 "$SASL"
log "installed $SASL"

# ~/.getmail if it's already there (getmail's classic default), else XDG
GMDIR="$HOME/.getmail"; [ -d "$GMDIR" ] || GMDIR="$HOME/.config/getmail"
install -d -m 0700 "$GMDIR"
RC="$GMDIR/getmailrc"
STATE="$HOME/.local/state"; install -d -m 0755 "$STATE"

log "remote      : ${REMOTE_USER} @ ${IN_SERVER}  ${PROTO^^}S:${PORT}"
log "deliver to  : ${LOCAL_USER}  ->  /var/mail/${LOCAL_USER}   (via ${MDA})"
[ -z "$PLUS_LIST" ] || log "plus routing: ${PLUS_BASE%@*}+{${PLUS_LIST# }}@${PLUS_BASE#*@} -> that user (else ${LOCAL_USER})"
log "server copy : $( [ "$KEEP" = 1 ] && echo 'KEEP (getmail remembers seen mail)' || echo 'DELETE after delivery' )"

# regex-escape a literal for a getmail `locals` pattern
re_esc() { printf '%s' "$1" | sed 's/[][+*?(){}|^$.\\]/\\&/g'; }

# the [destination] section(s): one MDA, or a MultiGuesser fanning out by tag
destinations() {
  if [ -z "$PLUS_LIST" ]; then
    cat <<EOF
[destination]
type = MDA_external
path = ${MDA}
arguments = ("-oi", "--", "${LOCAL_USER}")
EOF
    return
  fi
  pl="$(re_esc "${PLUS_BASE%@*}")"; pd="$(re_esc "${PLUS_BASE#*@}")"
  echo "# plus routing: ${PLUS_BASE%@*}+USER@${PLUS_BASE#*@} -> USER, anything else -> ${LOCAL_USER}"
  echo "[destination]"
  echo "type = MultiGuesser"
  echo "default = [dest-default]"
  echo "locals = ("
  for u in $PLUS_LIST; do
    printf '    (r"(?i)^%s\\+%s@%s$", "[dest-%s]"),\n' "$pl" "$(re_esc "$u")" "$pd" "$u"
  done
  echo "  )"
  for u in default $PLUS_LIST; do
    to="$u"; [ "$u" = default ] && to="$LOCAL_USER"
    printf '\n[dest-%s]\ntype = MDA_external\npath = %s\narguments = ("-oi", "--", "%s")\n' "$u" "$MDA" "$to"
  done
}

backup "$RC"
{
cat <<EOF
# getmailrc - generated $(date) by configure-getmail.sh
# No password here: password_command reads it from ${PWFILE}.
[retriever]
type = ${RTYPE}
server = ${IN_SERVER}
port = ${PORT}
username = ${REMOTE_USER}
password_command = ("${SASL}", "--file", "${PWFILE}", "${REMOTE_USER}")
$( [ "$PROTO" = imap ] && echo 'mailboxes = ("INBOX",)' )

EOF
destinations
cat <<EOF

[options]
read_all = false
delete = $( [ "$KEEP" = 1 ] && echo false || echo true )
verbose = 1
message_log = ${STATE}/getmail.log
EOF
} > "$RC"
chmod 600 "$RC"
log "wrote $RC"

write_mail_pull "$BIN" "v=\"\"
for a in \"\$@\"; do
  case \"\$a\" in
    -v|--verbose) v=-v ;;
    -n|--dry-run) echo 'mail-pull: getmail has no dry run (use pop-pull -n)' >&2; exit 2 ;;
  esac
done
exec \"$GETMAIL\" --getmaildir \"$GMDIR\" --rcfile getmailrc \$v"

case ":$PATH:" in
  *":$BIN:"*) : ;;
  *) warn "$BIN is not on \$PATH - add  export PATH=\"$BIN:\$PATH\"  to your shell rc" ;;
esac

install_pull_timer "$TIMER_MIN" "$BIN"

if [ "$DO_TEST" = 1 ]; then
  echo
  log "running one fetch ..."
  before="$(wc -c < "/var/mail/${LOCAL_USER}" 2>/dev/null || echo 0)"
  "$BIN/mail-pull" -v || true
  after="$(wc -c < "/var/mail/${LOCAL_USER}" 2>/dev/null || echo 0)"
  log "mailbox /var/mail/${LOCAL_USER}: ${before} -> ${after} bytes"
fi

echo
log "Done.  Fetch on demand:   mail-pull -v"
log "Config:  $RC      Log:  $STATE/getmail.log"
log "Back to pop-pull any time:  configure-mail-pull.sh"
