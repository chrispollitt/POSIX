#!/usr/bin/env bash
#
# configure-sendmail-relay.sh
#
# Configure Postfix as a send-only sendmail: local mail -> /var/mail,
# everything else -> an authenticated TLS smarthost, with locally generated
# senders rewritten to the real mailbox (this box can't receive replies).
#
# Linux only - the mail master role (the one host that owns /var/mail) is
# meant for a Linux/Pi box.  If Postfix isn't installed, apt-installs it.
# You're asked whether to run it as a service (systemd / sysv / none).
#
# Re-runnable.
#
# Usage:
#   sudo ./configure-sendmail-relay.sh --relay-file smtp-relay.txt [options]
#
# Options:
#   --relay-file FILE   cPanel-style "Mail Client Configuration" text to read the
#                       smarthost host / port / username (and password) from.
#   --user NAME         local account that receives root's mail   (default: you)
#   --service KIND      systemd | sysv | none   (default: ask)
#   --smtp-port N       override the smarthost submission port
#   --cron              add a 15-minute queue-runner cron entry (send-only mode)
#   --test ADDR         after configuring, send a test message to ADDR and you
#   -h | --help         show this header.
#
set -euo pipefail

RELAY_FILE=""
ADMIN_USER="$(id -un)"
ADD_CRON=0
TEST_ADDR=""
SERVICE=""
SMTP_PORT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --relay-file)  RELAY_FILE="${2:?}"; shift 2 ;;
    --user)        ADMIN_USER="${2:?}"; shift 2 ;;
    --service)     SERVICE="${2:?}";    shift 2 ;;
    --smtp-port)   SMTP_PORT="${2:?}";  shift 2 ;;
    --rewrite-all) shift ;;   # deprecated no-op: outbound From is always rewritten now
    --cron)        ADD_CRON=1; shift ;;
    --test)        TEST_ADDR="${2:?}"; shift 2 ;;
    -h|--help)     sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '  %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s 2>/dev/null)" = Linux ] || die \
"Linux only - Postfix isn't available on $(uname -s 2>/dev/null || echo 'this OS').
  The mail master role (the box that owns /var/mail) is meant for a Linux/Pi
  box; point a client at it instead with:  mail-setup.sh --role client"

_enable_service() {   # $1 = service name; uses $svc / $SUDO
    case "$svc" in
      systemd) $SUDO systemctl enable --now "$1"
               log "$1: enabled + running (systemd)" ;;
      sysv)    $SUDO update-rc.d "$1" defaults >/dev/null 2>&1 || true
               $SUDO service "$1" restart
               log "$1: enabled + running (sysv init)" ;;
      *)       $SUDO systemctl disable --now "$1" 2>/dev/null \
                 || $SUDO service "$1" stop 2>/dev/null || true
               log "$1: not run as a service" ;;
    esac
}

_cfg_postfix() {   # configure an already-installed Postfix as a smarthost relay
    hn="$(hostname 2>/dev/null || echo localhost)"
    fqdn="$(hostname -f 2>/dev/null || echo "$hn")"
    # installed but never configured (debconf "No configuration"): no main.cf,
    # and postconf -e refuses to create one
    if [ ! -e /etc/postfix/main.cf ]; then
        if [ -r /usr/share/postfix/main.cf.debian ]; then
            $SUDO cp /usr/share/postfix/main.cf.debian /etc/postfix/main.cf
        else
            $SUDO touch /etc/postfix/main.cf
        fi
        log "postfix: had no main.cf - started from the distro default"
    fi
    $SUDO postconf -e \
      "relayhost = [${H}]:${PORT}" \
      "smtp_sasl_auth_enable = yes" \
      "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd" \
      "smtp_sasl_security_options = noanonymous" \
      "smtp_sasl_tls_security_options = noanonymous" \
      "smtp_tls_security_level = encrypt" \
      "smtp_use_tls = yes" \
      "smtp_generic_maps = hash:/etc/postfix/generic" \
      "inet_interfaces = loopback-only" \
      "mydestination = \$myhostname, localhost.\$mydomain, localhost" \
      "alias_maps = hash:/etc/aliases" \
      "alias_database = hash:/etc/aliases"
    if [ "$reuse" = 0 ]; then
        printf '[%s]:%s %s:%s\n' "$H" "$PORT" "$U" "$P" | $SUDO tee /etc/postfix/sasl_passwd >/dev/null
        $SUDO chmod 600 /etc/postfix/sasl_passwd
    fi
    $SUDO postmap /etc/postfix/sasl_passwd
    # one-way rewrite: every locally originated address -> the real mailbox,
    # applied only on outbound (smtp_generic_maps)
    $SUDO tee /etc/postfix/generic >/dev/null <<EOF
@${hn}                  ${U}
@${fqdn}                ${U}
@localhost              ${U}
@localhost.localdomain  ${U}
root@localhost          ${U}
${ADMIN_USER}@localhost ${U}
EOF
    $SUDO postmap /etc/postfix/generic
    $SUDO grep -qs '^root:' /etc/aliases \
      || printf 'root: %s\n' "$ADMIN_USER" | $SUDO tee -a /etc/aliases >/dev/null
    $SUDO newaliases 2>/dev/null || true
    log "postfix: relayhost=[${H}]:${PORT}, SASL+TLS, generic rewrite -> ${U}, loopback-only"
    log "  (for LAN delivery later: inet_interfaces=all + mynetworks=<your /24>)"
    _enable_service postfix
}

SUDO=""
if [ "$(id -u)" != 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "run as root (no sudo found)"
    SUDO="sudo"
fi

_rv() { sed -n "s/^$1:[[:space:]]*//p" "$RELAY_FILE" 2>/dev/null | head -1 | tr -d ' \r'; }
H=""; U=""; P=""; PORT=""
if [ -n "$RELAY_FILE" ] && [ -f "$RELAY_FILE" ]; then
    H="$(_rv 'Outgoing Server')"; U="$(_rv Username)"; P="$(_rv Password)"
    PORT="$(sed -n 's/.*SMTP Port:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$RELAY_FILE" | head -1 | tr -d ' \r')"
fi
: "${H:=u-l.ca}"; : "${U:=cwp@u-l.ca}"
case "$PORT" in 465|"") PORT=587 ;; esac    # STARTTLS submission (465 needs extra wiring)
[ -n "$SMTP_PORT" ] && PORT="$SMTP_PORT"

if ! command -v postfix >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || die \
"Postfix not installed and no apt to add it.  Install postfix, then re-run this script."
    log "Postfix not found - installing ..."
    $SUDO apt-get update -qq || true
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y postfix >/dev/null || die \
"could not install postfix (EOL release / no network?).  Install it by hand."
fi
log "MTA       : postfix"

PW_STORE=/etc/postfix/sasl_passwd
reuse=0
if [ -z "$P" ] || [ "$P" = SECRET ]; then
    if [ -n "${SMARTHOST_PASS_ENV:-}" ]; then P="$SMARTHOST_PASS_ENV"
    elif $SUDO test -r "$PW_STORE"; then reuse=1; log "reusing existing $PW_STORE"
    else printf 'SMTP password for %s (host %s): ' "$U" "$H" >&2
         read -rs P; echo >&2
    fi
fi
[ "$reuse" = 1 ] || [ -n "$P" ] || die "no SMTP password supplied"

# --- run Postfix as a background service? (it always needs its daemon) ----
have_sd=0; have_sv=0
[ -d /run/systemd/system ] && have_sd=1
{ command -v service >/dev/null 2>&1 && [ -d /etc/init.d ]; } && have_sv=1
svc="$SERVICE"
if [ -z "$svc" ]; then
    def=none
    [ "$have_sv" = 1 ] && def=sysv
    [ "$have_sd" = 1 ] && def=systemd
    echo
    echo "Run Postfix as a background service (queue runner, deferred-mail retries)?"
    printf "  options: "
    [ "$have_sd" = 1 ] && printf "systemd "
    [ "$have_sv" = 1 ] && printf "sysv "
    printf "none\n  choice [%s]: " "$def"
    read -r svc || true; : "${svc:=$def}"
fi
if [ "$svc" != systemd ] && [ "$svc" != sysv ]; then
    [ "$have_sd" = 1 ] && svc=systemd || { [ "$have_sv" = 1 ] && svc=sysv || svc=systemd; }
    warn "Postfix needs its daemon to accept local mail - using '$svc'"
fi

echo
log "smarthost : ${H}::${PORT}  (STARTTLS, AUTH)"
log "auth user : ${U}"
log "rewrite   : local senders -> ${U}   (on outbound only)"
log "service   : ${svc}"
log "root mail : ${ADMIN_USER}"
echo

_cfg_postfix

if [ -n "$TEST_ADDR" ]; then
    echo; log "test message to $TEST_ADDR and $ADMIN_USER ..."
    printf 'To: %s\nSubject: mail-setup relay test\n\nsent %s from %s\n' \
        "$TEST_ADDR" "$(date)" "$(hostname)" \
      | /usr/sbin/sendmail -oi "$TEST_ADDR" "$ADMIN_USER"
    log "check:  mail  |  sudo tail /var/log/mail.log       |  mailq"
fi

if [ "$ADD_CRON" = 1 ]; then
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v 'configure-sendmail-relay: postqueue -f'
          echo "*/15 * * * * postqueue -f   # configure-sendmail-relay: postqueue -f" ) | crontab -
        log "added */15 'postqueue -f' crontab entry (ensure 'cron' is running)"
    else
        warn "--cron requested but 'crontab' not found; install the 'cron' package"
    fi
fi

echo; log "done."
