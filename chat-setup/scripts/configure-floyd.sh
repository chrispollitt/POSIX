#!/usr/bin/env bash
#
# configure-floyd.sh
#
# Give Floyd (tvchat's bot, tvmail's assistant) a home on the master (cpbee).
# Run it with sudo, on the master that runs Postfix + Dovecot + Ergo.  Does:
#
#   1. creates the system user "floyd" (home directory, no login shell) with a
#      random password, saved once in --password-file (mode 600).  An existing
#      user is left alone (and its password is not changed);
#   2. makes the mail puller fetch cwp+floyd@u-l.ca mail into that mailbox: on a
#      getmail --imap setup (configure-getmail.sh --plus-users) each tag has its
#      own getmail dir and a line in the puller's mail-pull wrapper, so this
#      clones the existing plus-TAG dir as plus-floyd (folder INBOX.floyd,
#      delivered to floyd) and adds the line.  mail-pull is backed up first.
#      If you later re-run configure-getmail.sh, add floyd to its --plus-users;
#   3. writes tvmail's configuration in ~floyd, so that mail is read with
#      `tvmail` (as floyd) through the master's own Dovecot:
#        ~floyd/.config/tvmail/tvmail.conf   IMAP + SMTP submission on localhost,
#                                            sending as "Floyd <cwp+floyd@u-l.ca>"
#        ~floyd/.netrc                       the login (mode 600, owned by floyd)
#      then logs in to IMAP as floyd to prove it works;
#   4. registers his IRC nick with NickServ on Ergo (its loopback plaintext
#      listener, 127.0.0.1:6667), with a random password written to
#      --env-file as TVCHAT_PASS_<ACCOUNT> for the floyd-daemon service
#      (configure/tvchat-floyd.service reads it).  Re-running keeps the password
#      already in that file.
#
# It does NOT start the daemon: see tvchat's INSTALL.md, "The central Floyd".
#
# Re-runnable: each step is skipped when already true.
#
# Usage:
#   sudo ./configure-floyd.sh [options]
#
# Options:
#   --user NAME         the Unix / mailbox user (default: floyd)
#   --nick NICK         his IRC nick and NickServ account (default: Floyd)
#   --address ADDR      the address mail for him arrives at (default:
#                       cwp+floyd@u-l.ca)
#   --mail-host HOST    Dovecot / Postfix as seen from this box (default: localhost)
#   --irc-port PORT     Ergo's loopback plaintext port (default: 6667)
#   --account NAME      the tvchat account id in floyd.conf, for the variable
#                       name (default: cpbee -> TVCHAT_PASS_CPBEE)
#   --pull-user U       whose getmail setup fetches the mail (default: chris)
#   --service-user U    who runs the floyd-daemon, and so owns --env-file
#                       (default: chris)
#   --env-file F        default /etc/tvchat/floyd.env
#   --password-file F   where the mailbox password is saved
#                       (default: /root/floyd-passwords)
#   -n | --dry-run      say what would be done, change nothing
#   -h | --help         show this header
#
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

USERNAME=floyd
NICK=Floyd
ADDRESS="cwp+floyd@u-l.ca"
MAILHOST=localhost
IRCPORT=6667
ACCOUNT=cpbee
SVCUSER=chris
PULLUSER=chris
ENVFILE=/etc/tvchat/floyd.env
PWFILE=/root/floyd-passwords
DRY=0

log()  { printf '  %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then log "would run: $*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user)          USERNAME=${2:?}; shift 2 ;;
    --nick)          NICK=${2:?}; shift 2 ;;
    --address)       ADDRESS=${2:?}; shift 2 ;;
    --mail-host)     MAILHOST=${2:?}; shift 2 ;;
    --irc-port)      IRCPORT=${2:?}; shift 2 ;;
    --account)       ACCOUNT=${2:?}; shift 2 ;;
    --pull-user)     PULLUSER=${2:?}; shift 2 ;;
    --service-user)  SVCUSER=${2:?}; shift 2 ;;
    --env-file)      ENVFILE=${2:?}; shift 2 ;;
    --password-file) PWFILE=${2:?}; shift 2 ;;
    -n|--dry-run)    DRY=1; shift ;;
    -h|--help)       sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

case "$USERNAME" in ''|[!a-z_]*|*[!a-z0-9_-]*) die "--user: '$USERNAME' is not a valid user name" ;; esac
case "$NICK" in ''|-*|*[!A-Za-z0-9_\`^{}\|\[\]\\-]*) die "--nick: '$NICK' is not a valid nickname" ;; esac
case "$ADDRESS" in *@*.*) : ;; *) die "--address: '$ADDRESS' is not an address" ;; esac
case "$ACCOUNT" in ''|*[!A-Za-z0-9_-]*) die "--account: '$ACCOUNT' may only have letters, digits, - and _" ;; esac

[ "$(uname -s)" = Linux ] || die "this sets up the Linux master; run it on cpbee"
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run it as root:  sudo $0"
id "$SVCUSER" >/dev/null 2>&1 || die "--service-user: no such user: $SVCUSER"
id "$PULLUSER" >/dev/null 2>&1 || die "--pull-user: no such user: $PULLUSER"

gen_pw() { head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 22; }
find_python() {
  for c in python3 python3.12 python3.11 python3.10 python3.9 python3.8 python3.7; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }
  done
  die "python3 not found"
}
ergo_py="$here/ergo-register.py"
[ -f "$ergo_py" ] || die "ergo-register.py not found next to this script ($here)"

# 1. the user -----------------------------------------------------------------
mailpw=""
if id "$USERNAME" >/dev/null 2>&1; then
  log "user        : $USERNAME exists - left alone"
else
  mailpw=$(gen_pw)
  nologin=$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)
  run useradd --create-home --shell "$nologin" --comment "Floyd the robot" "$USERNAME"
  if [ "$DRY" = 1 ]; then
    log "would set a random password for $USERNAME and save it in $PWFILE"
  else
    printf '%s:%s\n' "$USERNAME" "$mailpw" | chpasswd
    umask 077
    printf '%s  %s  (%s)\n' "$(date +%F)" "$USERNAME:$mailpw" "$ADDRESS" >> "$PWFILE"
    chmod 600 "$PWFILE"
    log "user        : created $USERNAME; password saved in $PWFILE"
  fi
fi
if [ "$DRY" != 1 ]; then
  uid=$(id -u "$USERNAME")
  [ "$uid" -ge 1000 ] || warn "$USERNAME has uid $uid: pop-pull's plus routing only takes uid >= 1000 (plus_min_uid)"
fi

# 2. the mail puller ----------------------------------------------------------
pull_home=$(getent passwd "$PULLUSER" | cut -d: -f6)
gm="$pull_home/.config/getmail"
wrapper="$pull_home/bin/mail-pull"
tpl=""
for d in "$gm"/plus-*/; do [ -f "${d}getmailrc" ] && { tpl=${d%/}; break; }; done
if [ -d "$gm/plus-$USERNAME" ]; then
  log "puller      : $gm/plus-$USERNAME exists - left alone"
elif [ -z "$tpl" ] || [ ! -f "$wrapper" ] || ! grep -q "plus-" "$wrapper"; then
  warn "puller      : no getmail --imap plus setup found for $PULLUSER (looked for $gm/plus-*/ and $wrapper)."
  warn "              Make cwp+$USERNAME@ mail reach $USERNAME's mailbox yourself (configure-getmail.sh --plus-users)."
else
  tag=$(basename "$tpl"); tag=${tag#plus-}
  if [ "$DRY" = 1 ]; then
    log "would clone $tpl as $gm/plus-$USERNAME (INBOX.$tag -> INBOX.$USERNAME, delivered to $USERNAME)"
    log "would add a plus-$USERNAME line to $wrapper"
  else
    install -d -m 700 -o "$PULLUSER" -g "$(id -gn "$PULLUSER")" "$gm/plus-$USERNAME"
    sed -e "s/\"INBOX\.$tag\"/\"INBOX.$USERNAME\"/" \
        -e "s/\"--\", \"$tag\"/\"--\", \"$USERNAME\"/" "$tpl/getmailrc" > "$gm/plus-$USERNAME/getmailrc"
    chown "$PULLUSER:$(id -gn "$PULLUSER")" "$gm/plus-$USERNAME/getmailrc"
    chmod 600 "$gm/plus-$USERNAME/getmailrc"
    grep -q "INBOX.$USERNAME" "$gm/plus-$USERNAME/getmailrc" && grep -q "\"$USERNAME\"" "$gm/plus-$USERNAME/getmailrc" \
      || die "could not derive $gm/plus-$USERNAME/getmailrc from $tpl/getmailrc (check it by hand)"
    # the wrapper: the template's line, for floyd, just before the final "exit"
    line=$(grep "plus-$tag\"" "$wrapper" | head -n1)
    [ -n "$line" ] || die "no plus-$tag line in $wrapper to copy"
    newline=$(printf '%s\n' "$line" | sed -e "s/plus-$tag\"/plus-$USERNAME\"/" -e "s/INBOX\.$tag/INBOX.$USERNAME/" -e "s/cwp+$tag@/cwp+$USERNAME@/")
    cp -p "$wrapper" "$wrapper.bak.$(date +%Y%m%d-%H%M%S)"
    NEWLINE="$newline" awk '/^exit / && !done { print ENVIRON["NEWLINE"]; done=1 } { print }' "$wrapper" > "$wrapper.new"
    cat "$wrapper.new" > "$wrapper" && rm -f "$wrapper.new"
    log "puller      : cwp+$USERNAME@ mail is fetched from INBOX.$USERNAME into $USERNAME's mailbox (next mail-pull;"
    log "              the folder is created by the first cwp+$USERNAME@ message)"
  fi
fi

# 3. tvmail's configuration ---------------------------------------------------
home=$(getent passwd "$USERNAME" | cut -d: -f6 || true)
[ -n "$home" ] || home=/home/$USERNAME
conf="$home/.config/tvmail/tvmail.conf"
if [ -e "$conf" ]; then
  log "tvmail.conf : $conf exists - left alone"
else
  if [ "$DRY" = 1 ]; then
    log "would write $conf and ~/.netrc for $USERNAME"
  else
    install -d -m 700 -o "$USERNAME" -g "$(id -gn "$USERNAME")" "$home/.config" "$home/.config/tvmail"
    cat > "$conf" <<EOF
# tvmail for $USERNAME: the master's own Dovecot (IMAP) and Postfix (submission).
# Mail for $ADDRESS is pulled to this mailbox by pop-pull.  The password is in
# ~/.netrc, never here.  Written by configure-floyd.sh.
[service]
mode = remote

[imap]
host   = $MAILHOST
port   = 993
ssl    = true
user   = $USERNAME
verify = false

[smtp]
host     = $MAILHOST
port     = 587
starttls = true
user     = $USERNAME
verify   = false
from     = Floyd <$ADDRESS>
auth     = true
EOF
    chown "$USERNAME:$(id -gn "$USERNAME")" "$conf"
    chmod 600 "$conf"
    log "tvmail.conf : wrote $conf"
  fi
fi
netrc="$home/.netrc"
if [ -n "$mailpw" ] && [ "$DRY" != 1 ]; then
  umask 077
  { [ ! -e "$netrc" ] || cat "$netrc"
    printf 'machine %s login %s password %s\n' "$MAILHOST" "$USERNAME" "$mailpw"; } > "$netrc.new"
  mv "$netrc.new" "$netrc"
  chown "$USERNAME:$(id -gn "$USERNAME")" "$netrc"
  chmod 600 "$netrc"
  log "login       : wrote $netrc"
elif [ -z "$mailpw" ] && [ "$DRY" != 1 ] && ! grep -qs "login $USERNAME " "$netrc" 2>/dev/null; then
  warn "no login for $USERNAME in $netrc, and the password of the existing user is not known:"
  warn "  set one (passwd $USERNAME) and add: machine $MAILHOST login $USERNAME password ..."
fi
if [ -n "$mailpw" ] && [ "$DRY" != 1 ]; then       # prove the login
  if MAILHOST="$MAILHOST" U="$USERNAME" P="$mailpw" "$(find_python)" - <<'PYEOF'
import imaplib, os, ssl
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
m = imaplib.IMAP4_SSL(os.environ["MAILHOST"], 993, ssl_context=ctx, timeout=15)
m.login(os.environ["U"], os.environ["P"]); m.logout()
PYEOF
  then log "imap        : logged in to $MAILHOST:993 as $USERNAME"
  else warn "could not log in to IMAP on $MAILHOST:993 as $USERNAME (is Dovecot up? configure-dovecot.sh)"
  fi
fi

# 4. the IRC nick -------------------------------------------------------------
var="TVCHAT_PASS_$(printf '%s' "$ACCOUNT" | tr 'a-z-' 'A-Z_')"
ircpw=""
[ ! -r "$ENVFILE" ] || ircpw=$(sed -n "s/^$var=//p" "$ENVFILE" | head -n1)
fresh=0
if [ -z "$ircpw" ]; then ircpw=$(gen_pw); fresh=1; fi
if [ "$DRY" = 1 ]; then
  log "would register $NICK with NickServ on 127.0.0.1:$IRCPORT and write $var to $ENVFILE"
else
  CHAT_SETUP_PASS="$ircpw" "$(find_python)" "$ergo_py" 127.0.0.1 "$IRCPORT" "$NICK" \
    || die "could not register $NICK with NickServ (is Ergo up on 127.0.0.1:$IRCPORT? configure-ergo.sh)"
  if [ "$fresh" = 1 ]; then
    install -d -m 755 "$(dirname "$ENVFILE")"
    umask 077
    { [ ! -e "$ENVFILE" ] || grep -v "^$var=" "$ENVFILE" || true
      printf '%s=%s\n' "$var" "$ircpw"; } > "$ENVFILE.new"
    mv "$ENVFILE.new" "$ENVFILE"
    chown "$SVCUSER" "$ENVFILE"
    chmod 600 "$ENVFILE"
    log "nickserv    : $NICK's password is in $ENVFILE (owner $SVCUSER)"
  else
    log "nickserv    : $NICK registered; the password in $ENVFILE is unchanged"
  fi
fi

# 5. what is next -------------------------------------------------------------
cat <<EOF

Done.  Next:
  * read his mail:   sudo -u $USERNAME -H tvmail      (it is cwp+floyd@... mail, once pop-pull has fetched it)
  * start the bot:   see tvchat's INSTALL.md, "The central Floyd"
                     (/etc/tvchat/floyd.conf: sasl = $NICK; admins = chris)
EOF
