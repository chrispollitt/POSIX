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
# Plus-address routing (one shared mailbox cwp@u-l.ca for chris, miche, ...):
#
#   --imap  (use this on cPanel-style hosts)  cPanel/Dovecot files mail for
#     cwp+chris@u-l.ca in an IMAP FOLDER named "chris" (INBOX.chris to IMAP
#     clients; created on first delivery), NOT in the inbox, so POP3 never sees
#     it.  With --plus-base cwp@u-l.ca --plus-users chris,miche this script
#     writes one getmailrc per folder, each in its own getmaildir
#     (<getmaildir>/plus-chris/, ...) so their seen-mail state stays apart:
#         INBOX        -> --local-user
#         INBOX.chris  -> chris        INBOX.miche -> miche
#     The folder name is the routing key; no header parsing.  The mail-pull
#     wrapper runs getmail once per rc; a missing tag folder (no tagged mail
#     yet) is reported but doesn't fail the run.  --plus-prefix sets the IMAP
#     prefix+separator (default "INBOX."; "INBOX/" or "" on other servers) -
#     tests/live/check-plus-addressing.py shows what your host uses.  The tag's
#     case matters to Dovecot: only lower-case tags land in these folders.
#     --plus-headers additionally routes tagged mail found in INBOX by header.
#
#   POP3 (default)  POP only sees the inbox, so this suits hosts that deliver
#     tagged mail INTO the inbox.  The [destination] becomes a getmail
#     MultiGuesser: a message whose Delivered-To / Envelope-To / To / Cc
#     (getmail checks them in that order, the first header that has addresses
#     wins) names cwp+chris@u-l.ca goes to chris, cwp+miche@... to miche,
#     anything else to --local-user.  (MultiSorter would need a multidrop
#     retriever and an envelope-recipient header; MultiGuesser works with the
#     plain retriever.)  A message addressed to several tags is delivered to
#     each of them.  On a cPanel-style host this finds nothing: use --imap.
#
# Run it as root or a service account so it can deliver for every user, e.g.
#   sudo ./configure-getmail.sh --imap --plus-base cwp@u-l.ca \
#        --plus-users chris,miche --local-user chris
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
#   --plus-prefix P     with --imap: the tag folders are P<user>   (default INBOX.)
#   --plus-headers      with --imap: also route tagged mail in INBOX by header
#   --delete            delete messages from the server after delivery
#   --timer N           systemd --user timer: pull every N minutes
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
PLUS_PREFIX="INBOX."
PLUS_HEADERS=0
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
    --plus-prefix) PLUS_PREFIX="${2-}"; [ $# -ge 2 ] || die "--plus-prefix needs a value (\"\" for none)"; shift 2 ;;
    --plus-headers) PLUS_HEADERS=1; shift ;;
    --delete)    KEEP=0; shift ;;
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
  case "$PLUS_PREFIX" in
    *[!A-Za-z0-9._/-]*) die "--plus-prefix '$PLUS_PREFIX': use letters, digits and . _ / - only" ;;
  esac
elif [ "$PLUS_HEADERS" = 1 ]; then
  die "--plus-headers needs --plus-base and --plus-users"
fi
# folders (IMAP) or headers (POP3) pick the user; the guesser needs the headers
PLUS_FOLDERS=0; DEST_GUESS=0
if [ -n "$PLUS_LIST" ]; then
  if [ "$PROTO" = imap ]; then PLUS_FOLDERS=1; DEST_GUESS=$PLUS_HEADERS
  else DEST_GUESS=1; fi
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
if [ "$PLUS_FOLDERS" = 1 ]; then
  log "plus folders: $(for u in $PLUS_LIST; do printf '%s%s -> %s;  ' "$PLUS_PREFIX" "$u" "$u"; done)INBOX -> ${LOCAL_USER}"
  [ "$DEST_GUESS" = 0 ] || log "plus headers: tagged mail found in INBOX is also routed by header"
elif [ -n "$PLUS_LIST" ]; then
  log "plus routing: ${PLUS_BASE%@*}+{${PLUS_LIST# }}@${PLUS_BASE#*@} -> that user by header (else ${LOCAL_USER})"
  warn "POP3 only sees the inbox: a host that files cwp+TAG@ mail in a TAG folder (cPanel) needs --imap"
fi
log "server copy : $( [ "$KEEP" = 1 ] && echo 'KEEP (getmail remembers seen mail)' || echo 'DELETE after delivery' )"

# regex-escape a literal for a getmail `locals` pattern
re_esc() { printf '%s' "$1" | sed 's/[][+*?(){}|^$.\\]/\\&/g'; }

# the [destination] section(s): one MDA, or a MultiGuesser fanning out by tag
destinations() {
  if [ "$DEST_GUESS" != 1 ]; then
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

# write_rc FILE MAILBOX DESTFN - one getmailrc: the retriever (IMAP: MAILBOX),
# then whatever DESTFN prints for [destination]
write_rc() {
  backup "$1"
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
$( [ "$PROTO" = imap ] && echo "mailboxes = (\"$2\",)" )

EOF
"$3"
cat <<EOF

[options]
read_all = false
delete = $( [ "$KEEP" = 1 ] && echo false || echo true )
verbose = 1
message_log = ${STATE}/getmail.log
EOF
  } > "$1"
  chmod 600 "$1"
  log "wrote $1"
}

write_rc "$RC" INBOX destinations

# IMAP tag folders: <prefix><user> -> that user.  Each rc gets its own
# getmaildir so its seen-mail (oldmail) state can't be mixed up with INBOX's.
plain_dest() {
  printf '[destination]\ntype = MDA_external\npath = %s\narguments = ("-oi", "--", "%s")\n' "$MDA" "$DEST_USER"
}
if [ "$PLUS_FOLDERS" = 1 ]; then
  for u in $PLUS_LIST; do
    install -d -m 0700 "$GMDIR/plus-$u"
    DEST_USER="$u"
    write_rc "$GMDIR/plus-$u/getmailrc" "${PLUS_PREFIX}$u" plain_dest
  done
fi

GM_HEAD="v=\"\"
for a in \"\$@\"; do
  case \"\$a\" in
    -v|--verbose) v=-v ;;
    -n|--dry-run) echo 'mail-pull: getmail has no dry run (use pop-pull -n)' >&2; exit 2 ;;
  esac
done"
if [ "$PLUS_FOLDERS" = 1 ]; then
  # INBOX decides the exit status; a tag folder only exists after its first
  # tagged mail, so a failing folder run is reported, not fatal
  GM_BODY="rc=0
\"$GETMAIL\" --getmaildir \"$GMDIR\" --rcfile getmailrc \$v || rc=\$?"
  for u in $PLUS_LIST; do
    GM_BODY="$GM_BODY
\"$GETMAIL\" --getmaildir \"$GMDIR/plus-$u\" --rcfile getmailrc \$v || echo 'mail-pull: folder ${PLUS_PREFIX}$u: getmail failed (not created yet? the first ${PLUS_BASE%@*}+$u@ mail creates it)' >&2"
  done
  GM_BODY="$GM_BODY
exit \$rc"
else
  GM_BODY="exec \"$GETMAIL\" --getmaildir \"$GMDIR\" --rcfile getmailrc \$v"
fi
write_mail_pull "$BIN" "$GM_HEAD
$GM_BODY"

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
