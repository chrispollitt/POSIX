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
#   5. brings up the daemon (tvchat-backend floyd-daemon), all of it:
#        - builds and installs tvchat from its checkout when it is missing or out of
#          date (built as the checkout's owner, installed into /usr/local);
#        - installs the Claude CLI for the service user (Anthropic's installer, into
#          ~/.local/bin) and clones the repositories he may read into --claude-dir;
#        - writes --conf-file (/etc/tvchat/floyd.conf, from tvchat's floyd.conf.example,
#          with his nick, the Ergo address, the account name, the admins and the path of
#          his claude filled in; an existing file is kept, but its claude_cmd is fixed),
#          the systemd unit tvchat-floyd.service (User = the service user), and starts
#          or restarts it;
#        - at a terminal, offers to log him in to Claude (once), then asks the CLI a
#          question the way the daemon does, to prove it works.
#      tvchat's checkout: --tvchat-dir, or ../../../TUIs/tvchat, or the installed
#      /usr/local/share/doc/tvchat (then nothing is built).
#
# The daemon runs as the floyd user by default, so the Claude CLI that admins can
# ask through him (!claude ...) is only as powerful as that account: it cannot read
# your files.  His Claude login is his own (the account has no login shell, so su
# cannot be used; the script runs the CLI for him).  --service-user chris runs the
# daemon as you instead.
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
#                       (default: the --user, floyd)
#   --irc-host HOST     where he connects to Ergo's TLS port (default: the address
#                       Ergo listens on, from ss; on the master the name "cpbee" is
#                       127.0.1.1 or ::1, which Ergo's LAN-only listener refuses)
#   --admins LIST       NickServ accounts that may give him orders (default: chris)
#   --claude-dir DIR    the directory the Claude CLI works in (default: ~floyd/src)
#   --clone URL         a repository to clone (or update) into --claude-dir, so Claude
#                       can read it; repeatable (default: github.com/chrispollitt's
#                       TUIs and POSIX).  --no-clone: none
#   --claude-cmd PATH   his claude (default: ~floyd/.local/bin/claude, installed if absent)
#   --no-claude-install don't install the Claude CLI for him
#   --no-login          don't offer the Claude login
#   --no-install-tvchat don't build and install tvchat from the checkout
#   --conf-file F       default /etc/tvchat/floyd.conf
#   --tvchat-dir DIR    where floyd.conf.example and tvchat-floyd.service are
#   --no-start          write the files, do not start the service
#   --print-config      print the floyd.conf this would write, and stop (no root)
#   --print-unit        print the systemd unit this would write, and stop
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
SVCUSER=""
ADMINS=chris
IRCHOST=""
CLAUDEDIR=""
CONFFILE=/etc/tvchat/floyd.conf
TVCHATDIR=""
NOSTART=0
NOCLONE=0; NOCLAUDE=0; NOLOGIN=0; NOTV=0
CLAUDECMD=""
CLONES=()
PRINT=""
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
    --irc-host)      IRCHOST=${2:?}; shift 2 ;;
    --admins)        ADMINS=${2:?}; shift 2 ;;
    --claude-dir)    CLAUDEDIR=${2:?}; shift 2 ;;
    --conf-file)     CONFFILE=${2:?}; shift 2 ;;
    --tvchat-dir)    TVCHATDIR=${2:?}; shift 2 ;;
    --no-start)      NOSTART=1; shift ;;
    --clone)         CLONES+=("${2:?}"); shift 2 ;;
    --no-clone)      NOCLONE=1; shift ;;
    --claude-cmd)    CLAUDECMD=${2:?}; shift 2 ;;
    --no-claude-install) NOCLAUDE=1; shift ;;
    --no-login)      NOLOGIN=1; shift ;;
    --no-install-tvchat) NOTV=1; shift ;;
    --print-config)  PRINT=config; shift ;;
    --print-unit)    PRINT=unit; shift ;;
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

[ -n "$SVCUSER" ] || SVCUSER=$USERNAME
[ ${#CLONES[@]} -gt 0 ] || CLONES=(https://github.com/chrispollitt/TUIs https://github.com/chrispollitt/POSIX)
case "$CLAUDECMD" in ''|/*) : ;; *) die "--claude-cmd: '$CLAUDECMD' is not a full path" ;; esac
case "$ADMINS" in ''|*[!A-Za-z0-9_,\ \`^{}\|\[\]\\-]*) die "--admins: '$ADMINS' is not a list of account names" ;; esac

# tvchat's files: a source checkout has them in configure/, an install in the doc dir
tv_file() {
  local dirs=("$here/../../../TUIs/tvchat" /usr/local/share/doc/tvchat /usr/share/doc/tvchat)
  [ -z "$TVCHATDIR" ] || dirs=("$TVCHATDIR")        # asked for one: look nowhere else
  for d in "${dirs[@]}"; do
    for f in "$d/configure/$1" "$d/$1"; do [ -f "$f" ] && { echo "$f"; return 0; }; done
  done
  return 1
}
# the directory those files are in: a tvchat checkout (has build.sh) or its installed doc dir
tv_dir() {
  local f
  f=$(tv_file floyd.conf.example) || return 1
  f=$(dirname "$f"); [ "$(basename "$f")" = configure ] && f=$(dirname "$f")
  echo "$f"
}
# the address Ergo's TLS listener is bound to (not loopback), if this box shows one
detect_irc_host() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnH 'sport = :6697' 2>/dev/null | awk '{print $4}' | sed 's/:6697$//' \
    | grep -vE '^(127\.|\[?::1?\]?$|0\.0\.0\.0$|\*$)' | head -n1 || true
}
[ -n "$IRCHOST" ] || IRCHOST=$(detect_irc_host)
case "$IRCHOST" in *[!A-Za-z0-9.:-]*) die "--irc-host: '$IRCHOST' is not a host name or address" ;; esac
# floyd.conf: the example with his nick, the account name and the admins filled in
make_conf() {
  local src
  src=$(tv_file floyd.conf.example) || die "floyd.conf.example not found (use --tvchat-dir DIR: a tvchat checkout or its installed doc directory)"
  sed -e "s/^\[account:cpbee\]/[account:$ACCOUNT]/" \
      -e "s#^attach   = cpbee/\*#attach   = $ACCOUNT/*#" \
      -e "s/^nick     = .*/nick     = $NICK/" \
      -e "s/^sasl     = .*/sasl     = $NICK/" \
      ${IRCHOST:+-e "s/^host     = .*/host     = $IRCHOST/"} \
      -e "s/^admins   = .*/admins   = $ADMINS/" \
      ${CLAUDEDIR:+-e "s#^claude_dir *= .*#claude_dir      = $CLAUDEDIR#"} \
      ${CLAUDECMD:+-e "s|^#\{0,1\}claude_cmd .*|claude_cmd = $CLAUDECMD|"} "$src"
}
backend_path() { command -v tvchat-backend 2>/dev/null || echo /usr/local/bin/tvchat-backend; }
# the systemd unit: who runs it, where the backend, the config and the passwords are
make_unit() {
  local src
  src=$(tv_file tvchat-floyd.service) || die "tvchat-floyd.service not found (use --tvchat-dir DIR)"
  sed -e "s#^User=.*#User=$SVCUSER#" \
      -e "s#^ExecStart=.*#ExecStart=$(backend_path) floyd-daemon --conf $CONFFILE#" \
      -e "s#^EnvironmentFile=.*#EnvironmentFile=-$ENVFILE#" "$src"
}
case "$PRINT" in config) make_conf; exit 0 ;; unit) make_unit; exit 0 ;; esac

[ "$(uname -s)" = Linux ] || die "this sets up the Linux master; run it on cpbee"
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run it as root:  sudo $0"
[ "$SVCUSER" = "$USERNAME" ] || id "$SVCUSER" >/dev/null 2>&1 || die "--service-user: no such user: $SVCUSER"   # (floyd is made below)
id "$PULLUSER" >/dev/null 2>&1 || die "--pull-user: no such user: $PULLUSER"

[ "$DRY" != 1 ] || [ "$(id -u)" = 0 ] || \
  log "(a dry run as $(id -un): other users' home directories cannot be examined, so steps that are done may show as 'would'; use sudo for an exact one)"
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
  rc=0
  CHAT_SETUP_PASS="$ircpw" "$(find_python)" "$ergo_py" 127.0.0.1 "$IRCPORT" "$NICK" || rc=$?
  if [ "$rc" = 3 ] && [ "$fresh" = 0 ]; then
    # Ergo does not let an unauthenticated connection take a registered nick: so on a
    # re-run, once his secret is saved, "taken" means "registered earlier"
    log "nickserv    : $NICK is taken - registered earlier (his password is in $ENVFILE).  If he is not,"
    log "              something else is using the nick: /whois $NICK from an IRC client."
    rc=0
  fi
  [ "$rc" = 0 ] || die "could not register $NICK with NickServ (is Ergo up on 127.0.0.1:$IRCPORT? configure-ergo.sh; is another connection using the nick $NICK?)"
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
    if [ -e "$ENVFILE" ]; then chown "$SVCUSER" "$ENVFILE"; chmod 600 "$ENVFILE"; fi
  fi
fi

# 5. tvchat, Claude for him, the daemon ----------------------------------------
changed=0
svc_home=$(getent passwd "$SVCUSER" | cut -d: -f6 || true); [ -n "$svc_home" ] || svc_home=/home/$SVCUSER
as_svc() { runuser -u "$SVCUSER" -- env HOME="$svc_home" "$@"; }
tvdir=$(tv_dir || true)
if [ -z "$tvdir" ]; then
  warn "daemon      : tvchat's floyd.conf.example / tvchat-floyd.service not found - give --tvchat-dir DIR"
  warn "              (a tvchat checkout, or /usr/local/share/doc/tvchat once installed)"
  exit 0
fi
backend=$(backend_path)

# 5a. tvchat itself: built and installed when missing or different from the checkout
if [ "$NOTV" = 0 ] && [ -f "$tvdir/build.sh" ]; then
  if [ ! -x "$backend" ] || ! cmp -s "$tvdir/backend/tvchat-backend" "$backend"; then
    owner=$(stat -c %U "$tvdir")
    if [ "$DRY" = 1 ]; then
      log "would build tvchat in $tvdir (as $owner) and install it into /usr/local"
    else
      log "tvchat      : building $tvdir as $owner (a few minutes the first time) ..."
      blog=$(mktemp)
      if runuser -u "$owner" -- sh -c 'cd "$1" && ./build.sh' sh "$tvdir" > "$blog" 2>&1; then
        cmake --install "$tvdir/build" --prefix /usr/local > "$blog" 2>&1 \
          || { tail -n 15 "$blog" >&2; die "installing tvchat failed"; }
        chown "$owner" "$tvdir/build/install_manifest.txt" 2>/dev/null || true
        rm -f "$blog"; changed=1
        log "tvchat      : installed into /usr/local ($(tvchat-backend --version))"
      else
        tail -n 20 "$blog" >&2; die "building tvchat failed (above; full log: $blog)"
      fi
    fi
  fi
elif [ ! -x "$backend" ]; then
  warn "daemon      : tvchat-backend is not installed on this box and there is no checkout to build it from"
  warn "              (./build.sh && ./install.sh in tvchat, or give --tvchat-dir DIR); then run this again"
  exit 0
fi

# 5b. the Claude CLI, for the service user
[ -n "$CLAUDECMD" ] || { [ -x "$svc_home/.local/bin/claude" ] && CLAUDECMD="$svc_home/.local/bin/claude"; } || true
if [ -z "$CLAUDECMD" ] && [ "$NOCLAUDE" = 0 ]; then
  if [ "$DRY" = 1 ]; then
    log "would install the Claude CLI for $SVCUSER (https://claude.ai/install.sh, into $svc_home/.local/bin)"
  else
    log "claude      : installing the Claude CLI for $SVCUSER (Anthropic's installer, into $svc_home/.local/bin) ..."
    clog=$(mktemp)
    if as_svc sh -c 'cd "$HOME" && curl -fsSL https://claude.ai/install.sh | bash' > "$clog" 2>&1 \
       && [ -x "$svc_home/.local/bin/claude" ]; then
      CLAUDECMD="$svc_home/.local/bin/claude"; rm -f "$clog"; changed=1
      log "claude      : installed $CLAUDECMD"
    else
      tail -n 10 "$clog" >&2
      warn "claude      : could not install it for $SVCUSER (above); !claude will not work until you do"
    fi
  fi
fi

# 5c. what he may read: --claude-dir, with the repositories cloned (or updated) into it
if [ -z "$CLAUDEDIR" ] && [ "$NOCLONE" = 0 ]; then CLAUDEDIR="$svc_home/src"; fi
if [ -n "$CLAUDEDIR" ] && [ "$DRY" != 1 ]; then
  as_svc mkdir -p "$CLAUDEDIR" || warn "claude dir  : cannot create $CLAUDEDIR as $SVCUSER"
  if [ "$NOCLONE" = 0 ]; then
    for url in "${CLONES[@]}"; do
      name=$(basename "$url" .git)
      if [ -d "$CLAUDEDIR/$name/.git" ]; then
        as_svc git -C "$CLAUDEDIR/$name" pull -q --ff-only >/dev/null 2>&1 \
          && log "clone       : $name updated" || warn "clone       : could not update $CLAUDEDIR/$name"
      else
        as_svc git -C "$CLAUDEDIR" clone -q "$url" >/dev/null 2>&1 \
          && log "clone       : $name -> $CLAUDEDIR/$name" || warn "clone       : could not clone $url into $CLAUDEDIR"
      fi
    done
  fi
elif [ -n "$CLAUDEDIR" ]; then
  log "would create $CLAUDEDIR as $SVCUSER"
  [ "$NOCLONE" = 1 ] || log "would clone (or update) into it: ${CLONES[*]}"
fi

# 5d. the config, the unit, the service
if [ "$DRY" = 1 ]; then
  log "would write $CONFFILE (claude_cmd = ${CLAUDECMD:-claude}) and /etc/systemd/system/tvchat-floyd.service (User=$SVCUSER), then start it"
else
  if [ -e "$CONFFILE" ]; then
    log "floyd.conf  : $CONFFILE exists - kept"
    if [ -n "$CLAUDECMD" ] && ! grep -qxE "claude_cmd *= *$CLAUDECMD" "$CONFFILE"; then
      if grep -qE '^#?claude_cmd *=( *claude)? *$' "$CONFFILE"; then
        sed -i "s|^#\{0,1\}claude_cmd .*|claude_cmd = $CLAUDECMD|" "$CONFFILE"
        changed=1; log "floyd.conf  : claude_cmd = $CLAUDECMD"
      else
        warn "floyd.conf  : its claude_cmd is not $CLAUDECMD; left as you set it"
      fi
    fi
  else
    install -d -m 755 "$(dirname "$CONFFILE")"
    make_conf > "$CONFFILE.new" && mv "$CONFFILE.new" "$CONFFILE"
    chmod 644 "$CONFFILE"; changed=1
    log "floyd.conf  : wrote $CONFFILE (nick $NICK, account $ACCOUNT, host ${IRCHOST:-as in the example}, admins $ADMINS)"
  fi
  if ! out=$("$(backend_path)" check-config "$CONFFILE" 2>&1); then
    printf '%s\n' "$out" >&2
    die "$CONFFILE has errors (above); fix it and run this again"
  fi
  unit=/etc/systemd/system/tvchat-floyd.service
  make_unit > "$unit.new"
  if [ -f "$unit" ] && cmp -s "$unit.new" "$unit"; then
    rm -f "$unit.new"; log "unit        : $unit is up to date"
  else
    mv "$unit.new" "$unit"; chmod 644 "$unit"; changed=1; log "unit        : wrote $unit (runs as $SVCUSER)"
  fi
  if [ "$NOSTART" = 1 ]; then
    log "service     : not started (--no-start):  systemctl enable --now tvchat-floyd"
  elif ! command -v systemctl >/dev/null 2>&1; then
    warn "service     : no systemctl here; run it by hand:  $(backend_path) floyd-daemon --conf $CONFFILE"
  else
    systemctl daemon-reload
    systemctl enable tvchat-floyd >/dev/null 2>&1 || true
    if systemctl is-active --quiet tvchat-floyd && [ "$changed" = 1 ]; then systemctl restart tvchat-floyd
    else systemctl start tvchat-floyd; fi
    sleep 3
    if systemctl is-active --quiet tvchat-floyd; then
      log "service     : tvchat-floyd is running (journalctl -u tvchat-floyd -f); what it says about IRC:"
      sleep 2; journalctl -u tvchat-floyd -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/                /' || true
    else
      warn "service     : tvchat-floyd did not stay up:"
      journalctl -u tvchat-floyd -n 15 --no-pager 2>/dev/null >&2 || true
    fi
  fi

  # 5e. his Claude login (his own, once), proved the way the daemon uses the CLI
  if [ -n "$CLAUDECMD" ] && grep -qs "^claude *= *yes" "$CONFFILE"; then
    claude_ok() {
      echo "Reply with exactly: pong" | as_svc sh -c 'cd "$1" && timeout 90 "$2" -p --output-format text --tools Read --allowedTools Read --permission-mode dontAsk' \
        sh "${CLAUDEDIR:-$svc_home}" "$CLAUDECMD" 2>/dev/null | grep -qi pong
    }
    if claude_ok; then
      log "claude      : $SVCUSER is logged in to Claude and the CLI answers"
    elif [ "$NOLOGIN" = 0 ] && [ -t 0 ] && [ -t 1 ]; then
      printf '  claude      : %s is not logged in to Claude yet.  Log in now (then /exit)? [Y/n] ' "$SVCUSER"
      read -r ans || ans=n
      case "$ans" in [Nn]*) : ;; *) as_svc sh -c 'cd "$HOME" && exec "$1"' sh "$CLAUDECMD" || true ;; esac
      if claude_ok; then log "claude      : logged in, and the CLI answers"
      else warn "claude      : still no answer from the CLI; log in with:  sudo -u $SVCUSER -H sh -c 'cd ~ && $CLAUDECMD'"; fi
    else
      warn "claude      : $SVCUSER is not logged in to Claude (or the CLI does not answer).  Log in once:"
      warn "              sudo -u $SVCUSER -H sh -c 'cd ~ && $CLAUDECMD'      (then /exit)"
    fi
  elif grep -qs "^claude *= *yes" "$CONFFILE"; then
    warn "claude      : no Claude CLI for $SVCUSER, so !claude will say it cannot be reached"
  fi
fi

# 6. what is next -------------------------------------------------------------
cat <<EOF

Done.  Next:
  * try the bot:       /msg $NICK hello      (as $ADMINS: !whoami, then !claude QUESTION)
  * read his mail:     sudo -u $USERNAME -H tvmail      (it is $ADDRESS mail, once pop-pull has fetched it)
  * logs:              journalctl -u tvchat-floyd -f
EOF
