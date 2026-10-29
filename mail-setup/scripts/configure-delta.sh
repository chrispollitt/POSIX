#!/usr/bin/env bash
#
# configure-delta.sh
#
# Make the master able to host Delta Chat mailboxes (tvchat's Delta Chat
# accounts, or any Delta Chat app): Delta Chat's core logs in to IMAP to read
# and to SMTP *with a password* to send, and a Postfix that only relays for the
# LAN on port 25 has no such login.  Linux only, on the master (Postfix +
# Dovecot - see configure-sendmail-relay.sh and configure-dovecot.sh).  Does:
#
#   1. creates the mailboxes: one system user per name in --users (no shell,
#      home directory) with a random password, printed once and appended to
#      --password-file (mode 600).  An existing user is left alone.  Use a
#      DEDICATED mailbox: Delta Chat moves chat mail into its own folder and
#      may delete it from the server - never the everyday inbox;
#   2. makes --domain a local Postfix domain (mydestination), so mail between
#      the mailboxes is delivered here.  Delta Chat wants a domain with a dot
#      (`delta@cpbee.cmnet`, not `delta@cpbee`);
#   3. writes ONE Dovecot drop-in, conf.d/96-mail-setup-submission.conf (mode
#      644 - dovecot-lda reads it as the recipient, so an unreadable file
#      stops ALL local delivery), an auth socket for Postfix.  Checked with
#      doveconf and removed if the check fails; works in Dovecot 2.3 and 2.4;
#   4. adds a Postfix `submission` service on port 587: STARTTLS required, a
#      login required, relaying only for logged-in users.  It uses Postfix's
#      own certificate (the distro's self-signed one unless you set another),
#      so clients need to accept it (tvchat: verify = false);
#   5. opens 587 for the LAN with ../../net-utils/lan-port (on a cmpi-router box:
#      listed in its port list, `setup-router.sh fw` reloaded, checked; elsewhere
#      it says which nft rule would); with ufw active, opens it there;
#   6. logs in to IMAP (993) and SMTP (587) as each NEW user to prove it works,
#      and prints the tvchat.conf lines for it.
#
# Re-runnable: each step is skipped when already true; Postfix's main.cf and
# master.cf are copied to --backup-dir first.  An older temporary drop-in
# (96-delta-submission.conf) is replaced.
#
# Usage:
#   sudo ./configure-delta.sh [options]
#
# Options:
#   --domain DOMAIN     the mail domain of the mailboxes (default: the host's
#                       fully qualified name, if it has a dot)
#   --users "a b"       mailbox names to create (default: delta)
#   --password-file F   where new passwords are saved (default:
#                       /root/mail-setup-delta-passwords)
#   --backup-dir DIR    where main.cf / master.cf are copied (default:
#                       /root/mail-setup-backup-DATE)
#   --print             just print the Dovecot drop-in and the Postfix settings
#                       to stdout - no root, no Linux, nothing changed (tests)
#   -h | --help         show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../lib/common.sh"

DOMAIN=""
USERS="delta"
PWFILE=/root/mail-setup-delta-passwords
BACKUP=""
PRINT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)        DOMAIN="${2:?}"; shift 2 ;;
    --users)         USERS="${2:?}"; shift 2 ;;
    --password-file) PWFILE="${2:?}"; shift 2 ;;
    --backup-dir)    BACKUP="${2:?}"; shift 2 ;;
    --print)         PRINT=1; shift ;;
    -h|--help) usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

DROP=/etc/dovecot/conf.d/96-mail-setup-submission.conf
OLDDROP=/etc/dovecot/conf.d/96-delta-submission.conf
POSTCONF=$(command -v postconf 2>/dev/null || echo /usr/sbin/postconf)

# the settings of the submission service, one "name=value" per line
submission_settings() {
  cat <<'EOF'
syslog_name=postfix/submission
smtpd_tls_security_level=encrypt
smtpd_tls_auth_only=yes
smtpd_sasl_auth_enable=yes
smtpd_sasl_type=dovecot
smtpd_sasl_path=private/auth
smtpd_sasl_security_options=noanonymous
smtpd_relay_restrictions=permit_sasl_authenticated,reject
smtpd_recipient_restrictions=permit_sasl_authenticated,reject
EOF
}

# the same text suits Dovecot 2.3 and 2.4
dropin() {
  cat <<EOF
# 96-mail-setup-submission.conf - generated $(date) by mail-setup's
# configure-delta.sh.  Re-run that script rather than editing this by hand.
#
# Lets Postfix's submission service (port 587) ask Dovecot to check logins.
# Must stay world-readable: dovecot-lda reads every conf.d file as the
# recipient, and a file it cannot open stops all local delivery.

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
EOF
}

if [ "$PRINT" = 1 ]; then
  dropin
  echo
  echo "# Postfix master.cf: submission inet n - y - - smtpd"
  submission_settings | sed 's/^/#   -o /'
  exit 0
fi

[ "$IS_LINUX" = 1 ] || die "Linux only - run this on the mail master (Postfix + Dovecot)"
if [ "$(id -u)" != 0 ] && [ -z "$SUDO" ]; then die "run as root (no sudo found)"; fi
command -v "$POSTCONF" >/dev/null 2>&1 || die "postconf not found - run configure-sendmail-relay.sh first"
command -v doveconf >/dev/null 2>&1 || die "doveconf not found - run configure-dovecot.sh first"

if [ -z "$DOMAIN" ]; then
  fq=$(hostname -f 2>/dev/null || true)
  case "$fq" in *.*) DOMAIN=$fq ;; *) die "give --domain (this host's name has no dot)" ;; esac
fi
case "$DOMAIN$USERS" in *[!A-Za-z0-9._\ -]*) die "--domain and --users take plain names only" ;; esac
[ -n "$BACKUP" ] || BACKUP=/root/mail-setup-backup-$(date +%Y%m%d-%H%M%S)

backup() {   # backup FILE - once per run
  [ -d "$BACKUP" ] || $SUDO mkdir -p "$BACKUP"
  $SUDO cp -p "$1" "$BACKUP/"
}

# ---------------------------------------------------------------------------
step "Mailboxes"
# ---------------------------------------------------------------------------
NEW=""        # "user:password" of those created now
for u in $USERS; do
  if getent passwd "$u" >/dev/null 2>&1; then
    log "$u: exists"
    continue
  fi
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)
  [ ${#pw} -ge 12 ] || die "could not make a random password"
  $SUDO useradd -m -s /usr/sbin/nologin "$u"
  printf '%s:%s\n' "$u" "$pw" | $SUDO chpasswd
  # the umask is for this one write only: leaking it once made a root-owned
  # Dovecot file unreadable to the LDA and stopped all local mail
  $SUDO sh -c "umask 077; printf '%s  %s\n' '$u@$DOMAIN' '$pw' >> '$PWFILE'"
  log "$u@$DOMAIN created, password: $pw   (also in $PWFILE)"
  NEW="$NEW $u:$pw"
done

# ---------------------------------------------------------------------------
step "Postfix: $DOMAIN is a local domain"
# ---------------------------------------------------------------------------
if $SUDO "$POSTCONF" -h mydestination 2>/dev/null | tr ',' ' ' | grep -qw -- "$DOMAIN"; then
  log "already in mydestination"
else
  backup /etc/postfix/main.cf
  $SUDO "$POSTCONF" -e "mydestination = $($POSTCONF -h mydestination 2>/dev/null), $DOMAIN"
  log "added to mydestination"
  RELOAD_POSTFIX=1
fi

# ---------------------------------------------------------------------------
step "Dovecot: auth socket for Postfix"
# ---------------------------------------------------------------------------
tmp=$(mktemp); dropin > "$tmp"
$SUDO rm -f "$OLDDROP"
prev=""
if [ -f "$DROP" ]; then prev=$(mktemp); $SUDO cp "$DROP" "$prev"; fi
$SUDO install -m 644 "$tmp" "$DROP"
rm -f "$tmp"
if $SUDO doveconf -n >/dev/null 2>&1; then
  $SUDO systemctl reload dovecot 2>/dev/null || $SUDO service dovecot reload || true
  log "$DROP written (mode 644), Dovecot reloaded"
else
  if [ -n "$prev" ]; then $SUDO install -m 644 "$prev" "$DROP"; else $SUDO rm -f "$DROP"; fi
  die "doveconf rejects the config - $DROP put back as it was"
fi
[ -z "$prev" ] || rm -f "$prev"

# ---------------------------------------------------------------------------
step "Postfix: submission service (587)"
# ---------------------------------------------------------------------------
# postconf -M exits 0 even for a service that is not there: test the output
if [ -n "$($SUDO "$POSTCONF" -M submission/inet 2>/dev/null)" ]; then
  log "submission is already defined in master.cf (left as it is)"
else
  backup /etc/postfix/master.cf
  $SUDO "$POSTCONF" -M "submission/inet=submission inet n - y - - smtpd"
  while IFS= read -r kv; do
    $SUDO "$POSTCONF" -P "submission/inet/$kv"
  done < <(submission_settings)
  log "submission added to master.cf"
  RELOAD_POSTFIX=1
fi
if [ "${RELOAD_POSTFIX:-0}" = 1 ]; then
  $SUDO "$POSTCONF" >/dev/null 2>&1 || die "postconf rejects the Postfix config - see $BACKUP"
  $SUDO systemctl reload postfix 2>/dev/null || $SUDO postfix reload || true
fi

# ---------------------------------------------------------------------------
step "Firewall (587)"
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q '^Status: active'; then
  $SUDO ufw allow 587/tcp >/dev/null && log "ufw: 587/tcp allowed"
fi
lan_ports_keep 587 "Postfix submission (mail-setup configure-delta.sh)"

# ---------------------------------------------------------------------------
step "Logins"
# ---------------------------------------------------------------------------
if [ -z "$NEW" ]; then
  log "no new mailbox: nothing to try (a login needs its password)"
else
  for up in $NEW; do
    u=${up%%:*}; pw=${up#*:}
    python3 - "$u" "$pw" <<'PYEOF' || warn "login test for $u failed - see above"
import imaplib, smtplib, ssl, sys
user, pw = sys.argv[1:3]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
bad = 0
try:
    m = imaplib.IMAP4_SSL("localhost", 993, ssl_context=ctx)
    print("  %s: IMAP login %s" % (user, m.login(user, pw)[0])); m.logout()
except Exception as e:
    print("  %s: IMAP FAILED: %s" % (user, e)); bad = 1
try:
    s = smtplib.SMTP("localhost", 587, timeout=15); s.starttls(context=ctx)
    print("  %s: SMTP login %s" % (user, s.login(user, pw)[0])); s.quit()
except Exception as e:
    print("  %s: SMTP FAILED: %s" % (user, e)); bad = 1
sys.exit(bad)
PYEOF
  done
fi

host=$(hostname -s 2>/dev/null || hostname)
cat <<EOF

For each mailbox, tvchat.conf (the login is the bare user name; the password
goes in ~/.netrc as  machine $host login USER password ...  or in
\$TVCHAT_PASS_<ACCOUNT>):

  [account:delta]
  protocol    = deltachat
  addr        = USER@$DOMAIN
  imap_server = $host
  imap_user   = USER
  smtp_server = $host
  smtp_port   = 587
  smtp_user   = USER
  verify      = false

Two Delta Chat accounts must exchange keys before they can write to each
other: one runs  tvchat-backend invite ACCOUNT  and the other joins that link.
EOF
