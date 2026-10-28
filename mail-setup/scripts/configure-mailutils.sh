#!/usr/bin/env bash
#
# configure-mailutils.sh
#
# GNU Mailutils (mail(1)): install it if missing, then write its per-user
# settings - ~/.mail (IMAP mailbox + SMTP mailer URLs) and ~/.mu-tickets
# (the password, URL-encoded, mode 600).  Other programs can reuse those two
# files (tvmail-backend does, as a fallback behind its own tvmail.conf).
#
# Usage:
#   ./configure-mailutils.sh [options]
#
# Options:
#   --role master|client   only changes the suggested defaults: master ->
#                          localhost, client -> the master's name
#   --host NAME            suggested IMAP/SMTP host
#   --smtp-port N          suggested SMTP port (default 25)
#   -y, --yes              accept every "offer to ..." prompt
#   --assume-no            decline every "offer to ..." prompt (checks only)
#   -h | --help            show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../lib/common.sh"

ROLE=client
DEF_HOST=""
DEF_SMTP_PORT=25
ASSUME="${ASSUME:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --role)      ROLE="${2:?}"; shift 2 ;;
    --host)      DEF_HOST="${2:?}"; shift 2 ;;
    --smtp-port) DEF_SMTP_PORT="${2:?}"; shift 2 ;;
    -y|--yes)    ASSUME=yes; shift ;;
    --assume-no) ASSUME=no; shift ;;
    -h|--help)   usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$DEF_HOST" ]; then
  [ "$ROLE" = master ] && DEF_HOST=localhost || DEF_HOST=cpbee
fi

# python3, for the ~/.mu-tickets percent-encoder below (falls back to sed).
PY3=$(find_python || true)
enc() {   # enc STRING -> percent-encoded STRING
  if [ -n "$PY3" ]; then
    "$PY3" -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
  else
    printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/@/%40/g' -e 's/:/%3A/g' -e 's/#/%23/g' \
                            -e 's/&/%26/g' -e 's/(/%28/g' -e 's/)/%29/g' -e 's#/#%2F#g' \
                            -e 's/?/%3F/g' -e 's/ /%20/g'
  fi
}

# --------------------------------------------------------------------------
step "GNU Mailutils (mail(1))"
# --------------------------------------------------------------------------
HAVE_MU=0
if command -v mail >/dev/null 2>&1 && mail --version 2>/dev/null | grep -qi mailutils; then
  HAVE_MU=1
  log "GNU Mailutils: found ($(mail --version 2>/dev/null | head -1))"
else
  log "GNU Mailutils: not found"
  if ask "Install GNU Mailutils now?"; then
    case "$PKG" in
      apt)    pkg_install mailutils ;;
      dnf|yum) pkg_install mailutils ;;
      pacman) pkg_install mailutils || warn "not in the official repos - try the AUR: yay -S mailutils" ;;
      brew)   pkg_install mailutils || warn "no stock brew formula - see https://mailutils.org" ;;
      cygwin)  pkg_install mailutils ;;
      *) warn "no known package manager - see https://mailutils.org" ;;
    esac
    command -v mail >/dev/null 2>&1 && HAVE_MU=1
  fi
fi
[ "$HAVE_MU" = 1 ] || warn "mail(1) still not on \$PATH - the settings below will be ready for it, just not usable yet"

# --------------------------------------------------------------------------
step "Configure GNU Mailutils (~/.mail, ~/.mu-tickets)"
# --------------------------------------------------------------------------
if ask "Write ~/.mail and ~/.mu-tickets now?"; then
  imap_host=$(readval "IMAP host" "$DEF_HOST")
  imap_port=$(readval "IMAP port" "143")
  imap_user=$(readval "IMAP user" "$(id -un)")
  smtp_host=$(readval "SMTP host" "$DEF_HOST")
  smtp_port=$(readval "SMTP port" "$DEF_SMTP_PORT")

  mail_cfg="$HOME/.mail"
  backup "$mail_cfg"
  cat > "$mail_cfg" <<EOF
# ~/.mail - generated $(date) by mail-setup's configure-mailutils.sh

mailbox {
    mailbox-pattern "imap://${imap_user}@${imap_host}:${imap_port}/INBOX";
    # base URL for mail(1)'s "+name" folder shorthand (folder +Trash, mail -f +Junk, ...)
    folder "imap://${imap_user}@${imap_host}:${imap_port}/";
};

mailer {
    url "smtp://${smtp_host}:${smtp_port}";
};
EOF
  log "wrote $mail_cfg"

  # Loud and proud: have mail(1) name itself in every message it sends
  # (User-Agent: mail (GNU Mailutils X.Y)).  That is Mailutils' default; this
  # pins it, so a site-wide /etc/mailrc "set noxmailer" can't silence it.
  # Who/where it came from is stamped downstream by Postfix (header_checks,
  # see configure-sendmail-relay.sh) or sendmail-shim.  Added once; the rest
  # of ~/.mailrc is left alone.
  mailrc="$HOME/.mailrc"
  if ! grep -qs '^# >>> mail-setup: loud and proud' "$mailrc" 2>/dev/null; then
    backup "$mailrc"
    cat >> "$mailrc" <<'EOF'
# >>> mail-setup: loud and proud >>>
set xmailer
# <<< mail-setup <<<
EOF
    log "added 'set xmailer' to $mailrc (User-Agent header on outgoing mail)"
  fi

  if ask "Add a ~/.mu-tickets credential for ${imap_user}@${imap_host}?"; then
    pw=$(readsecret "password for ${imap_user}@${imap_host}")
    tickets="$HOME/.mu-tickets"
    backup "$tickets"
    tmp=$(mktemp)
    [ -e "$tickets" ] && grep -v "@${imap_host}\$" "$tickets" > "$tmp" || : > "$tmp"
    printf '*://%s:%s@%s\n' "$(enc "$imap_user")" "$(enc "$pw")" "$imap_host" >> "$tmp"
    mv "$tmp" "$tickets"
    chmod 600 "$tickets"
    log "wrote $tickets (mode 600)"
  fi
fi
