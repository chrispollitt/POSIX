#!/usr/bin/env bash
#
# configure-sieve.sh
#
# Let a mail client edit a Sieve "vacation" (out-of-office) script on the master
# over ManageSieve - tvmail's  File > Out of office...  is the user.  A reply
# has to be sent by the machine that receives the mail, so the script lives on
# the master and runs there when mail is delivered.
#
# Linux only, on the master (the box that runs Postfix + Dovecot - see
# configure-sendmail-relay.sh and configure-dovecot.sh).  Does four things:
#
#   1. installs Dovecot's Sieve parts (Pigeonhole: sieve + managesieve);
#   2. writes ONE drop-in, /etc/dovecot/conf.d/95-mail-setup-sieve.conf, that
#      turns on managesieve (port 4190, STARTTLS) and the Sieve plugin in the
#      LDA.  It is checked with doveconf before Dovecot is reloaded; if the
#      check fails, the previous drop-in is put back.  Handles both config
#      syntaxes (Dovecot 2.3 and 2.4);
#   3. makes Postfix deliver local mail through dovecot-lda (mailbox_command),
#      because Sieve only runs for mail Dovecot delivers.  Postfix local(8)
#      writing /var/mail directly bypasses it.  pop-pull, getmail and the
#      sendmail shim all hand mail to Postfix, so this one setting covers them,
#      and mail still lands in the same /var/mail/<user> that IMAP reads;
#   4. opens port 4190 in ufw if ufw is active; if an nftables input chain
#      drops by default and has no rule for 4190, says which rule to add
#      (clients would just time out) and adds it with --open-firewall;
#      then reloads both daemons.
#
# TLS: the distro's self-signed Dovecot cert is left as is, as in
# configure-dovecot.sh.
#
# Re-runnable.  An older tvmail-era drop-in (95-tvmail-sieve.conf) is replaced.
#
# Usage:
#   sudo ./configure-sieve.sh [options]
#
# Options:
#   --listen all|local  managesieve on every interface (LAN clients such as
#                       tvmail on another machine; default) or localhost only
#   --force             replace an existing Postfix mailbox_command
#   --open-firewall     add the nftables rule for 4190 now (runtime only - it is
#                       gone when nftables reloads; the message says how to keep it)
#   --firewall-plan     just print the nftables rule(s) that would open 4190, one
#                       per line, and exit - no root, nothing changed.  Reads
#                       `nft list ruleset`, or the file in $MAIL_SETUP_NFT_RULESET
#   --print VERSION     just print the drop-in for Dovecot VERSION (2.3 / 2.4)
#                       to stdout - no root, no Linux, nothing changed (tests)
#   -h | --help         show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/../lib/common.sh"

LISTEN=all
FORCE=0
OPEN_FW=0
FW_PLAN=0
PRINT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --listen)  LISTEN="${2:?}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    --open-firewall) OPEN_FW=1; shift ;;
    --firewall-plan) FW_PLAN=1; shift ;;
    --print)   PRINT="${2:?}"; shift 2 ;;
    -h|--help) usage "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$LISTEN" in all|local) : ;; *) die "--listen must be all or local" ;; esac

syntax_of() {   # syntax_of VERSION -> 23 | 24, or fail
  case "$1" in
    2.3*|2.2*) echo 23 ;;
    2.4*|2.5*) echo 24 ;;
    *) return 1 ;;
  esac
}

# dropin SYNTAX(23|24) VERSION [NEED_PROTOCOL NEED_PRIV NEED_POSTMASTER]
#   -> the 95-mail-setup-sieve.conf text on stdout.  The NEED_* flags (default
#   1) say whether this box's other config already sets that, so we don't
#   repeat it; --print always shows the full set.
dropin() {
  local syn=$1 ver=$2 needproto=${3:-1} needpriv=${4:-1} needpm=${5:-1} svc
  svc='service managesieve-login {
  inet_listener sieve {
    port = 4190'
  [ "$LISTEN" = local ] && svc="$svc
    address = 127.0.0.1, ::1"
  svc="$svc
  }
}"
  cat <<EOF
# 95-mail-setup-sieve.conf - generated $(date) by mail-setup's configure-sieve.sh
# (Dovecot $ver).  Re-run that script rather than editing this by hand.
#
# managesieve (port 4190, STARTTLS) so a client can edit the vacation script,
# and the Sieve plugin in the LDA so it runs when Postfix hands mail over.

EOF
  if [ "$syn" = 23 ]; then
    [ "$needproto" = 1 ] && printf 'protocols = $protocols sieve\n\n'
    [ "$needpriv" = 1 ] && printf '# lets the LDA dot-lock /var/mail (as the user, it is group mail only)\nmail_privileged_group = mail\n\n'
    [ "$needpm" = 1 ] && printf 'postmaster_address = postmaster@%s\n\n' "$(hostname -f 2>/dev/null || hostname)"
    cat <<EOF
$svc

protocol lda {
  mail_plugins = \$mail_plugins sieve
}

plugin {
  sieve = file:~/sieve;active=~/.dovecot.sieve
}
EOF
  else
    [ "$needproto" = 1 ] && printf 'protocols {\n  sieve = yes\n}\n\n'
    [ "$needpriv" = 1 ] && printf 'mail_privileged_group = mail\n\n'
    [ "$needpm" = 1 ] && printf 'postmaster_address = postmaster@%s\n\n' "$(hostname -f 2>/dev/null || hostname)"
    cat <<EOF
$svc

protocol lda {
  mail_plugins {
    sieve = yes
  }
}

sieve_script personal {
  driver = file
  path = ~/sieve
  active_path = ~/.dovecot.sieve
}
EOF
  fi
}

# --------------------------------------------------------------------------
# firewall helpers.  A default-drop nftables input chain silently eats 4190:
# the client just times out.  Rather than guess at a hand-written ruleset we
# open 4190 wherever IMAP (143/993) is already accepted - same interface, same
# chain - and by default only SAY so.
# --------------------------------------------------------------------------
fw_ruleset() {   # the nftables ruleset text on stdout (empty if there is none)
  if [ -n "${MAIL_SETUP_NFT_RULESET:-}" ]; then cat "$MAIL_SETUP_NFT_RULESET" 2>/dev/null || true
  elif command -v nft >/dev/null 2>&1; then ${SUDO:-} nft list ruleset 2>/dev/null || true
  fi
}

# fw_plan: ruleset on stdin -> one TAB line per place to open:
#   family  table  chain  interface   (interface "-": IMAP rule had none)
fw_plan() {
  awk '
    function has(line, p) { return (" " line " ") ~ ("[^0-9]" p "[^0-9]") }
    /^table / { fam = $2; tbl = $3; chain = ""; next }
    /^[ \t]*chain / { chain = $2; hook = 0; drop = 0; ok = 0; n = 0; split("", seen); next }
    chain != "" && /type filter hook input/ { hook = 1; drop = ($0 ~ /policy drop/); next }
    chain != "" && hook && drop && /tcp dport/ && /accept/ {
      if (has($0, "4190")) ok = 1
      else if (has($0, "143") || has($0, "993")) {
        iface = "-"
        if (match($0, /iifname "[^"]+"/)) iface = substr($0, RSTART + 9, RLENGTH - 10)
        if (!(iface in seen)) { seen[iface] = 1; order[++n] = iface }
      }
      next
    }
    /^[ \t]*}/ && chain != "" {
      if (hook && drop && !ok) {
        if (n == 0) printf "%s\t%s\t%s\t-\n", fam, tbl, chain
        for (i = 1; i <= n; i++) printf "%s\t%s\t%s\t%s\n", fam, tbl, chain, order[i]
      }
      chain = ""
    }'
}

# fw_rules: plan -> "interface<TAB>nft command" lines
fw_rules() {
  local fam tbl chain iif
  while IFS=$'\t' read -r fam tbl chain iif; do
    [ -n "$fam" ] || continue
    # names come from the ruleset text and end up in a command line: plain only
    case "$fam$tbl$chain$iif" in *[!A-Za-z0-9_.@:-]*) continue ;; esac
    if [ "$iif" = - ]; then
      printf '%s\t%s\n' - "nft add rule $fam $tbl $chain tcp dport 4190 accept"
    else
      printf '%s\t%s\n' "$iif" "nft add rule $fam $tbl $chain iifname \"$iif\" tcp dport 4190 accept"
    fi
  done
}

if [ -n "$PRINT" ]; then
  syn=$(syntax_of "$PRINT") || die "unsupported Dovecot version '$PRINT' (need 2.3 or 2.4)"
  dropin "$syn" "$PRINT"
  exit 0
fi
if [ "$FW_PLAN" = 1 ]; then
  fw_ruleset | fw_plan | fw_rules | cut -f2
  exit 0
fi

[ "$IS_LINUX" = 1 ] || die "Linux only - run this on the mail master (Postfix + Dovecot)"
if [ "$(id -u)" != 0 ] && [ -z "$SUDO" ]; then die "run as root (no sudo found)"; fi
command -v dovecot >/dev/null 2>&1 \
  || die "Dovecot is not installed here - this is for the mail master (run configure-dovecot.sh first)"
command -v postconf >/dev/null 2>&1 \
  || die "Postfix (postconf) is not installed here (run configure-sendmail-relay.sh first)"

# --------------------------------------------------------------------------
# 1. packages
# --------------------------------------------------------------------------
have_pigeonhole() {
  ls /usr/lib/dovecot/modules/lib90_sieve_plugin.so /usr/lib*/dovecot/modules/lib90_sieve_plugin.so \
     /usr/lib/dovecot/managesieve /usr/lib*/dovecot/managesieve >/dev/null 2>&1
}
if ! have_pigeonhole; then
  log "installing Dovecot Sieve (Pigeonhole) ..."
  case "$PKG" in
    apt)       pkg_install dovecot-sieve dovecot-managesieved ;;
    dnf|yum)   pkg_install dovecot-pigeonhole ;;
    pacman)    pkg_install pigeonhole ;;
    *) die "no known package manager - install Pigeonhole (dovecot sieve + managesieve) by hand, then re-run" ;;
  esac
fi

# --------------------------------------------------------------------------
# 2. the Dovecot drop-in
# --------------------------------------------------------------------------
VER="$(dovecot --version 2>/dev/null | awk '{print $1}')"
SYNTAX=$(syntax_of "$VER") || die "unsupported Dovecot version '${VER:-?}' (need 2.3 or 2.4)"
log "dovecot     : $VER"

CONF=/etc/dovecot/dovecot.conf
DROPIN=/etc/dovecot/conf.d/95-mail-setup-sieve.conf
LEGACY=/etc/dovecot/conf.d/95-tvmail-sieve.conf     # tvmail's old enable-managesieve.sh
$SUDO test -r "$CONF" || die "$CONF not found"
$SUDO grep -Eq '^[[:space:]]*!include[_try]*[[:space:]]+conf\.d/\*\.conf' "$CONF" \
  || die "$CONF doesn't !include conf.d/*.conf - add that line, then re-run"

# Judge "already set" without our own earlier drop-ins (current and legacy):
# move them aside, put them back if the new one is rejected.
stamp=$(date +%Y%m%d-%H%M%S)
aside=""      # "orig=backup" pairs, space-separated (paths have no spaces)
for f in "$DROPIN" "$LEGACY"; do
  if $SUDO test -e "$f"; then
    $SUDO cp -p "$f" "$f.bak.$stamp"
    $SUDO rm -f "$f"
    aside="$aside $f=$f.bak.$stamp"
    log "backed up existing $f"
  fi
done
restore() {
  for p in $aside; do $SUDO cp -p "${p#*=}" "${p%%=*}"; done
}

needproto=1; $SUDO doveconf -h protocols 2>/dev/null | tr ' ' '\n' | grep -qx sieve && needproto=0
needpriv=1;  [ -n "$($SUDO doveconf -h mail_privileged_group 2>/dev/null || true)" ] && needpriv=0
needpm=1;    [ -n "$($SUDO doveconf -h postmaster_address 2>/dev/null || true)" ] && needpm=0

tmp=$(mktemp)
dropin "$SYNTAX" "$VER" "$needproto" "$needpriv" "$needpm" > "$tmp"
$SUDO install -m 0644 "$tmp" "$DROPIN"; rm -f "$tmp"
if ! err="$($SUDO doveconf -n 2>&1 >/dev/null)"; then
  $SUDO rm -f "$DROPIN"; restore
  die "doveconf rejected the new config (put the old one back):
$err"
fi
log "wrote $DROPIN  (doveconf: ok)"

# --------------------------------------------------------------------------
# 3. Postfix -> dovecot-lda
# --------------------------------------------------------------------------
LDA=""
for c in /usr/lib/dovecot/dovecot-lda /usr/libexec/dovecot/dovecot-lda /usr/lib64/dovecot/dovecot-lda; do
  [ -x "$c" ] && { LDA=$c; break; }
done
[ -n "$LDA" ] || LDA="$(command -v dovecot-lda || true)"
[ -n "$LDA" ] || die "dovecot-lda not found - is the dovecot-core package complete?"
WANT="$LDA -f \"\$SENDER\" -a \"\$RECIPIENT\""
CUR="$($SUDO postconf -h mailbox_command)"
if [ "$CUR" = "$WANT" ]; then
  log "postfix     : mailbox_command already delivers through dovecot-lda"
else
  if [ -n "$CUR" ] && [ "$FORCE" = 0 ]; then
    die "Postfix already has  mailbox_command = $CUR
  Replacing it would stop that filter running.  Re-run with --force if that is what you want."
  fi
  backup /etc/postfix/main.cf sudo
  $SUDO postconf -e "mailbox_command = $WANT"
  log "postfix     : mailbox_command = $WANT"
fi

# --------------------------------------------------------------------------
# 4. firewall, reload
# --------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q '^Status: active'; then
  $SUDO ufw allow 4190/tcp >/dev/null && log "ufw         : allowed 4190/tcp"
fi
FW_RULES="$(fw_ruleset | fw_plan | fw_rules)"
if [ -n "$FW_RULES" ]; then
  while IFS=$'\t' read -r iif cmd; do
    if [ "$OPEN_FW" = 1 ] && [ "$iif" != - ]; then
      eval "$SUDO $cmd" && log "nftables    : opened 4190 on $iif  ($cmd)"   # names vetted in fw_rules
    elif [ "$iif" = - ]; then
      warn "nftables drops 4190 by default; no interface could be inferred from the IMAP rules."
      warn "  to open it (on EVERY interface - narrow it with iifname \"...\"):  $cmd"
    else
      warn "nftables drops 4190 by default on $iif, so clients will just time out."
      warn "  open it now:  $cmd      (or re-run with --open-firewall)"
    fi
  done <<<"$FW_RULES"
  warn "A runtime rule is lost when nftables reloads.  To keep it, add 4190 to the same rule"
  warn "  that accepts 143/993 in your ruleset file (often /etc/nftables.conf), check it with"
  warn "  'nft -c -f FILE', and leave the live rule as it is until the next boot."
fi
if command -v iptables >/dev/null 2>&1 && $SUDO iptables -S INPUT 2>/dev/null | grep -q '^-P INPUT DROP'; then
  warn "iptables drops by default; if clients time out on 4190:  iptables -A INPUT -p tcp --dport 4190 -j ACCEPT"
fi
if [ -d /run/systemd/system ]; then
  $SUDO systemctl restart dovecot
  $SUDO systemctl reload postfix 2>/dev/null || $SUDO systemctl restart postfix
else
  $SUDO service dovecot restart
  $SUDO service postfix reload || $SUDO service postfix restart
fi
sleep 1

if (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ':4190 '; then
  log "managesieve : listening on 4190"
else
  warn "nothing is listening on 4190; check 'journalctl -u dovecot'"
fi

cat <<'EOF'

Done.  To check it end to end:

  1. From your tvmail machine:   tvmail-backend vacation status
       -> "state: none"  (it logged in to managesieve and found no script)
  2. In tvmail:  File > Out of office...  switch it on, Save.
  3. From another account / address, mail yourself, then watch:
       sudo journalctl -u dovecot -u postfix -f      (or  tail -f /var/log/mail.log)
     You should see dovecot-lda run the script and Postfix send the reply.

If a reply never comes: the message was probably not addressed to one of the
addresses in the dialog's "Addresses" line - mail fetched from a POP account is
addressed to the public address, not to the local user.  See tvmail's INSTALL.md,
"Out of office".
EOF
