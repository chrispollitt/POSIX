#!/usr/bin/env bash
#
# configure-sendmail-relay.sh
#
# Configure Postfix as a send-only sendmail: local mail -> /var/mail,
# everything else -> an authenticated TLS smarthost, with locally generated
# senders rewritten to the real mailbox (this box can't receive replies).
# Addresses LAN clients qualify with their own hostname (chris@laptop - any
# domain without a dot) are treated as this box, so they deliver here and
# leave as the real mailbox too.
# Delivery failures are reported locally: the sender is warned after 1h
# stuck in the queue, and postmaster (-> root -> --user) gets a copy of every
# bounce / delay notice.  For a watchdog on top, see configure-webmin.sh.
#
# Linux only - the mail master role (the one host that owns /var/mail) is
# meant for a Linux/Pi box.  If Postfix isn't installed, apt-installs it.
# You're asked whether to run it as a service (systemd / sysv / none).
#
# Per-user senders (--plus-users): by default EVERY local sender is rewritten
# to the one mailbox address, so replies to chris and to miche both land in the
# shared inbox with nothing to tell them apart.  With --plus-users chris,miche
# the generic map also gets one line per user, using plus-addresses of the
# shared mailbox:
#     chris@HOST   cwp+chris@u-l.ca
#     miche@HOST   cwp+miche@u-l.ca
# while root and other system/local senders keep the shared catch-all
# (@HOST -> cwp@u-l.ca).  Postfix tries user@domain before @domain, so the
# specific lines win.  The inbound half is getmail --imap --plus-base (see
# configure-getmail.sh), which fetches each user's tag folder.  This needs the
# smarthost to accept a +tag sender - check with
# tests/live/check-plus-addressing.py before relying on it.
#
# Loud and proud: a header_checks table stamps every locally submitted message
# (sendmail(1), cron, mail(1), tvmail ...) with
#     X-Relayed-By: Postfix 3.9.1 on cpbee (submitted by chris, uid 1000)
# by reading Postfix's own "Received: by HOST (Postfix, from userid N)" line.
# This happens at submission, BEFORE smtp_generic_maps rewrites the sender to
# the real mailbox on the way out, so the original local user and host survive
# the rewrite.  Mail that comes in over SMTP is not touched.  An existing
# header_checks setting is kept (ours is appended to the list).
#
# The new map is test-built (postmap) in a temp dir before anything under
# /etc/postfix is touched; after install it is looked up and `postfix check`ed
# before Postfix is reloaded, and the previous map is put back if that fails.
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
#   --lan CIDR|auto     accept mail from LAN clients: listen on all interfaces
#                       and trust CIDR (mynetworks) - 'auto' = this box's own
#                       IPv4 network, e.g. 192.168.1.0/24.  LAN clients then
#                       send through here on port 25 with no password.
#   --no-lan            back to loopback-only (the default on a fresh setup;
#                       a re-run without either flag keeps what's there)
#   --plus-users LIST   comma-separated local users that get their own sender
#                       address BASE+USER@domain (see above)
#   --plus-base ADDR    plain shared address to tag (default: the smarthost
#                       login, e.g. cwp@u-l.ca)
#   --print             just print the generic map to stdout - no root, no
#                       Linux, nothing changed (used by the tests)
#   --print-header-checks   same, for the header_checks table
#   --fqdn NAME         use NAME instead of `hostname -f` (mainly with --print)
#   --cron              add a 15-minute queue-runner cron entry (send-only mode)
#   --test ADDR         after configuring, send a test message to ADDR and you
#   -h | --help         show this header.
#
set -euo pipefail

RELAY_FILE=""
ADMIN_USER="${SUDO_USER:-$(id -un)}"     # under sudo: whoever ran sudo
ADD_CRON=0
TEST_ADDR=""
SERVICE=""
SMTP_PORT=""
LAN=""           # "" = keep / fresh default, CIDR, or "off"
PLUS_USERS=""
PLUS_BASE=""
PRINT=0
PRINT_HC=0
FQDN_OPT=""
# tests point these into a sandbox
PF_DIR="${MAIL_SETUP_POSTFIX_DIR:-/etc/postfix}"
ALIASES="${MAIL_SETUP_ALIASES:-/etc/aliases}"

while [ $# -gt 0 ]; do
  case "$1" in
    --relay-file)  RELAY_FILE="${2:?}"; shift 2 ;;
    --user)        ADMIN_USER="${2:?}"; shift 2 ;;
    --service)     SERVICE="${2:?}";    shift 2 ;;
    --smtp-port)   SMTP_PORT="${2:?}";  shift 2 ;;
    --rewrite-all) shift ;;   # deprecated no-op: outbound From is always rewritten now
    --lan)         LAN="${2:?}"; shift 2 ;;
    --no-lan)      LAN=off; shift ;;
    --plus-users)  PLUS_USERS="${2:?}"; shift 2 ;;
    --plus-base)   PLUS_BASE="${2:?}";  shift 2 ;;
    --print)       PRINT=1; shift ;;
    --print-header-checks) PRINT=1; PRINT_HC=1; shift ;;
    --fqdn)        FQDN_OPT="${2:?}";   shift 2 ;;
    --cron)        ADD_CRON=1; shift ;;
    --test)        TEST_ADDR="${2:?}"; shift 2 ;;
    -h|--help)     sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../lib/common.sh"      # log/warn/die, lan_cidr

[ "$PRINT" = 1 ] || [ "$(uname -s 2>/dev/null)" = Linux ] || die \
"Linux only - Postfix isn't available on $(uname -s 2>/dev/null || echo 'this OS').
  The mail master role (the box that owns /var/mail) is meant for a Linux/Pi
  box; point a client at it instead with:  mail-setup.sh --role client"

_enable_service() {   # $1 = service name; uses $svc / $SUDO
    case "$svc" in
      systemd) $SUDO systemctl enable "$1" >/dev/null 2>&1 || true
               # restart, not just start: inet_interfaces changes need it
               $SUDO systemctl restart "$1"
               log "$1: enabled + running (systemd)" ;;
      sysv)    $SUDO update-rc.d "$1" defaults >/dev/null 2>&1 || true
               $SUDO service "$1" restart
               log "$1: enabled + running (sysv init)" ;;
      *)       $SUDO systemctl disable --now "$1" 2>/dev/null \
                 || $SUDO service "$1" stop 2>/dev/null || true
               log "$1: not run as a service" ;;
    esac
}

_cfg_lan() {   # who may submit mail without a password: loopback, or + the LAN
    local_nets='127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128'
    if [ -n "$LAN_NET" ]; then
        $SUDO postconf -e "inet_interfaces = all" "mynetworks = $local_nets $LAN_NET"
        log "postfix: LAN clients welcome - listening on all interfaces, trusting $LAN_NET"
        log "  (only expose port 25 to that LAN, never to the Internet)"
    elif [ "$LAN" = off ] || [ -z "$($SUDO postconf -n mynetworks 2>/dev/null)" ]; then
        # fresh setup, or asked for: this box only
        $SUDO postconf -e "inet_interfaces = loopback-only"
        $SUDO postconf -X mynetworks 2>/dev/null || true
        log "postfix: loopback-only (LAN clients: re-run with --lan auto)"
    else
        log "postfix: keeping $($SUDO postconf -n inet_interfaces 2>/dev/null || echo 'inet_interfaces = (default)'),"
        log "  $($SUDO postconf -n mynetworks)  (--no-lan resets to loopback-only)"
    fi
}

_names() {   # sets hn / fqdn / mh
    mh=""
    if [ -n "$FQDN_OPT" ]; then fqdn="$FQDN_OPT"; hn="${FQDN_OPT%%.*}"
    else
        hn="$(hostname 2>/dev/null || echo localhost)"
        fqdn="$(hostname -f 2>/dev/null || echo "$hn")"
        # LAN clients qualify addresses with their own hostname (see _cfg_postfix);
        # Postfix's own idea of this box's name gets a catch-all line too
        mh="$($SUDO postconf -h myhostname 2>/dev/null || true)"
    fi
}

# gen_generic -> the generic map text (for $PF_DIR/generic) on stdout.  Needs hn fqdn mh U
# ADMIN_USER, and PLUS_LIST / PLUS_LOCAL / PLUS_DOM from _plus_setup.
gen_generic() {
    echo "# generic - written $(date) by configure-sendmail-relay.sh; re-run it, don't edit"
    if [ -n "$PLUS_LIST" ]; then
        echo "# per-user senders (more specific than the @host lines below, so they win)"
        for u in $PLUS_LIST; do
            for d in "$fqdn" "$hn" localhost; do
                printf '%-36s %s\n' "${u}@${d}" "${PLUS_LOCAL}+${u}@${PLUS_DOM}"
            done | awk '!seen[$1]++'
        done
        echo "# everything else (root, system mail) shares the one mailbox address"
    fi
    { printf '@%-22s %s\n' "$hn" "$U"
      printf '@%-22s %s\n' "$fqdn" "$U"
      [ -z "$mh" ] || printf '@%-22s %s\n' "$mh" "$U"
      printf '@%-22s %s\n' localhost "$U"
      printf '@%-22s %s\n' localhost.localdomain "$U"
      printf '%-23s %s\n' root@localhost "$U"
    } | awk '!seen[$1]++'
    case " $PLUS_LIST " in
      *" $ADMIN_USER "*) : ;;     # already has its own line above
      *) printf '%-23s %s\n' "${ADMIN_USER}@localhost" "$U" ;;
    esac
}

# gen_header_checks -> the header_checks table (for $PF_DIR/header_checks) on
# stdout.  Needs fqdn/hn from _names.  One rule per local account (uid 0 and
# >= 1000, from getent passwd or $MAIL_SETUP_PASSWD) so the user NAME is
# recorded, then a catch-all rule that records the bare uid.
gen_header_checks() {
    ver="$(postconf -h mail_version 2>/dev/null || true)"
    tool="Postfix${ver:+ $ver}"
    echo "# header_checks - written $(date) by configure-sendmail-relay.sh; re-run it, don't edit"
    echo "# stamp locally submitted mail with who sent it and from where (see the script's header)"
    { if [ -n "${MAIL_SETUP_PASSWD:-}" ]; then cat "$MAIL_SETUP_PASSWD" 2>/dev/null
      else getent passwd 2>/dev/null; fi
    } | awk -F: '$1 ~ /^[a-z_][a-z0-9._-]*$/ && ($3 == 0 || ($3 >= 1000 && $3 < 60000)) { print $1, $3 }' \
      | while read -r name uid; do
          printf '/^Received: by ([^ ]+) \\(Postfix, from userid %s\\)/ PREPEND X-Relayed-By: %s on ${1} (submitted by %s, uid %s)\n' \
              "$uid" "$tool" "$name" "$uid"
        done
    printf '/^Received: by ([^ ]+) \\(Postfix, from userid ([0-9]+)\\)/ PREPEND X-Relayed-By: %s on ${1} (submitted by uid ${2})\n' "$tool"
}

# _install_header_checks - install the table, check that Postfix really reads
# it, then add it to header_checks.  Cosmetic, so a problem only warns.
_install_header_checks() {
    hc="$PF_DIR/header_checks"; old=""
    tmp="$(mktemp)"; gen_header_checks > "$tmp"
    if $SUDO test -e "$hc"; then
        old="$hc.bak.$(date +%Y%m%d-%H%M%S)"; $SUDO cp -p "$hc" "$old"
        log "backed up existing $hc"
    fi
    $SUDO install -m 0644 "$tmp" "$hc"; rm -f "$tmp"
    uid="$(id -u "$ADMIN_USER" 2>/dev/null || echo 1000)"
    got="$($SUDO postmap -q "Received: by $hn (Postfix, from userid $uid)" "regexp:$hc" 2>/dev/null || true)"
    case "$got" in
      "PREPEND X-Relayed-By: "*) : ;;
      *) if [ -n "$old" ]; then $SUDO cp -p "$old" "$hc"; else $SUDO rm -f "$hc"; fi
         warn "Postfix did not read the new $hc as expected (got '${got}') - header stamping left off"
         return 0 ;;
    esac
    cur="$($SUDO postconf -h header_checks 2>/dev/null || true)"
    case "$cur" in
      *"$hc"*) : ;;
      "")      $SUDO postconf -e "header_checks = regexp:$hc" ;;
      *)       $SUDO postconf -e "header_checks = $cur, regexp:$hc" ;;
    esac
    log "postfix: local mail is stamped  X-Relayed-By: ${tool:-Postfix} on $hn (submitted by USER, uid N)"
}

# validate --plus-users / --plus-base -> PLUS_LIST (space separated), PLUS_LOCAL, PLUS_DOM
_plus_setup() {
    PLUS_LIST=""; PLUS_LOCAL=""; PLUS_DOM=""
    [ -n "$PLUS_USERS" ] || { [ -z "$PLUS_BASE" ] || die "--plus-base only makes sense with --plus-users"; return 0; }
    b="${PLUS_BASE:-$U}"
    case "$b" in
      *+*|*[[:space:]]*|*@*@*|@*|*@) die "plus base '$b' must be a plain address like cwp@u-l.ca (use --plus-base)" ;;
      *@*) : ;;
      *)   die "plus base '$b' must be a plain address like cwp@u-l.ca (use --plus-base)" ;;
    esac
    PLUS_LOCAL="${b%@*}"; PLUS_DOM="${b#*@}"
    for u in $(echo "$PLUS_USERS" | tr ',' ' '); do
        case "$u" in
          root) die "--plus-users: root's mail stays on the shared address - leave it out" ;;
          *[!a-z0-9._-]*|-*) die "--plus-users: '$u' isn't a plain lower-case login name" ;;
        esac
        case " $PLUS_LIST " in *" $u "*) : ;; *) PLUS_LIST="$PLUS_LIST $u" ;; esac
    done
    PLUS_LIST="${PLUS_LIST# }"
}

# _prebuild_generic - build the new map in a temp dir first; a map postmap
# rejects aborts the run before anything under $PF_DIR has been touched
_prebuild_generic() {
    gdir="$(mktemp -d)"; trap 'rm -rf "$gdir"' EXIT
    gen_generic > "$gdir/generic"
    postmap "hash:$gdir/generic" || die "postmap rejected the new generic map - nothing was changed"
}

# _install_generic - install the prebuilt map, verify it, roll back on failure
_install_generic() {
    g="$PF_DIR/generic"; old=""
    if $SUDO test -e "$g"; then
        old="$g.bak.$(date +%Y%m%d-%H%M%S)"
        $SUDO cp -p "$g" "$old"
        $SUDO test -e "$g.db" && $SUDO cp -p "$g.db" "$old.db"
        log "backed up existing $g"
    fi
    $SUDO install -m 0644 "$gdir/generic" "$g"
    bad=""
    $SUDO postmap "hash:$g" || bad="postmap failed on $g"
    if [ -z "$bad" ]; then
        for u in $PLUS_LIST; do
            got="$($SUDO postmap -q "${u}@${fqdn}" "hash:$g" 2>/dev/null || true)"
            [ "$got" = "${PLUS_LOCAL}+${u}@${PLUS_DOM}" ] || bad="lookup of ${u}@${fqdn} gave '${got}'"
        done
    fi
    [ -n "$bad" ] || { err="$($SUDO postfix check 2>&1)" || bad="postfix check: $err"; }
    if [ -n "$bad" ]; then
        if [ -n "$old" ]; then
            $SUDO cp -p "$old" "$g"; $SUDO test -e "$old.db" && $SUDO cp -p "$old.db" "$g.db"
        else
            $SUDO rm -f "$g" "$g.db"
        fi
        die "new generic map rejected ($bad) - put the old one back"
    fi
}

_cfg_postfix() {   # configure an already-installed Postfix as a smarthost relay
    _names
    _prebuild_generic
    # installed but never configured (debconf "No configuration"): no main.cf,
    # and postconf -e refuses to create one
    if [ ! -e $PF_DIR/main.cf ]; then
        if [ -r /usr/share/postfix/main.cf.debian ]; then
            $SUDO cp /usr/share/postfix/main.cf.debian $PF_DIR/main.cf
        else
            $SUDO touch $PF_DIR/main.cf
        fi
        log "postfix: had no main.cf - started from the distro default"
    fi
    # myorigin = $myhostname: a bare "chris" / "root" must stay chris@<this box>
    # and be delivered HERE.  Debian's default (/etc/mailname) is often the
    # public domain, which turns local mail into chris@that-domain and relays
    # it out - where it bounces ("No Such User").  Outbound mail still leaves
    # as the real mailbox via the generic map below.
    $SUDO postconf -e \
      "relayhost = [${H}]:${PORT}" \
      "smtp_sasl_auth_enable = yes" \
      "smtp_sasl_password_maps = hash:$PF_DIR/sasl_passwd" \
      "smtp_sasl_security_options = noanonymous" \
      "smtp_sasl_tls_security_options = noanonymous" \
      "smtp_tls_security_level = encrypt" \
      "smtp_tls_wrappermode = ${WRAP}" \
      "smtp_use_tls = yes" \
      "smtp_generic_maps = hash:$PF_DIR/generic" \
      "mydestination = \$myhostname, localhost.\$mydomain, localhost" \
      "myorigin = \$myhostname" \
      "alias_maps = hash:$ALIASES" \
      "alias_database = hash:$ALIASES"
    # Failure notices, all delivered locally (postmaster -> root -> you), so
    # they still arrive when the smarthost is the thing that's broken:
    #  - senders hear after 1h that a message is stuck, not after the 5-day
    #    bounce (default: never warned)
    #  - postmaster gets a copy (headers only) of every bounce, delay warning
    #    and undeliverable bounce - covers LAN clients' mail and daemons too
    $SUDO postconf -e \
      "delay_warning_time = 1h" \
      "notify_classes = resource, software, bounce, delay, 2bounce"
    if [ "$reuse" = 0 ]; then
        printf '[%s]:%s %s:%s\n' "$H" "$PORT" "$U" "$P" | $SUDO tee $PF_DIR/sasl_passwd >/dev/null
        $SUDO chmod 600 $PF_DIR/sasl_passwd
    elif ! $SUDO grep -q "^\[${H}\]:${PORT}[[:space:]]" $PF_DIR/sasl_passwd; then
        # reusing the stored password, but the host/port changed: Postfix
        # looks it up by the exact "[host]:port" key, so re-key that line
        $SUDO sed -i "s|^\[[^]]*\]:[0-9]*\([[:space:]][[:space:]]*${U}:\)|[${H}]:${PORT}\1|" \
            $PF_DIR/sasl_passwd
        $SUDO grep -q "^\[${H}\]:${PORT}[[:space:]]" $PF_DIR/sasl_passwd \
            && log "sasl_passwd: ${U} now keyed to [${H}]:${PORT}" \
            || warn "sasl_passwd has no line for ${U} - re-run with the password (it'll ask)"
    fi
    $SUDO postmap $PF_DIR/sasl_passwd
    # The pullers (pop-pull, getmail via sasl-pass) run as you and read the
    # mailbox password from this same file - so it's root:<your group> 0640,
    # not root-only.  On Debian-style systems that group is just you.
    grp="$(id -gn "$ADMIN_USER" 2>/dev/null || echo root)"
    $SUDO chown "root:$grp" $PF_DIR/sasl_passwd $PF_DIR/sasl_passwd.db
    $SUDO chmod 640 $PF_DIR/sasl_passwd $PF_DIR/sasl_passwd.db
    log "sasl_passwd: root:$grp 0640 (readable by $ADMIN_USER's pullers)"
    # one-way rewrite: every locally originated address -> the real mailbox
    # (or, per user, its plus-address), applied only on outbound
    # (smtp_generic_maps).  Tested + verified, rolled back on failure.
    _install_generic
    _install_header_checks
    # LAN clients qualify addresses with their own hostname: "chris" sent
    # from the laptop arrives as chris@laptop - both as recipient (relayed
    # out, bounced) and as sender (the smarthost's sender verify rejects it).
    # A domain without a dot can't be delivered anywhere else, so treat it as
    # this box: chris@laptop -> chris@$myhostname (always in mydestination),
    # delivered here, and on the way out the generic map turns it into the
    # real mailbox.  Headers are rewritten for LAN clients too (by default
    # only for local submissions).
    # That name must have a dot: Delta Chat (and anything else strict) won't
    # take chris@cpbee as an address.  A short myhostname becomes the FQDN;
    # the short name stays in mydestination so mail still addressed to it is
    # delivered.
    mh="$($SUDO postconf -h myhostname 2>/dev/null || true)"
    case "$mh" in
      *.*) ;;
      *) case "$fqdn" in
           *.*) $SUDO postconf -e "myhostname = $fqdn" \
                  "mydestination = \$myhostname, ${mh:-$hn}, localhost.\$mydomain, localhost"
                log "postfix: myhostname ${mh:-$hn} -> $fqdn (addresses need a dot)"
                mh="$fqdn" ;;
           *) log "warning: no FQDN for this box (try --fqdn NAME): addresses will be user@${mh:-$hn}" ;;
         esac ;;
    esac
    printf '/^([^@]+)@[^.@]+$/    ${1}@%s\n' "$mh" | $SUDO tee $PF_DIR/lan-canonical >/dev/null
    $SUDO postconf -e \
      "canonical_maps = regexp:$PF_DIR/lan-canonical" \
      "local_header_rewrite_clients = permit_inet_interfaces, permit_mynetworks"
    $SUDO grep -qs '^root:' $ALIASES \
      || printf 'root: %s\n' "$ADMIN_USER" | $SUDO tee -a $ALIASES >/dev/null
    $SUDO grep -qs '^postmaster:' $ALIASES \
      || printf 'postmaster: root\n' | $SUDO tee -a $ALIASES >/dev/null
    $SUDO newaliases 2>/dev/null || true
    _cfg_lan
    log "postfix: relayhost=[${H}]:${PORT}, SASL+TLS, generic rewrite -> ${U}"
    [ -z "$PLUS_LIST" ] || log "  per-user senders: $(for u in $PLUS_LIST; do printf '%s ' "${PLUS_LOCAL}+${u}@${PLUS_DOM}"; done)"
    log "postfix: failure notices -> postmaster -> root -> ${ADMIN_USER} (stuck > 1h, bounces)"
    _enable_service postfix
    # pick up main.cf / map changes if it was already running
    if $SUDO postfix status >/dev/null 2>&1; then $SUDO postfix reload >/dev/null 2>&1 || true; fi
}

SUDO=""
if [ "${MAIL_SETUP_SUDO+set}" = set ]; then
    SUDO="$MAIL_SETUP_SUDO"      # tests set it empty so nothing ever escalates
elif [ "$PRINT" = 0 ] && [ "$(id -u)" != 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "run as root (no sudo found)"
    SUDO="sudo"
fi

_rv() { sed -n "s/^$1:[[:space:]]*//p" "$RELAY_FILE" 2>/dev/null | head -1 | tr -d ' \r'; }
H=""; U=""; P=""; PORT=""
if [ -n "$RELAY_FILE" ] && [ -f "$RELAY_FILE" ]; then
    H="$(_rv 'Outgoing Server')"; U="$(_rv Username)"; P="$(_rv Password)"
    PORT="$(sed -n 's/.*SMTP Port:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$RELAY_FILE" | head -1 | tr -d ' \r')"
fi
# No relay file on a re-run (e.g. just --lan): keep the smarthost Postfix
# already has, rather than falling back to the defaults below.
REUSED=0
if [ -z "$H" ] && command -v postconf >/dev/null 2>&1; then
    cur="$(postconf -h relayhost 2>/dev/null || true)"          # [host]:port
    if [ -n "$cur" ]; then
        H="${cur#[}"; H="${H%%]*}"
        case "$cur" in *]:*) PORT="${cur##*]:}" ;; esac
        U="$($SUDO awk -v k="$cur" '$1==k {split($2,a,":"); print a[1]; exit}' \
               $PF_DIR/sasl_passwd 2>/dev/null || true)"
        REUSED=1
        log "no relay file - keeping the current smarthost $cur${U:+ ($U)}"
    fi
fi
: "${H:=u-l.ca}"; : "${U:=cwp@u-l.ca}"
[ -n "$PORT" ] || PORT=587

[ -n "$SMTP_PORT" ] && PORT="$SMTP_PORT"
# 465 = SMTPS: TLS from the first byte (Postfix "wrapper mode");
# 587/25 = plain connect, then STARTTLS.  Some networks block one of them -
# check with:  timeout 5 bash -c 'exec 3<>/dev/tcp/HOST/PORT' && echo open
WRAP=no; [ "$PORT" = 465 ] && WRAP=yes

_plus_setup
if [ "$PRINT" = 1 ]; then
    _names
    if [ "$PRINT_HC" = 1 ]; then gen_header_checks; else gen_generic; fi
    exit 0
fi

LAN_NET=""
case "$LAN" in
  ""|off) : ;;
  auto) LAN_NET="$(lan_cidr)" || die "--lan auto: couldn't work out this box's network - give it, e.g. --lan 192.168.1.0/24" ;;
  *)    LAN_NET="$(cidr_check "$LAN")" || die "--lan: '$LAN' isn't an IPv4/IPv6 network (e.g. 192.168.1.0/24)" ;;
esac

if ! command -v postfix >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || die \
"Postfix not installed and no apt to add it.  Install postfix, then re-run this script."
    log "Postfix not found - installing ..."
    $SUDO apt-get update -qq || true
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y postfix >/dev/null || die \
"could not install postfix (EOL release / no network?).  Install it by hand."
fi
log "MTA       : postfix"

PW_STORE=$PF_DIR/sasl_passwd
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
log "smarthost : ${H}:${PORT}  ($( [ "$WRAP" = yes ] && echo 'TLS from connect' || echo STARTTLS ), AUTH)"
log "auth user : ${U}"
log "rewrite   : local senders -> ${U}   (on outbound only)"
[ -z "$PLUS_LIST" ] || log "per-user   : ${PLUS_LIST// /, } -> ${PLUS_LOCAL}+USER@${PLUS_DOM}"
log "service   : ${svc}"
log "root mail : ${ADMIN_USER}"
log "LAN       : $( [ -n "$LAN_NET" ] && echo "accept from $LAN_NET" || { [ "$LAN" = off ] && echo 'loopback-only' || echo 'unchanged (loopback-only on a fresh setup)'; } )"
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
