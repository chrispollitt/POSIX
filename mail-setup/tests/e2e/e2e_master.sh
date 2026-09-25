#!/usr/bin/env bash
#
# e2e_master.sh - live check of a configured mail MASTER (Linux).
#
# Talks to the real Postfix + Dovecot on this box, as the current user (or,
# run as root, as $MAIL_SETUP_E2E_USER):
#   1. postfix check / doveconf -n are clean, both daemons are running
#   2. a message sent to you through /usr/sbin/sendmail lands in /var/mail/$USER
#   3. Dovecot finds that same message in your INBOX (doveadm search)
#   4. the special-use folders (Drafts Sent Trash Junk Archive) exist
#   5. mail(1), if installed, lists it straight from the spool
#   6. the test message is expunged again
# Optional, because they reach the outside world:
#   MAIL_SETUP_E2E_PULL=1        mail-pull -n -v  (dry run against your ISP)
#   MAIL_SETUP_E2E_SEND_TO=ADDR  also relay a message out via the smarthost
#
# Needs root or passwordless sudo (doveadm, postfix check).  Exits 77 =
# skipped when this isn't a Linux box with Postfix + Dovecot, 0 = pass,
# 1 = fail.
set -uo pipefail

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
skip() { echo "e2e_master: skipped - $*"; exit 77; }

[ "$(uname -s)" = Linux ] || skip "not Linux"
for c in postfix postconf dovecot doveconf doveadm; do
  command -v "$c" >/dev/null 2>&1 || [ -x "/usr/sbin/$c" ] || skip "no $c here (not a mail master)"
done
export PATH="$PATH:/usr/sbin:/sbin"
SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo -n"
$SUDO true 2>/dev/null || skip "needs root or passwordless sudo"

ME="${MAIL_SETUP_E2E_USER:-$(id -un)}"     # as root: whose mail to test
SPOOL="/var/mail/$ME"
TOKEN="mail-setup-e2e-$(date +%s)-$$"

# 1 -------------------------------------------------------------------------
$SUDO postfix check >/dev/null 2>&1 && ok "postfix check" || bad "postfix check"
$SUDO doveconf -n >/dev/null 2>&1 && ok "doveconf -n" || bad "doveconf -n"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  for s in postfix dovecot; do
    systemctl is-active --quiet "$s" && ok "$s running" || bad "$s not running"
  done
fi
[ -e /etc/dovecot/conf.d/99-mail-setup.conf ] && ok "99-mail-setup.conf present" \
  || echo "  note  no 99-mail-setup.conf - Dovecot was configured some other way"

# 2 -------------------------------------------------------------------------
printf 'To: %s\nSubject: %s\n\nsent by e2e_master.sh\n' "$ME" "$TOKEN" \
  | /usr/sbin/sendmail -oi "$ME" && ok "sendmail accepted it" || bad "sendmail failed"
got=0
for _ in $(seq 1 30); do
  grep -qF "$TOKEN" "$SPOOL" 2>/dev/null && { got=1; break; }
  sleep 1
done
[ "$got" = 1 ] && ok "delivered to $SPOOL" || bad "not in $SPOOL after 30s (see: $SUDO tail /var/log/mail.log; mailq)"

# 3 -------------------------------------------------------------------------
hits=$($SUDO doveadm search -u "$ME" mailbox INBOX subject "$TOKEN" 2>&1)
[ -n "$hits" ] && ! grep -qi error <<<"$hits" && ok "Dovecot sees it in INBOX" \
  || bad "doveadm search: ${hits:-no match}"

# 4 -------------------------------------------------------------------------
boxes=$($SUDO doveadm mailbox list -u "$ME" 2>&1)
for b in Drafts Sent Trash Junk Archive; do
  grep -qx "$b" <<<"$boxes" && ok "folder $b" || bad "folder $b missing (have: $(echo $boxes))"
done

# 5 -------------------------------------------------------------------------
if command -v mail >/dev/null 2>&1; then
  # wide COLUMNS: the header summary cuts the subject at the terminal width
  COLUMNS=300 mail -H -f "$SPOOL" 2>/dev/null | grep -qF "$TOKEN" && ok "mail(1) lists it" \
    || bad "mail -H -f $SPOOL doesn't show it"
fi

# optional ------------------------------------------------------------------
if [ "${MAIL_SETUP_E2E_PULL:-}" = 1 ]; then
  if command -v mail-pull >/dev/null 2>&1; then
    mail-pull -n -v >/dev/null 2>&1; rc=$?
    { [ "$rc" = 0 ] || [ "$rc" = 1 ]; } && ok "mail-pull -n -v (rc $rc)" || bad "mail-pull -n -v -> $rc"
  else
    bad "MAIL_SETUP_E2E_PULL=1 but no mail-pull on \$PATH"
  fi
fi
if [ -n "${MAIL_SETUP_E2E_SEND_TO:-}" ]; then
  before=$($SUDO postqueue -p 2>/dev/null | tail -1)
  printf 'To: %s\nSubject: %s (relay)\n\nsent by e2e_master.sh\n' "$MAIL_SETUP_E2E_SEND_TO" "$TOKEN" \
    | /usr/sbin/sendmail -oi "$MAIL_SETUP_E2E_SEND_TO" && ok "relay: queued to $MAIL_SETUP_E2E_SEND_TO" \
    || bad "relay: sendmail failed"
  sleep 10
  $SUDO grep -F "$MAIL_SETUP_E2E_SEND_TO" /var/log/mail.log 2>/dev/null | tail -1 | grep -q 'status=sent' \
    && ok "relay: smarthost accepted it" \
    || echo "  note  relay: no status=sent in /var/log/mail.log yet (queue: $before)"
fi

# 6 -------------------------------------------------------------------------
$SUDO doveadm expunge -u "$ME" mailbox INBOX subject "$TOKEN" >/dev/null 2>&1 \
  && ok "test message expunged" || bad "couldn't expunge the test message (subject $TOKEN)"

echo
echo "e2e_master: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
