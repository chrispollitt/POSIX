#!/usr/bin/env bash
#
# mail-setup.sh - set up standard Unix mail on this box: GNU Mailutils,
# Postfix, a puller (pop-pull or getmail), Dovecot, or a sendmail shim.
#
# Two roles:
#   master  - the one host that owns /var/mail: Postfix (smarthost relay +
#             local delivery), Dovecot (IMAP over /var/mail + ~/mail), and a
#             puller that fetches mail from your ISP into /var/mail.
#             Linux/Pi only (no Postfix/Dovecot on Cygwin).
#   client  - a thin box that talks IMAP/SMTP to a master: optionally a
#             /usr/sbin/sendmail shim that forwards straight to the master.
# Both get GNU Mailutils, with ~/.mail + ~/.mu-tickets pointed at the master.
#
# Re-runnable; every step is a yes/no offer, so declining one just skips it.
# Each step is its own script in scripts/ and can be run alone:
#   configure-sendmail-relay.sh  Postfix as a send-only smarthost relay
#   configure-dovecot.sh         Dovecot IMAP over /var/mail + ~/mail
#   configure-mail-pull.sh       pop-pull   (POP3S -> /var/mail)
#   configure-getmail.sh         getmail    (POP3S/IMAPS -> /var/mail)
#   install-sendmail-shim.sh     client-side /usr/sbin/sendmail forwarder
#   configure-mailutils.sh       mail(1) + ~/.mail + ~/.mu-tickets
#
# Usage:
#   ./mail-setup.sh [options]
#
# Options:
#   --role master|client     skip the role question
#   --puller pop-pull|getmail|none   skip the puller question (master)
#   --caller NAME            name shown in test-message subjects (default:
#                            mail-setup; tvmail's configure.sh passes tvmail)
#   -y, --yes                accept every "offer to ..." prompt (unattended)
#   --assume-no              decline every "offer to ..." prompt (checks only)
#   -h, --help               this text
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
S="$here/scripts"
. "$here/lib/common.sh"

ROLE=""
PULLER=""
CALLER=mail-setup
ASSUME=""        # "" = ask each time / "yes" / "no"

while [ $# -gt 0 ]; do
  case "$1" in
    --role)      ROLE="${2:?}"; shift 2 ;;
    --role=*)    ROLE="${1#--role=}"; shift ;;
    --puller)    PULLER="${2:?}"; shift 2 ;;
    --puller=*)  PULLER="${1#--puller=}"; shift ;;
    --caller)    CALLER="${2:?}"; shift 2 ;;
    -y|--yes)    ASSUME=yes; shift ;;
    --assume-no) ASSUME=no; shift ;;
    -h|--help)   usage "$0"; exit 0 ;;
    *) echo "mail-setup.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$ROLE" in ""|master|client) : ;; *) die "--role must be master or client" ;; esac
case "$PULLER" in ""|pop-pull|getmail|none) : ;; *) die "--puller must be pop-pull, getmail or none" ;; esac
export ASSUME     # the step scripts' ask() honours it too

log "OS: $OS   package manager: ${PKG:-none found}"

# --------------------------------------------------------------------------
step "Role"
# --------------------------------------------------------------------------
if [ -z "$ROLE" ]; then
  echo "Is this the mail MASTER (owns /var/mail, runs Postfix + Dovecot + a puller)"
  echo "or a CLIENT (a thin box that talks IMAP/SMTP to a master)?"
  ans=$(readval "master or client" "client")
  case "$ans" in m|M|master|Master) ROLE=master ;; *) ROLE=client ;; esac
fi
log "role: $ROLE"
if [ "$ROLE" = master ] && [ "$IS_LINUX" = 0 ]; then
  warn "the master role needs Postfix + Dovecot - Linux/Pi only; on $OS the"
  warn "master steps below will be skipped or fail.  Consider --role client."
fi

MASTER_HOST=""
MASTER_PORT=""

if [ "$ROLE" = master ]; then
  # ------------------------------------------------------------------------
  step "Postfix (master MTA)"
  # ------------------------------------------------------------------------
  if command -v postfix >/dev/null 2>&1; then
    log "postfix: found ($(command -v postfix))"
  else
    log "postfix: not found"
    if ask "Install Postfix now?"; then
      case "$PKG" in
        apt|dnf|yum|pacman) pkg_install postfix ;;
        brew) log "macOS ships Postfix already (/usr/sbin/postfix) - nothing to install" ;;
        cygwin) warn "Cygwin has no Postfix package - the master role needs a Linux/Pi box." ;;
        *) warn "no known package manager - install postfix by hand" ;;
      esac
    fi
  fi

  # ------------------------------------------------------------------------
  step "Configure Postfix (smarthost relay + local delivery)"
  # ------------------------------------------------------------------------
  relay_file=""
  if command -v postfix >/dev/null 2>&1; then
    if ask "Run configure-sendmail-relay.sh now?"; then
      relay_file=$(readval "cPanel-style relay-info file (blank = enter host/user/pass when asked)" "")
      test_addr=$(readval "send a live test message to (blank = skip)" "")
      set -- "$S/configure-sendmail-relay.sh"
      [ -n "$relay_file" ] && set -- "$@" --relay-file "$relay_file"
      [ -n "$test_addr" ]  && set -- "$@" --test "$test_addr"
      log "running: $*"
      bash "$@" || warn "configure-sendmail-relay.sh exited non-zero - see above"
    fi
  else
    warn "no MTA to configure yet - install Postfix first, or answer 'y' above"
  fi
  MASTER_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo localhost)
  MASTER_PORT=25

  # ------------------------------------------------------------------------
  step "Dovecot (IMAP over /var/mail, for every client)"
  # ------------------------------------------------------------------------
  if ask "Run configure-dovecot.sh now?"; then
    set -- "$S/configure-dovecot.sh" --test "$(id -un)"
    # security-relevant, so never switched on by --yes
    if [ -z "$ASSUME" ] && ask "Allow password login over plain IMAP (143) from the LAN?" N; then
      set -- "$@" --plaintext
    fi
    log "running: $*"
    bash "$@" || warn "configure-dovecot.sh exited non-zero - see above"
  fi

  # ------------------------------------------------------------------------
  step "Puller (fetch mail from your ISP into /var/mail)"
  # ------------------------------------------------------------------------
  if [ -z "$PULLER" ]; then
    echo "pop-pull: tiny stdlib-Python POP3S puller, nothing to install."
    echo "getmail : getmail6 - POP3S or IMAPS, more options, one more package."
    if [ -n "$ASSUME" ]; then PULLER=pop-pull
    else
      ans=$(readval "pop-pull, getmail or none" "pop-pull")
      case "$ans" in g*|G*) PULLER=getmail ;; n*|N*) PULLER=none ;; *) PULLER=pop-pull ;; esac
    fi
  fi
  log "puller: $PULLER"
  if [ "$PULLER" != none ]; then
    script="$S/configure-mail-pull.sh"; [ "$PULLER" = getmail ] && script="$S/configure-getmail.sh"
    if ask "Run $(basename "$script") now?"; then
      relay_file=$(readval "same relay-info file (blank = defaults / prompts)" "${relay_file:-}")
      do_test=""; ask "Run one fetch right after configuring?" N && do_test=1
      set -- "$script"
      [ -n "$relay_file" ] && set -- "$@" --relay-file "$relay_file"
      [ -n "$do_test" ]    && set -- "$@" --test
      log "running: $*"
      bash "$@" || warn "$(basename "$script") exited non-zero - see above"
    fi
  fi

else
  # ------------------------------------------------------------------------
  step "sendmail shim (forwards straight to the master, no local queue)"
  # ------------------------------------------------------------------------
  if ask "Install bin/sendmail-shim as /usr/sbin/sendmail?"; then
    MASTER_HOST=$(readval "master hostname" "cmpi")
    MASTER_PORT=$(readval "master SMTP port (25 = trusts this LAN via mynetworks, no auth)" "25")
    bash "$S/install-sendmail-shim.sh" --host "$MASTER_HOST" --port "$MASTER_PORT" \
      || warn "install-sendmail-shim.sh exited non-zero - see above"
  fi
fi

# --------------------------------------------------------------------------
# GNU Mailutils + ~/.mail / ~/.mu-tickets
# --------------------------------------------------------------------------
set -- "$S/configure-mailutils.sh" --role "$ROLE"
[ -n "$MASTER_HOST" ] && set -- "$@" --host "$MASTER_HOST"
[ -n "$MASTER_PORT" ] && set -- "$@" --smtp-port "$MASTER_PORT"
bash "$@" || warn "configure-mailutils.sh exited non-zero - see above"

# --------------------------------------------------------------------------
step "Test mail(1) and sendmail"
# --------------------------------------------------------------------------
if ask "Send a test message to yourself via mail(1) now?"; then
  if command -v mail >/dev/null 2>&1; then
    if echo "$CALLER mail-setup test, $(date)" | mail -s "$CALLER mail-setup test" "$(id -un)"; then
      log "sent - check your inbox"
    else
      warn "mail(1) send failed - check ~/.mail / ~/.mu-tickets and the MTA above"
    fi
  else
    warn "mail(1) not found - install GNU Mailutils first"
  fi
fi

if ask "Send a test message via /usr/sbin/sendmail now?"; then
  if [ -x /usr/sbin/sendmail ]; then
    if printf 'To: %s\nSubject: %s mail-setup sendmail test\n\nhi from mail-setup.sh\n' "$(id -un)" "$CALLER" \
         | /usr/sbin/sendmail -t; then
      log "sendmail accepted the message (exit 0)"
    else
      warn "/usr/sbin/sendmail exited non-zero"
    fi
  else
    warn "/usr/sbin/sendmail not found/executable"
  fi
fi

echo
log "mail-setup done (role: $ROLE)."
