#!/usr/bin/env bash
#
# configure-dovecot.sh
#
# Serve the master's mailstore over IMAP with Dovecot, so every client (mail(1),
# tvmail, Thunderbird, ...) reads the same folders: INBOX is /var/mail/<user>
# (where Postfix, pop-pull and getmail all deliver), other folders are mbox
# files in ~/mail.
#
# Linux only (the mail master is a Linux/Pi box).  Installs Dovecot if it's
# missing, then writes ONE drop-in, /etc/dovecot/conf.d/99-mail-setup.conf -
# the distro's own files are never edited.  Handles both config syntaxes
# (Dovecot 2.3 and 2.4).  The drop-in is checked with doveconf before Dovecot
# is reloaded; if the check fails, the previous drop-in is put back.
#
# TLS: the distro package's self-signed cert (IMAPS on 993) is left as is.
#
# Re-runnable.
#
# Usage:
#   sudo ./configure-dovecot.sh [options]
#
# Options:
#   --listen all|local  all interfaces (LAN clients; default) or localhost only
#   --plaintext         allow password login without TLS (plain IMAP on 143
#                       from the LAN, e.g. for mail(1)'s imap:// URLs)
#   --force             replace a mail location that isn't /var/mail + ~/mail
#   --test [USER]       list USER's (default: you) mailboxes afterwards
#   --print VERSION     just print the drop-in for Dovecot VERSION (2.3 / 2.4)
#                       to stdout - no root, no Linux, nothing changed (tests)
#   -h | --help         show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../lib/common.sh"

LISTEN=all
PLAINTEXT=0
FORCE=0
TEST_USER=""
PRINT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --listen)    LISTEN="${2:?}"; shift 2 ;;
    --plaintext) PLAINTEXT=1; shift ;;
    --force)     FORCE=1; shift ;;
    --test)      if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then TEST_USER="$2"; shift 2
                 else TEST_USER="$(id -un)"; shift; fi ;;
    --print)     PRINT="${2:?}"; shift 2 ;;
    -h|--help)   usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$LISTEN" in all|local) : ;; *) die "--listen must be all or local" ;; esac

# dropin SYNTAX(23|24) VERSION -> the 99-mail-setup.conf text on stdout
dropin() {
  if [ "$1" = 23 ]; then
    store='mail_location = mbox:~/mail:INBOX=/var/mail/%u'
    clear='disable_plaintext_auth = no'
  else
    store=$(printf '%s\n' 'mail_driver = mbox' 'mail_path = ~/mail' \
                          'mail_inbox_path = /var/mail/%{user}')
    clear='auth_allow_cleartext = yes'
  fi
  [ "$LISTEN" = all ] && listen='listen = *, ::' || listen='listen = 127.0.0.1, ::1'

cat <<EOF
# 99-mail-setup.conf - generated $(date) by mail-setup's configure-dovecot.sh
# (Dovecot $2).  Re-run that script rather than editing this by hand.

# INBOX = /var/mail/<user> (where Postfix / pop-pull / getmail deliver);
# every other folder is an mbox file in ~/mail.
$store
# lets Dovecot dot-lock mailboxes in the group-writable /var/mail
mail_privileged_group = mail

$listen
$( [ "$PLAINTEXT" = 1 ] && printf '# password login over plain IMAP (143) - LAN only\n%s\n' "$clear" )

# the folders mail clients expect, created + subscribed on first login
namespace inbox {
  inbox = yes
  mailbox Drafts {
    special_use = \\Drafts
    auto = subscribe
  }
  mailbox Sent {
    special_use = \\Sent
    auto = subscribe
  }
  mailbox Trash {
    special_use = \\Trash
    auto = subscribe
  }
  mailbox Junk {
    special_use = \\Junk
    auto = subscribe
  }
  mailbox Archive {
    special_use = \\Archive
    auto = subscribe
  }
}
EOF
}

syntax_of() {   # syntax_of VERSION -> 23 | 24, or fail
  case "$1" in
    2.3*|2.2*) echo 23 ;;
    2.4*|2.5*) echo 24 ;;
    *) return 1 ;;
  esac
}

if [ -n "$PRINT" ]; then
  syn=$(syntax_of "$PRINT") || die "unsupported Dovecot version '$PRINT' (need 2.3 or 2.4)"
  dropin "$syn" "$PRINT"
  exit 0
fi

[ "$IS_LINUX" = 1 ] || die "Linux only - Dovecot serves the master's mailstore, and the
  master is a Linux/Pi box.  Point this machine at it as a client instead."

if [ "$(id -u)" != 0 ] && [ -z "$SUDO" ]; then die "run as root (no sudo found)"; fi

# --------------------------------------------------------------------------
# install
# --------------------------------------------------------------------------
if ! command -v dovecot >/dev/null 2>&1; then
  log "Dovecot not found - installing ..."
  case "$PKG" in
    apt)         pkg_install dovecot-imapd ;;
    dnf|yum|pacman) pkg_install dovecot ;;
    *) die "no known package manager - install Dovecot (IMAP) by hand, then re-run" ;;
  esac
fi
VER="$(dovecot --version 2>/dev/null | awk '{print $1}')"
SYNTAX=$(syntax_of "$VER") || die "unsupported Dovecot version '${VER:-?}' (need 2.3 or 2.4)"
log "dovecot     : $VER"

CONF=/etc/dovecot/dovecot.conf
DROPIN=/etc/dovecot/conf.d/99-mail-setup.conf
$SUDO test -r "$CONF" || die "$CONF not found (Arch ships none) - copy the example config
  from /usr/share/doc/dovecot/example-config/ to /etc/dovecot/ and re-run"
$SUDO grep -Eq '^[[:space:]]*!include[_try]*[[:space:]]+conf\.d/\*\.conf' "$CONF" \
  || die "$CONF doesn't !include conf.d/*.conf - add that line, then re-run"

# --------------------------------------------------------------------------
# don't silently move someone's existing mailstore
# --------------------------------------------------------------------------
if [ "$SYNTAX" = 23 ]; then
  cur="$($SUDO doveconf -h mail_location 2>/dev/null || true)"
  case "$cur" in
    ""|mbox:*INBOX=/var/mail/*) ok=1 ;;
    *) ok=0 ;;
  esac
else
  cur="$($SUDO doveconf -h mail_driver 2>/dev/null || true):$($SUDO doveconf -h mail_inbox_path 2>/dev/null || true)"
  case "$cur" in
    :|mbox:/var/mail/*) ok=1 ;;
    *) ok=0 ;;
  esac
fi
log "mail store  : ${cur:-<unset>}"
if [ "$ok" = 0 ] && [ "$FORCE" = 0 ]; then
  $SUDO test -e "$DROPIN" || die "Dovecot already uses a different mail store ($cur).
  Switching it to /var/mail + ~/mail would hide the mail already there.
  Re-run with --force if that's really what you want."
fi

# --------------------------------------------------------------------------
# the drop-in
# --------------------------------------------------------------------------
tmp=$(mktemp)
dropin "$SYNTAX" "$VER" > "$tmp"

old=""
if $SUDO test -e "$DROPIN"; then
  old="$DROPIN.bak.$(date +%Y%m%d-%H%M%S)"
  $SUDO cp -p "$DROPIN" "$old"
  log "backed up existing $DROPIN"
fi
$SUDO install -m 0644 "$tmp" "$DROPIN"; rm -f "$tmp"
if ! err="$($SUDO doveconf -n 2>&1 >/dev/null)"; then
  if [ -n "$old" ]; then $SUDO cp -p "$old" "$DROPIN"; else $SUDO rm -f "$DROPIN"; fi
  die "doveconf rejected the new config (put the old one back):
$err"
fi
log "wrote $DROPIN  (doveconf: ok)"

# --------------------------------------------------------------------------
# run it
# --------------------------------------------------------------------------
if [ -d /run/systemd/system ]; then
  $SUDO systemctl enable dovecot >/dev/null 2>&1 || true
  $SUDO systemctl reload-or-restart dovecot
else
  $SUDO service dovecot restart
fi
log "dovecot: running  (IMAPS 993$( [ "$PLAINTEXT" = 1 ] && echo ', IMAP 143 with password login' ), listen: $LISTEN)"

if [ -n "$TEST_USER" ]; then
  echo; log "mailboxes for $TEST_USER:"
  $SUDO doveadm mailbox list -u "$TEST_USER" | sed 's/^/    /' \
    || warn "doveadm mailbox list failed - see: journalctl -u dovecot"
fi

echo; log "done."
