#!/usr/bin/env bash
#
# configure-webmin.sh
#
# Webmin as the master's mail watchdog.  Installs Webmin from its official
# apt repository if it's missing, then sets up its "System and Server Status"
# module to check the mail system every few minutes and email you when
# something changes:
#   - Postfix mail queue: messages piling up means the smarthost is
#     unreachable or refusing us (the case nothing else reports)
#   - Postfix running, and Dovecot running (if installed) - unless Webmin
#     already has monitors of those types
# Alerts go to <you>@localhost, i.e. straight into /var/mail - never through
# the smarthost, which may be the very thing that's down.  You get one mail
# when a check fails and one when it recovers.  For why a message is stuck,
# open Webmin -> Servers -> Postfix Mail Server -> Mail Queue; the log is in
# System -> System Logs (/var/log/mail.log).
#
# Linux only (the mail master is a Linux/Pi box).  Only the monitors this
# script adds (ids mailsetup_*) and the module's schedule/alert settings are
# changed; your other Webmin monitors are left alone.
#
# Re-runnable.
#
# Usage:
#   sudo ./configure-webmin.sh [options]
#
# Options:
#   --email ADDR        where alerts go (default: you@localhost - local)
#   --every N           check every N minutes, 1-60 (default: 5)
#   --queue-max N       alert when more than N messages are queued (default: 0)
#   --fails N           ... for N checks in a row, so mail that's merely in
#                       transit doesn't alert (default: 2)
#   --webhook URL|off   also call URL (HTTP GET, status as query parameters)
#                       on every alert; 'off' removes it (default: unchanged)
#   --allow CIDR|auto|all
#                       who may reach Webmin (port 10000): localhost + CIDR,
#                       'auto' = this box's network, 'all' = no restriction
#                       (default: unchanged)
#   --user NAME         whose mailbox the default --email is (default: you)
#   --no-install        don't install Webmin if it's missing, just stop
#   --print             show what would be set up and exit - no root, no
#                       Linux, nothing changed (tests)
#   -h | --help         show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../lib/common.sh"      # log/warn/die, SUDO, pkg_install, lan_cidr

ADMIN_USER="${SUDO_USER:-$(id -un)}"
EMAIL=""
EVERY=5
QMAX=0
FAILS=2
WEBHOOK=""       # "" = unchanged, URL, or "off"
ALLOW=""         # "" = unchanged, CIDR, auto, all
INSTALL=1
PRINT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --email)      EMAIL="${2:?}"; shift 2 ;;
    --every)      EVERY="${2:?}"; shift 2 ;;
    --queue-max)  QMAX="${2:?}"; shift 2 ;;
    --fails)      FAILS="${2:?}"; shift 2 ;;
    --webhook)    WEBHOOK="${2:?}"; shift 2 ;;
    --allow)      ALLOW="${2:?}"; shift 2 ;;
    --user)       ADMIN_USER="${2:?}"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    --print)      PRINT=1; shift ;;
    -h|--help)    usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
: "${EMAIL:=${ADMIN_USER}@localhost}"

_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
{ _num "$EVERY" && [ "$EVERY" -ge 1 ] && [ "$EVERY" -le 60 ]; } || die "--every must be 1-60 (minutes)"
_num "$QMAX"  || die "--queue-max must be a number"
{ _num "$FAILS" && [ "$FAILS" -ge 1 ]; } || die "--fails must be 1 or more"
case "$EMAIL" in *@*) : ;; *) die "--email must be an address, e.g. $ADMIN_USER@localhost" ;; esac
case "$WEBHOOK" in ""|off|http://*|https://*) : ;; *) die "--webhook must be an http(s):// URL or 'off'" ;; esac

ALLOW_NET=""
case "$ALLOW" in
  ""|all) : ;;
  auto) if [ "$PRINT" = 1 ]; then ALLOW_NET="<this box's network>"
        else ALLOW_NET="$(lan_cidr)" || die "--allow auto: couldn't work out this box's network - give it, e.g. --allow 192.168.1.0/24"
        fi ;;
  *)    ALLOW_NET="$(cidr_check "$ALLOW")" || die "--allow: '$ALLOW' isn't an IPv4/IPv6 network (e.g. 192.168.1.0/24)" ;;
esac

_summary() {
    log "alerts to : $EMAIL   (on change: one mail when a check fails, one when it recovers)"
    log "schedule  : every $EVERY min"
    log "monitors  : mail queue > $QMAX messages for $FAILS checks in a row"
    log "            Postfix running; Dovecot running (if installed)"
    log "            (skipped when Webmin already has a monitor of that type)"
    case "$WEBHOOK" in
      "")  log "webhook   : unchanged" ;;
      off) log "webhook   : removed" ;;
      *)   log "webhook   : $WEBHOOK" ;;
    esac
    case "$ALLOW" in
      "")  log "access    : unchanged" ;;
      all) log "access    : anyone who can reach port 10000" ;;
      *)   log "access    : localhost + $ALLOW_NET" ;;
    esac
}

if [ "$PRINT" = 1 ]; then _summary; exit 0; fi

[ "$IS_LINUX" = 1 ] || die \
"Linux only - Webmin here watches the mail master (Postfix), a Linux/Pi box."

# --- Webmin itself ----------------------------------------------------------
MINISERV=/etc/webmin/miniserv.conf
_install_webmin() {
    [ "$PKG" = apt ] || die \
"no apt here - install Webmin by hand (https://webmin.com/download/), then re-run."
    log "Webmin not found - adding its apt repository and installing ..."
    command -v curl >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1 \
      || pkg_install curl gnupg ca-certificates >/dev/null
    # the same key + repo line upstream's webmin-setup-repo.sh writes
    key=/usr/share/keyrings/webmin-developers.gpg
    curl -fsSL https://download.webmin.com/developers-key.asc \
      | gpg --dearmor | $SUDO tee "$key" >/dev/null \
      || die "couldn't fetch Webmin's signing key (no network?)"
    $SUDO chmod 644 "$key"
    echo "deb [signed-by=$key] https://download.webmin.com/download/newkey/repository stable contrib" \
      | $SUDO tee /etc/apt/sources.list.d/webmin-stable.list >/dev/null
    $SUDO apt-get update -qq || true
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --install-recommends webmin >/dev/null \
      || die "could not install webmin - see apt's output above"
}
if ! $SUDO test -r "$MINISERV"; then
    [ "$INSTALL" = 1 ] || die "Webmin isn't installed ($MINISERV missing) and --no-install was given"
    _install_webmin
fi
WROOT="$($SUDO sed -n 's/^root=//p' "$MINISERV" | head -1)"
WVAR="$($SUDO cat /etc/webmin/var-path 2>/dev/null || echo /var/webmin)"
[ -r "$WROOT/status/status-lib.pl" ] || die "Webmin's status module not found under '$WROOT'"
log "Webmin    : $WROOT  (version $(cat "$WROOT/version" 2>/dev/null || echo '?'))"
_summary
echo

# --- monitors + schedule, through Webmin's own status-lib.pl ----------------
# (writes /etc/webmin/status/services/mailsetup_*.serv and the module config,
# and creates/refreshes the module's cron job exactly as its UI does)
$SUDO env FOREIGN_MODULE_NAME=status FOREIGN_ROOT_DIRECTORY="$WROOT" \
    WEBMIN_CONFIG=/etc/webmin WEBMIN_VAR="$WVAR" \
    MS_EMAIL="$EMAIL" MS_EVERY="$EVERY" MS_QMAX="$QMAX" MS_FAILS="$FAILS" \
    MS_WEBHOOK="$WEBHOOK" \
    perl - <<'PERL'
$no_acl_check++;
chdir("$ENV{FOREIGN_ROOT_DIRECTORY}/status") || die "chdir: $!\n";
require './status-lib.pl';

# config first: it decides whether the webhook notify mode exists
$config{'sched_mode'}   = 1;
$config{'sched_period'} = 0;               # minutes
$config{'sched_int'}    = $ENV{MS_EVERY};
$config{'sched_offset'} = 0;
$config{'sched_warn'}   = 1;               # when a service changes status
$config{'sched_single'} = 0;
$config{'sched_email'}  = $ENV{MS_EMAIL};
delete($config{'sched_smtp'});             # the local MTA, not a relay
if ($ENV{MS_WEBHOOK} eq 'off') { delete($config{'sched_webhook'}); }
elsif ($ENV{MS_WEBHOOK} ne '') { $config{'sched_webhook'} = $ENV{MS_WEBHOOK}; }
&lock_file("$module_config_directory/config");
&save_module_config();
&unlock_file("$module_config_directory/config");
&setup_cron_job();

my $notify = $config{'sched_webhook'} ? 'email webhook' : 'email';
my @have = grep { $_->{'id'} !~ /^mailsetup_/ } &list_services();  # seeds defaults on first use
my %have = map { $_->{'type'}, $_->{'desc'} } @have;
my @mine = ( { 'id' => 'mailsetup_mailq', 'type' => 'mailq',
               'desc' => 'Mail queue (mail-setup)', 'mod' => 'postfix',
               'size' => $ENV{MS_QMAX}, 'fails' => $ENV{MS_FAILS} } );
push(@mine, { 'id' => 'mailsetup_postfix', 'type' => 'postfix',
              'desc' => 'Postfix server (mail-setup)', 'fails' => 1 });
push(@mine, { 'id' => 'mailsetup_dovecot', 'type' => 'dovecot',
              'desc' => 'Dovecot server (mail-setup)', 'fails' => 1 })
    if (&foreign_installed('dovecot'));
foreach my $s (@mine) {
    my $f = "$services_dir/$s->{'id'}.serv";
    if ($have{$s->{'type'}}) {
        # Webmin already watches this (e.g. its default "Postfix Server"):
        # don't double up - and drop ours if an earlier run added it
        &unlink_file($f) if (-e $f);
        printf "  monitor   : %-28s already watched by \"%s\"\n", $s->{'desc'}, $have{$s->{'type'}};
        next;
        }
    $s->{'notify'}  = $notify;
    $s->{'nosched'} = 0;
    $s->{'remote'}  = '*';
    &save_service($s);
    }

# warn if Webmin would send its alerts through an outside SMTP server
&foreign_require('mailboxes', 'mailboxes-lib.pl');
my %mb = &foreign_config('mailboxes');
if ($mb{'send_mode'} && $mb{'send_mode'} !~ /^(localhost|127\.0\.0\.1|::1)$/) {
    print "WARN: Webmin sends mail via SMTP server '$mb{'send_mode'}' (Webmin -> Read User Mail ->\n",
          "      Module Config).  Set it to 'Mail server program' so alerts don't depend on it.\n";
    }

# check everything once now
foreach my $s (grep { $_->{'type'} =~ /^(mailq|postfix|dovecot)$/ } &list_services()) {
    my $st = &service_status($s);
    my $up = $st->{'up'} == 1 ? 'up' : $st->{'up'} == 0 ? 'DOWN' : 'unknown';
    printf "  status    : %-28s %-7s %s\n", $s->{'desc'}, $up, $st->{'desc'};
    }
PERL
log "status module: checking every $EVERY min, alerts to $EMAIL"

# --- who may reach Webmin --------------------------------------------------
if [ -n "$ALLOW" ]; then
    $SUDO sed -i '/^allow=/d' "$MINISERV"
    if [ "$ALLOW" = all ]; then
        log "webmin: open to anyone who can reach port 10000"
    else
        printf 'allow=127.0.0.1 ::1 %s\n' "$ALLOW_NET" | $SUDO tee -a "$MINISERV" >/dev/null
        log "webmin: only localhost + $ALLOW_NET may connect"
    fi
    $SUDO /etc/webmin/restart >/dev/null 2>&1 || warn "couldn't restart Webmin - run: sudo /etc/webmin/restart"
fi

echo
log "Webmin: https://$(hostname -f 2>/dev/null || hostname):10000/  -> Tools -> System and Server Status"
log "Run the checks now (mails only on a change):  sudo /etc/webmin/status/monitor.pl"
log "done."
