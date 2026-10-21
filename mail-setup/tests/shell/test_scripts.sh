#!/usr/bin/env bash
#
# test_scripts.sh - tests for mail-setup.sh and scripts/*.sh.
#
# Every script runs for real, but inside a throwaway $HOME, with fake getmail /
# mail(1) / MDA programs first on $PATH, MAIL_SETUP_SUDO= (never escalates)
# and SENDMAIL_DEST pointing into the sandbox - so nothing outside it changes.
# Runs anywhere bash + python3 do (Linux, macOS, Cygwin).
#
# Exit 0 = all passed, 1 = something failed.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
M=$(CDPATH= cd -- "$here/../.." && pwd)
S="$M/scripts"

PASS=0; FAIL=0; CUR=""
t()    { CUR="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  ok    %s: %s\n' "$CUR" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s: %s\n' "$CUR" "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }        # check "what" 'test-expr'
has()  { grep -qF -- "$2" "$1"; }                                   # has FILE TEXT
pycheck() { "$PY" -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], \"exec\")" "$1"; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME/bin"
export MAIL_SETUP_SUDO=""
FAKE="$SANDBOX/fake"; mkdir -p "$FAKE"
export PATH="$HOME/bin:$FAKE:$PATH"
PY=$(command -v python3)

# mode checks only mean something where chmod sticks (not Cygwin's noacl /tmp)
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
touch "$SANDBOX/probe"; chmod 600 "$SANDBOX/probe"
MODES=0; [ "$(mode "$SANDBOX/probe")" = 600 ] && MODES=1
check_mode() {   # check_mode "what" FILE [MODE]   (MODE defaults to 600)
  _f=$2 _m=${3:-600}   # check() evals in its own scope, where $2 is the expression
  if [ "$MODES" = 1 ]; then check "$1" '[ "$(mode "$_f")" = "$_m" ]'
  else ok "$1 (skipped: this filesystem ignores chmod)"; fi
}

cat > "$FAKE/mda" <<'EOF'
#!/bin/sh
cat >> "$HOME/delivered"
EOF
cat > "$FAKE/getmail" <<'EOF'
#!/bin/sh
echo "fake-getmail $*"
# FAKE_GETMAIL_FAIL=<text>: fail the runs whose arguments contain it
[ -n "${FAKE_GETMAIL_FAIL:-}" ] && case "$*" in *"$FAKE_GETMAIL_FAIL"*) exit 1 ;; esac
exit 0
EOF
cat > "$FAKE/mail" <<'EOF'
#!/bin/sh
[ "$1" = --version ] && { echo "mail (GNU Mailutils) 0.0-fake"; exit 0; }
cat > /dev/null
EOF
chmod 755 "$FAKE"/*
export MAIL_SETUP_MDA="$FAKE/mda"

PW="$SANDBOX/sasl_passwd"
printf '[smtp.example.org]:587 me@example.org:p4ss\n' > "$PW"; chmod 600 "$PW"
RELAY="$SANDBOX/relay.txt"
printf 'Username: me@example.org\r\nIncoming Server: in.example.org\r\nOutgoing Server: out.example.org\r\nSMTP Port: 465\r\n' > "$RELAY"
OUT="$SANDBOX/out"

# --------------------------------------------------------------------------
t "configure-mail-pull"
"$S/configure-mail-pull.sh" --pwfile "$PW" --relay-file "$RELAY" > "$OUT" 2>&1
check "exits 0" '[ $? = 0 ]'
C="$HOME/.config/mailpull.conf"
check "server/user from relay file" 'has "$C" "server     = in.example.org" && has "$C" "user       = me@example.org"'
check "keep by default" 'has "$C" "keep       = true"'
check "mda + pwfile recorded" 'has "$C" "mda        = $FAKE/mda" && has "$C" "pwfile     = $PW"'
check "pop-pull installed, shebang = python found" '[ -x "$HOME/bin/pop-pull" ] && head -1 "$HOME/bin/pop-pull" | grep -q "^#!/.*python3"'
check "pull-mail alias" '[ -L "$HOME/bin/pull-mail" ]'
check "mail-pull runs pop-pull" 'has "$HOME/bin/mail-pull" "exec \"$HOME/bin/pop-pull\""'
check "mail-pull -h reaches pop-pull" '"$HOME/bin/mail-pull" -h 2>&1 | grep -q "usage: pop-pull"'
"$S/configure-mail-pull.sh" --pwfile "$PW" --relay-file "$RELAY" --delete --no-verify > "$OUT" 2>&1
check "re-run backs up the old config" 'ls "$C".bak.* >/dev/null 2>&1'
check "--delete / --no-verify" 'has "$C" "keep       = false" && has "$C" "verify     = false"'
"$S/configure-mail-pull.sh" --pwfile "$PW" --pop-user x@y > "$OUT" 2>&1
check "warns when pwfile has no line for the user" 'has "$OUT" "no line for '\''x@y'\'' in"'

# --------------------------------------------------------------------------
t "configure-getmail"
"$S/configure-getmail.sh" --pwfile "$PW" --relay-file "$RELAY" > "$OUT" 2>&1
check "exits 0" '[ $? = 0 ]'
RC="$HOME/.config/getmail/getmailrc"
check "POP3S retriever by default" 'has "$RC" "type = SimplePOP3SSLRetriever" && has "$RC" "port = 995"'
check "server/user from relay file" 'has "$RC" "server = in.example.org" && has "$RC" "username = me@example.org"'
check "delivers through the MDA to you" 'has "$RC" "path = $FAKE/mda" && has "$RC" "arguments = (\"-oi\", \"--\", \"$(id -un)\")"'
check "keeps mail on the server" 'has "$RC" "delete = false"'
check "no password in getmailrc" '! has "$RC" "p4ss"'
check "no getmail 'Delivered-To: unknown' header" 'has "$RC" "delivered_to = false"'
check_mode "getmailrc is mode 600" "$RC"
check "password_command works" '[ "$("$HOME/bin/sasl-pass" --file "$PW" me@example.org)" = p4ss ]'
check "mail-pull runs getmail with its dir" '"$HOME/bin/mail-pull" -v | grep -q "fake-getmail --getmaildir $HOME/.config/getmail --rcfile getmailrc -v"'
"$HOME/bin/mail-pull" -n > /dev/null 2>&1
check "mail-pull -n refuses (getmail has no dry run)" '[ $? = 2 ]'
"$S/configure-getmail.sh" --pwfile "$PW" --imap --delete --user me@example.org > "$OUT" 2>&1
check "--imap" 'has "$RC" "type = SimpleIMAPSSLRetriever" && has "$RC" "port = 993" && has "$RC" "mailboxes = (\"INBOX\",)"'
check "--delete" 'has "$RC" "delete = true"'
"$S/configure-mail-pull.sh" --pwfile "$PW" > /dev/null 2>&1
check "configuring pop-pull again switches mail-pull back" 'has "$HOME/bin/mail-pull" "pop-pull"'
MAIL_SETUP_GETMAIL="" ASSUME=no "$S/configure-getmail.sh" --pwfile "$PW" > "$OUT" 2>&1
check "no getmail + declined -> fails cleanly" '[ $? != 0 ] && has "$OUT" "getmail is required"'

# --------------------------------------------------------------------------
t "plus routing: configure-mail-pull"
"$S/configure-mail-pull.sh" --pwfile "$PW" --relay-file "$RELAY" --plus-base me@example.org > "$OUT" 2>&1
check "exits 0" '[ $? = 0 ]'
check "plus_base recorded" 'has "$C" "plus_base  = me@example.org"'
check "announces the routing" 'has "$OUT" "plus routing : me+TAG@example.org"'
"$S/configure-mail-pull.sh" --pwfile "$PW" --relay-file "$RELAY" > "$OUT" 2>&1
check "off by default (empty plus_base)" 'grep -qx "plus_base  = " "$C"'
for bad in 'a+b@c.org' nodomain '@x.org' 'x@' 'a@b@c'; do
  "$S/configure-mail-pull.sh" --pwfile "$PW" --plus-base "$bad" > "$OUT" 2>&1
  check "rejects --plus-base '$bad'" '[ $? != 0 ] && has "$OUT" "must be a plain address"'
done
CF2="$SANDBOX/etc-mailpull.conf"
"$S/configure-mail-pull.sh" --pwfile "$PW" --config "$CF2" --plus-base me@example.org --local-user zed > "$OUT" 2>&1
check "--config writes the config there" 'has "$CF2" "plus_base  = me@example.org" && has "$CF2" "local_user = zed"'
check "mail-pull passes --config to pop-pull" 'has "$HOME/bin/mail-pull" "--config \"$CF2\""'
"$S/configure-mail-pull.sh" --pwfile "$PW" > /dev/null 2>&1
check "without --config the wrapper is plain again" '! has "$HOME/bin/mail-pull" "--config"'

# --------------------------------------------------------------------------
t "plus routing: configure-getmail"
# prints the local users getmail would deliver ADDR to, per the written getmailrc
RCR="$SANDBOX/rc_route.py"
cat > "$RCR" <<'EOF'
import ast, configparser, re, sys
c = configparser.RawConfigParser()
c.read(sys.argv[1])
d = c["destination"]
hits = [dest for pat, dest in ast.literal_eval(d["locals"]) if re.search(pat, sys.argv[2])] or [d["default"]]
print(",".join(ast.literal_eval(c[h.strip("[]")]["arguments"])[-1] for h in hits))
EOF
route() { "$PY" "$RCR" "$RC" "$1"; }
"$S/configure-getmail.sh" --pwfile "$PW" --relay-file "$RELAY" --plus-base cwp@u-l.ca --plus-users chris,miche --local-user zed > "$OUT" 2>&1
check "exits 0" '[ $? = 0 ]'
check "MultiGuesser with a default" 'has "$RC" "type = MultiGuesser" && has "$RC" "default = [dest-default]"'
check "a destination section per user + default" 'has "$RC" "[dest-chris]" && has "$RC" "[dest-miche]" && has "$RC" "[dest-default]"'
check "cwp+chris@ -> chris" '[ "$(route cwp+chris@u-l.ca)" = chris ]'
check "cwp+miche@ -> miche, any case" '[ "$(route CWP+Miche@U-L.CA)" = miche ]'
check "untagged -> --local-user" '[ "$(route cwp@u-l.ca)" = zed ]'
check "unlisted tag -> --local-user" '[ "$(route cwp+bob@u-l.ca)" = zed ]'
check "patterns are anchored and dots escaped" '[ "$(route cwp+chrisx@u-l.ca)$(route xcwp+chris@u-l.ca)$(route cwp+chris@u-lxca)$(route cwp+chris@u-l.ca.evil.org)" = zedzedzedzed ]'
check "still no password in getmailrc" '! has "$RC" "p4ss"'
check_mode "getmailrc is mode 600" "$RC"
"$S/configure-getmail.sh" --pwfile "$PW" --relay-file "$RELAY" > "$OUT" 2>&1
check "re-run without --plus-* is a single MDA again" 'has "$RC" "type = MDA_external" && ! has "$RC" "MultiGuesser"'
"$S/configure-getmail.sh" --pwfile "$PW" --plus-base cwp@u-l.ca > "$OUT" 2>&1
check "--plus-base alone rejected" '[ $? != 0 ] && has "$OUT" "go together"'
"$S/configure-getmail.sh" --pwfile "$PW" --plus-users chris > "$OUT" 2>&1
check "--plus-users alone rejected" '[ $? != 0 ] && has "$OUT" "go together"'
"$S/configure-getmail.sh" --pwfile "$PW" --plus-base cwp@u-l.ca --plus-users 'chris,Bob' > "$OUT" 2>&1
check "bad user name rejected" '[ $? != 0 ] && has "$OUT" "plain lower-case login name"'
"$S/configure-getmail.sh" --pwfile "$PW" --plus-base 'cwp+x@u-l.ca' --plus-users chris > "$OUT" 2>&1
check "tagged base rejected" '[ $? != 0 ] && has "$OUT" "must be a plain address"'
"$S/configure-getmail.sh" --pwfile "$PW" --plus-base cwp@u-l.ca --plus-users chris > "$OUT" 2>&1
check "POP3 + plus warns that a TAG folder host needs --imap" 'has "$OUT" "needs --imap"'
check "POP3 + plus: one rc, no folder rcs" '! [ -e "$HOME/.config/getmail/plus-chris" ]'

# --------------------------------------------------------------------------
t "plus routing: configure-getmail --imap (cPanel-style tag folders)"
GM="$HOME/.config/getmail"
"$S/configure-getmail.sh" --imap --pwfile "$PW" --relay-file "$RELAY" --plus-base cwp@u-l.ca --plus-users chris,miche --local-user zed > "$OUT" 2>&1
check "exits 0" '[ $? = 0 ]'
check "announces the folder -> user map" 'has "$OUT" "INBOX.chris -> chris;  INBOX.miche -> miche;  INBOX -> zed"'
check "INBOX rc: plain MDA to --local-user, no header guessing" 'has "$RC" "mailboxes = (\"INBOX\",)" && has "$RC" "arguments = (\"-oi\", \"--\", \"zed\")" && ! has "$RC" "MultiGuesser"'
for u in chris miche; do
  check "folder rc for $u: IMAP, INBOX.$u, delivers to $u" \
    'has "$GM/plus-$u/getmailrc" "type = SimpleIMAPSSLRetriever" && has "$GM/plus-$u/getmailrc" "mailboxes = (\"INBOX.$u\",)" && has "$GM/plus-$u/getmailrc" "arguments = (\"-oi\", \"--\", \"$u\")"'
  check "folder rc for $u: same server/login, password via sasl-pass, KEEP" \
    'has "$GM/plus-$u/getmailrc" "server = in.example.org" && has "$GM/plus-$u/getmailrc" "username = me@example.org" && has "$GM/plus-$u/getmailrc" "password_command = (\"$HOME/bin/sasl-pass\"" && has "$GM/plus-$u/getmailrc" "delete = false" && ! has "$GM/plus-$u/getmailrc" "p4ss"'
  check_mode "plus-$u/getmailrc is mode 600" "$GM/plus-$u/getmailrc"
done
check "each folder has its own getmaildir (separate oldmail state)" '[ -d "$GM/plus-chris" ] && [ -d "$GM/plus-miche" ]'
out=$("$HOME/bin/mail-pull" -v 2>&1)
check "mail-pull runs getmail for INBOX and each folder" \
  'grep -q "fake-getmail --getmaildir $GM --rcfile getmailrc -v" <<<"$out" && grep -q "fake-getmail --getmaildir $GM/plus-chris --rcfile getmailrc -v" <<<"$out" && grep -q "fake-getmail --getmaildir $GM/plus-miche --rcfile getmailrc -v" <<<"$out"'
"$HOME/bin/mail-pull" > /dev/null 2>&1
check "all runs fine -> exit 0" '[ $? = 0 ]'
out=$(FAKE_GETMAIL_FAIL=plus-miche "$HOME/bin/mail-pull" 2>&1); rc=$?
check "a missing tag folder is reported but not fatal" '[ $rc = 0 ] && grep -q "folder INBOX.miche: getmail failed" <<<"$out"'
out=$(FAKE_GETMAIL_FAIL="getmail --rcfile" "$HOME/bin/mail-pull" 2>&1); rc=$?
check "an INBOX failure still fails the run (and the folders still run)" '[ $rc = 1 ] && grep -q "plus-chris" <<<"$out"'
"$HOME/bin/mail-pull" -n > /dev/null 2>&1
check "-n still refused" '[ $? = 2 ]'
"$S/configure-getmail.sh" --imap --pwfile "$PW" --relay-file "$RELAY" --plus-base cwp@u-l.ca --plus-users chris --plus-prefix 'INBOX/' > "$OUT" 2>&1
check "--plus-prefix: INBOX/chris" 'has "$GM/plus-chris/getmailrc" "mailboxes = (\"INBOX/chris\",)"'
"$S/configure-getmail.sh" --imap --pwfile "$PW" --relay-file "$RELAY" --plus-base cwp@u-l.ca --plus-users chris --plus-prefix '' > "$OUT" 2>&1
check "--plus-prefix '' : folder chris" 'has "$GM/plus-chris/getmailrc" "mailboxes = (\"chris\",)"'
"$S/configure-getmail.sh" --imap --pwfile "$PW" --relay-file "$RELAY" --plus-base cwp@u-l.ca --plus-users chris --plus-headers --local-user zed > "$OUT" 2>&1
check "--plus-headers: INBOX rc becomes a MultiGuesser, folder rc stays plain" \
  'has "$RC" "type = MultiGuesser" && has "$RC" "mailboxes = (\"INBOX\",)" && ! has "$GM/plus-chris/getmailrc" "MultiGuesser"'
check "... and routes by header like the POP3 mode" '[ "$(route cwp+chris@u-l.ca)" = chris ] && [ "$(route cwp@u-l.ca)" = zed ]'
"$S/configure-getmail.sh" --imap --pwfile "$PW" --relay-file "$RELAY" > "$OUT" 2>&1
check "re-run without --plus-*: single rc, wrapper execs getmail once" \
  '! has "$HOME/bin/mail-pull" "plus-chris" && has "$HOME/bin/mail-pull" "exec " && ! has "$RC" "MultiGuesser"'
"$S/configure-getmail.sh" --imap --pwfile "$PW" --plus-base cwp@u-l.ca --plus-users chris --plus-prefix "IN'BOX." > "$OUT" 2>&1
check "odd --plus-prefix rejected" '[ $? != 0 ] && has "$OUT" "--plus-prefix"'
"$S/configure-getmail.sh" --imap --pwfile "$PW" --plus-headers > "$OUT" 2>&1
check "--plus-headers needs the plus options" '[ $? != 0 ] && has "$OUT" "--plus-headers needs"'
"$S/configure-mail-pull.sh" --pwfile "$PW" --plus-base me@example.org > "$OUT" 2>&1
check "pop-pull --plus-base warns about cPanel tag folders" 'has "$OUT" "pop-pull only sees the POP inbox" && has "$OUT" "configure-getmail.sh --imap"'
"$S/configure-mail-pull.sh" --pwfile "$PW" > /dev/null 2>&1      # leave pop-pull as the puller

# --------------------------------------------------------------------------
t "configure-sendmail-relay --print (generic map)"
R="$S/configure-sendmail-relay.sh"
gv() { awk -v k="$2" '!/^#/ && $1 == k { print $2 }' <<<"$1"; }       # gv MAP KEY -> value
G0=$("$R" --print --fqdn mx.lan.example --user zed --relay-file "$RELAY")
check "default: the shared catch-all for the host" '[ "$(gv "$G0" @mx.lan.example)" = me@example.org ] && [ "$(gv "$G0" @mx)" = me@example.org ]'
check "default: root and admin@localhost too" '[ "$(gv "$G0" root@localhost)" = me@example.org ] && [ "$(gv "$G0" zed@localhost)" = me@example.org ]'
check "default: no per-user lines" '! grep -q "+" <<<"$G0"'
G1=$("$R" --print --fqdn mx.lan.example --user zed --relay-file "$RELAY" --plus-users chris,miche)
check "per-user: chris@host -> base+chris@domain" '[ "$(gv "$G1" chris@mx.lan.example)" = me+chris@example.org ] && [ "$(gv "$G1" chris@mx)" = me+chris@example.org ] && [ "$(gv "$G1" chris@localhost)" = me+chris@example.org ]'
check "per-user: miche too" '[ "$(gv "$G1" miche@mx.lan.example)" = me+miche@example.org ]'
check "per-user: catch-all kept for root/system" '[ "$(gv "$G1" @mx.lan.example)" = me@example.org ] && [ "$(gv "$G1" root@localhost)" = me@example.org ] && [ "$(gv "$G1" zed@localhost)" = me@example.org ]'
check "per-user: no duplicate keys" '[ -z "$(awk "!/^#/ && NF { print \$1 }" <<<"$G1" | sort | uniq -d)" ]'
G2=$("$R" --print --fqdn mx.lan.example --user chris --relay-file "$RELAY" --plus-users chris)
check "admin user in the list: its @localhost line is the per-user one, once" '[ "$(gv "$G2" chris@localhost)" = me+chris@example.org ] && [ "$(awk "\$1 == \"chris@localhost\"" <<<"$G2" | wc -l)" = 1 ]'
G3=$("$R" --print --fqdn mx.lan.example --relay-file "$RELAY" --plus-users chris,chris --plus-base shared@example.net)
check "--plus-base overrides the login; repeated users collapse" '[ "$(gv "$G3" chris@mx)" = shared+chris@example.net ] && [ "$(awk "\$1 == \"chris@mx\"" <<<"$G3" | wc -l)" = 1 ]'
"$R" --print --relay-file "$RELAY" --plus-users root > "$OUT" 2>&1
check "root can't be a per-user sender" '[ $? != 0 ] && has "$OUT" "root'\''s mail stays"'
"$R" --print --relay-file "$RELAY" --plus-users 'chris,Bob' > "$OUT" 2>&1
check "bad user name rejected" '[ $? != 0 ] && has "$OUT" "plain lower-case login name"'
"$R" --print --relay-file "$RELAY" --plus-users chris --plus-base 'a+b@c.org' > "$OUT" 2>&1
check "tagged base rejected" '[ $? != 0 ] && has "$OUT" "must be a plain address"'
"$R" --print --relay-file "$RELAY" --plus-base cwp@u-l.ca > "$OUT" 2>&1
check "--plus-base without --plus-users rejected" '[ $? != 0 ] && has "$OUT" "only makes sense with --plus-users"'

# --------------------------------------------------------------------------
t "configure-sendmail-relay --print-header-checks (loud and proud)"
PWF="$SANDBOX/passwd"
printf 'root:x:0:0::/root:/bin/sh
chris:x:1000:1000::/h:/bin/sh
miche:x:1001:1001::/h:/bin/sh
daemon:x:1:1::/:/bin/false
nobody:x:65534:65534::/:/bin/false
' > "$PWF"
HC=$(MAIL_SETUP_PASSWD="$PWF" "$R" --print-header-checks --fqdn mx.lan.example)
check "a rule per human account (and root), none for system users" 'has_str() { grep -qF -- "$2" <<<"$1"; }; has_str "$HC" "from userid 1000" && has_str "$HC" "from userid 1001" && has_str "$HC" "from userid 0" && ! grep -q "userid 1\\)" <<<"$HC" && ! grep -q "userid 65534" <<<"$HC"'
check "names the user and the tool" 'grep -q "PREPEND X-Relayed-By: Postfix on \${1} (submitted by chris, uid 1000)" <<<"$HC"'
check "catch-all for any other uid comes last" '[ "$(grep -v "^#" <<<"$HC" | tail -1 | grep -c "(submitted by uid \${2})")" = 1 ]'
PYX=$(find_python 2>/dev/null || command -v python3 || true)
if [ -n "$PYX" ]; then
  # the table must really match Postfix's own Received line and expand its captures
  got=$(HCT="$HC" "$PYX" -c '
import os, re
line = "Received: by mx.lan.example (Postfix, from userid %s)"
for uid in ("1000", "4242"):
    for rule in os.environ["HCT"].splitlines():
        if rule.startswith("#"): continue
        pat, act = rule.split(" PREPEND ", 1)
        m = re.match(pat[1:-1], line % uid)
        if m:
            print(re.sub(r"\$\{(\d)\}", lambda g: m.group(int(g.group(1))), act)); break
')
  check "chris's local mail gets chris + the host" '[ "$(sed -n 1p <<<"$got")" = "X-Relayed-By: Postfix on mx.lan.example (submitted by chris, uid 1000)" ]'
  check "an unknown uid still gets stamped" '[ "$(sed -n 2p <<<"$got")" = "X-Relayed-By: Postfix on mx.lan.example (submitted by uid 4242)" ]'
fi

# --------------------------------------------------------------------------
t "configure-sendmail-relay (sandboxed Postfix)"
# fake postfix tools + a Linux-looking uname, first on PATH for these runs only;
# /etc/postfix and /etc/aliases are replaced by sandbox paths
PFAKE="$SANDBOX/pfake"; mkdir -p "$PFAKE"
export FAKE_CALLS="$SANDBOX/calls"
cat > "$PFAKE/uname" <<'EOF'
#!/bin/sh
[ "$1" = -s ] && { echo Linux; exit 0; }
exec /usr/bin/uname "$@"
EOF
cat > "$PFAKE/postmap" <<'EOF'
#!/bin/sh
echo "postmap $*" >> "$FAKE_CALLS"
case "${FAKE_POSTMAP_FAIL:-}:$*" in
  outside:*/pf*/*) ;;                   # building inside the fake /etc/postfix is fine
  outside:*) exit 1 ;;                  # ... the temp-dir test build is what fails
  inside:*/pf*/generic*) exit 1 ;;
esac
if [ "$1" = -q ]; then                  # postmap -q KEY hash:FILE
  case "$3" in regexp:*) [ -f "${3#regexp:}" ] && echo "PREPEND X-Relayed-By: fake" && exit 0; exit 1 ;; esac
  f=${3#hash:}
  awk -v k="$2" '!/^#/ && $1 == k { print $2; found = 1 } END { exit !found }' "$f"
  exit
fi
f=${1#hash:}; [ -f "$f" ] || exit 1; touch "$f.db"
EOF
cat > "$PFAKE/postfix" <<'EOF'
#!/bin/sh
echo "postfix $*" >> "$FAKE_CALLS"
case "$1" in
  check)  [ "${FAKE_POSTFIX_CHECK_RC:-0}" = 0 ] || { echo "postfix: fatal: fake check failure" >&2; exit 1; } ;;
  status) exit 1 ;;
esac
exit 0
EOF
for n in postconf newaliases systemctl chown; do   # chown: the relay chowns sasl_passwd to root:group
  printf '#!/bin/sh\necho "%s $*" >> "$FAKE_CALLS"\nexit 0\n' "$n" > "$PFAKE/$n"
done
chmod 755 "$PFAKE"/*
PF="$SANDBOX/pf"; mkdir -p "$PF"
relay() {   # relay ARGS... (extra env comes from the caller)
  PATH="$PFAKE:$PATH" MAIL_SETUP_POSTFIX_DIR="$PF" MAIL_SETUP_ALIASES="$SANDBOX/aliases" \
    SMARTHOST_PASS_ENV=sekrit "$R" --relay-file "$RELAY" --user zed --service systemd \
    --fqdn mx.lan.example "$@"
}
: > "$FAKE_CALLS"
relay > "$OUT" 2>&1
check "plain run exits 0" '[ $? = 0 ]'
check "generic written + postmapped" 'has "$PF/generic" "@mx.lan.example" && [ -f "$PF/generic.db" ]'
check "smtp_generic_maps points at it" 'has "$FAKE_CALLS" "smtp_generic_maps = hash:$PF/generic"'
check "sasl_passwd line" 'has "$PF/sasl_passwd" "[out.example.org]:465 me@example.org:sekrit"'    # the relay file says 465: SMTPS is kept
# root:<your group> 0640, not 600: the pullers run as you and read it
check_mode "sasl_passwd is mode 640" "$PF/sasl_passwd" 640
check_mode "sasl_passwd.db is mode 640" "$PF/sasl_passwd.db" 640
check "root alias added" 'has "$SANDBOX/aliases" "root: zed"'
check "header_checks table installed + added to header_checks" 'has "$PF/header_checks" "PREPEND X-Relayed-By:" && has "$FAKE_CALLS" "header_checks = regexp:$PF/header_checks"'
check "no per-user lines by default" '! grep -q "+" "$PF/generic"'
relay --plus-users chris,miche > "$OUT" 2>&1
check "--plus-users run exits 0" '[ $? = 0 ]'
check "per-user lines installed" 'has "$PF/generic" "chris@mx.lan.example" && has "$PF/generic" "me+miche@example.org"'
check "announced" 'has "$OUT" "per-user   : chris, miche -> me+USER@example.org"'
check "old map backed up (and its .db)" 'ls "$PF"/generic.bak.* >/dev/null 2>&1 && ls "$PF"/generic.bak.*.db >/dev/null 2>&1'
check "installed map was looked up and checked" 'has "$FAKE_CALLS" "postmap -q chris@mx.lan.example hash:$PF/generic" && has "$FAKE_CALLS" "postfix check"'
GOOD="$SANDBOX/generic.good"; cp "$PF/generic" "$GOOD"

: > "$FAKE_CALLS"
FAKE_POSTFIX_CHECK_RC=1 relay --plus-users chris > "$OUT" 2>&1
check "failed 'postfix check': non-zero, says so" '[ $? != 0 ] && has "$OUT" "new generic map rejected"'
check "... and the previous map is back" 'cmp -s "$PF/generic" "$GOOD"'
check "... and Postfix was not started/reloaded" '! has "$FAKE_CALLS" "systemctl enable" && ! has "$FAKE_CALLS" "postfix reload"'

: > "$FAKE_CALLS"
FAKE_POSTMAP_FAIL=outside relay --plus-users chris > "$OUT" 2>&1
check "map postmap rejects up front: non-zero" '[ $? != 0 ] && has "$OUT" "nothing was changed"'
check "... before main.cf or anything else is touched" '! has "$FAKE_CALLS" "postconf" && cmp -s "$PF/generic" "$GOOD"'

FAKE_POSTMAP_FAIL=inside relay --plus-users chris > "$OUT" 2>&1
check "postmap failing on the installed map: non-zero, rolled back" '[ $? != 0 ] && cmp -s "$PF/generic" "$GOOD" && [ -f "$PF/generic.db" ]'

rm -rf "$PF"; mkdir -p "$PF"
FAKE_POSTFIX_CHECK_RC=1 relay > "$OUT" 2>&1
check "first-ever install that fails leaves no generic behind" '[ $? != 0 ] && [ ! -e "$PF/generic" ] && [ ! -e "$PF/generic.db" ]'
rm -rf "$PF"; mkdir -p "$PF"
if [ "$(uname -s)" != Linux ]; then
  "$R" --relay-file "$RELAY" > "$OUT" 2>&1
  check "refuses to run off Linux" '[ $? != 0 ] && has "$OUT" "Linux only"'
fi

# --------------------------------------------------------------------------
t "configure-mailutils"
printf 'mhost\n143\nme\nmhost\n25\np@ss:w/rd\n' \
  | ASSUME=yes "$S/configure-mailutils.sh" --role client > "$OUT" 2>&1
check "exits 0" '[ $? = 0 ]'
check "finds (fake) Mailutils, no install" 'has "$OUT" "GNU Mailutils: found"'
check "~/.mail mailbox + folder + mailer" 'has "$HOME/.mail" "mailbox-pattern \"imap://me@mhost:143/INBOX\";" && has "$HOME/.mail" "folder \"imap://me@mhost:143/\";" && has "$HOME/.mail" "url \"smtp://mhost:25\";"'
check "~/.mailrc pins xmailer (User-Agent on outgoing mail)" 'has "$HOME/.mailrc" "set xmailer"'
check "~/.mu-tickets URL-encodes the password" 'has "$HOME/.mu-tickets" "*://me:p%40ss%3Aw%2Frd@mhost"'
check_mode "~/.mu-tickets is mode 600" "$HOME/.mu-tickets"
printf 'mhost\n143\nme\nmhost\n25\nnewpw\n' | ASSUME=yes "$S/configure-mailutils.sh" > /dev/null 2>&1
check "re-run replaces that host's ticket, doesn't duplicate" '[ "$(grep -c "@mhost$" "$HOME/.mu-tickets")" = 1 ] && has "$HOME/.mu-tickets" "me:newpw@mhost"'
check "re-run doesn't repeat the ~/.mailrc block" '[ "$(grep -c "^set xmailer" "$HOME/.mailrc")" = 1 ]'
check "re-run backs up ~/.mail" 'ls "$HOME"/.mail.bak.* >/dev/null 2>&1'
ASSUME=no "$S/configure-mailutils.sh" --role master > "$OUT" 2>&1
check "--assume-no writes nothing new" '[ $? = 0 ] && has "$OUT" "Write ~/.mail and ~/.mu-tickets now? -> no"'

# --------------------------------------------------------------------------
t "install-sendmail-shim"
DEST="$SANDBOX/sbin/sendmail"; mkdir -p "$(dirname "$DEST")"; echo old > "$DEST"
SENDMAIL_DEST="$DEST" "$S/install-sendmail-shim.sh" --host master.lan --port 2525 > "$OUT" 2>&1
check "exits 0" '[ $? = 0 ]'
check "relay host/port baked in" 'grep -q "^RELAY_HOST = \"master.lan\"" "$DEST" && grep -q "^RELAY_PORT = 2525" "$DEST"'
check "executable, python shebang" '[ -x "$DEST" ] && head -1 "$DEST" | grep -q "^#!/.*python3"'
check "old sendmail kept" 'ls "$DEST".orig.* >/dev/null 2>&1'
check "compiles" 'pycheck "$DEST"'

# --------------------------------------------------------------------------
t "configure-dovecot --print"
D23=$("$S/configure-dovecot.sh" --print 2.3.21)
D24=$("$S/configure-dovecot.sh" --print 2.4.1 --plaintext --listen local)
check "2.3: mail_location" 'grep -qx "mail_location = mbox:~/mail:INBOX=/var/mail/%u" <<<"$D23"'
check "2.3: no cleartext unless asked" '! grep -q "plaintext_auth" <<<"$D23"'
check "2.3: listens everywhere by default" 'grep -qx "listen = \*, ::" <<<"$D23"'
check "2.4: mail_driver/path/inbox_path" 'grep -qx "mail_driver = mbox" <<<"$D24" && grep -qx "mail_path = ~/mail" <<<"$D24" && grep -qx "mail_inbox_path = /var/mail/%{user}" <<<"$D24"'
check "2.4: --plaintext -> auth_allow_cleartext" 'grep -qx "auth_allow_cleartext = yes" <<<"$D24"'
check "2.4: --listen local" 'grep -qx "listen = 127.0.0.1, ::1" <<<"$D24"'
check "special-use folders auto-subscribed" '[ "$(grep -c "auto = subscribe" <<<"$D23")" = 5 ] && grep -q "special_use = \\\\Junk" <<<"$D23"'
check "braces balance" '[ "$(tr -cd "{" <<<"$D24" | wc -c)" = "$(tr -cd "}" <<<"$D24" | wc -c)" ]'
"$S/configure-dovecot.sh" --print 3.0 > /dev/null 2>&1
check "unknown version rejected" '[ $? != 0 ]'
if [ "$(uname -s)" != Linux ]; then
  "$S/configure-dovecot.sh" > "$OUT" 2>&1
  check "refuses to run off Linux" '[ $? != 0 ] && has "$OUT" "Linux only"'
fi

# --------------------------------------------------------------------------
t "configure-webmin --print"
W=$("$S/configure-webmin.sh" --print --user alice)
check "alerts go to you@localhost by default" 'grep -q "alerts to : alice@localhost" <<<"$W"'
check "defaults: every 5 min, queue > 0 for 2 checks" 'grep -q "every 5 min" <<<"$W" && grep -q "queue > 0 messages for 2 checks" <<<"$W"'
check "access + webhook unchanged by default" 'grep -q "access    : unchanged" <<<"$W" && grep -q "webhook   : unchanged" <<<"$W"'
W=$("$S/configure-webmin.sh" --print --email me@example.org --every 10 --queue-max 3 --fails 1 --allow 10.1.2.3/8 --webhook https://hook.example.org/x)
check "options show up" 'grep -q "alerts to : me@example.org" <<<"$W" && grep -q "every 10 min" <<<"$W" && grep -q "queue > 3 messages for 1 checks" <<<"$W"'
check "--allow normalised, localhost kept" 'grep -q "localhost + 10.0.0.0/8" <<<"$W"'
check "--webhook shown" 'grep -q "webhook   : https://hook.example.org/x" <<<"$W"'
for bad in "--every 0" "--every 61" "--every x" "--queue-max -1" "--fails 0" "--email nobody" "--webhook ftp://x" "--allow not-a-net"; do
  "$S/configure-webmin.sh" --print $bad > /dev/null 2>&1
  check "rejects $bad" '[ $? != 0 ]'
done
if [ "$(uname -s)" != Linux ]; then
  "$S/configure-webmin.sh" > "$OUT" 2>&1
  check "refuses to run off Linux" '[ $? != 0 ] && has "$OUT" "Linux only"'
fi

t "relay failure notices"
check "delay warning + postmaster notices set" 'has "$S/configure-sendmail-relay.sh" "\"delay_warning_time = 1h\"" && has "$S/configure-sendmail-relay.sh" "\"notify_classes = resource, software, bounce, delay, 2bounce\""'
check "postmaster alias ensured" 'has "$S/configure-sendmail-relay.sh" "postmaster: root"'
check "dotless (LAN host) domains canonicalised, headers too" 'has "$S/configure-sendmail-relay.sh" "canonical_maps = regexp:\$PF_DIR/lan-canonical" && has "$S/configure-sendmail-relay.sh" "permit_mynetworks\""'
LC=$(printf '/^([^@]+)@[^.@]+$/    ${1}@%s\n' cpbee | sed -n 's|^/\(.*\)/ .*|\1|p')
check "lan-canonical regex: dotless only" 'grep -Eq "$LC" <<<"chris@cmlaptop" && ! grep -Eq "$LC" <<<"me@gmail.com" && ! grep -Eq "$LC" <<<"chris"'

# --------------------------------------------------------------------------
t "configure-sieve --print"
S23=$("$S/configure-sieve.sh" --print 2.3.21)
S24=$("$S/configure-sieve.sh" --print 2.4.1)
S23L=$("$S/configure-sieve.sh" --print 2.3.21 --listen local)
S24L=$("$S/configure-sieve.sh" --print 2.4.1 --listen local)
check "2.3: sieve protocol added" 'grep -qx "protocols = \$protocols sieve" <<<"$S23"'
check "2.3: LDA loads the sieve plugin" 'grep -qx "  mail_plugins = \$mail_plugins sieve" <<<"$S23"'
check "2.3: managesieve on 4190" 'grep -qx "    port = 4190" <<<"$S23"'
check "2.3: per-user script + active link" 'grep -qx "  sieve = file:~/sieve;active=~/.dovecot.sieve" <<<"$S23"'
check "2.3: LDA may dot-lock /var/mail" 'grep -qx "mail_privileged_group = mail" <<<"$S23"'
check "2.3: listens everywhere by default" '! grep -q "^    address = " <<<"$S23"'
check "2.3: --listen local" 'grep -qx "    address = 127.0.0.1, ::1" <<<"$S23L"'
check "2.4: protocols block" 'grep -qx "protocols {" <<<"$S24" && grep -qx "  sieve = yes" <<<"$S24"'
check "2.4: LDA plugin block" 'grep -qx "  mail_plugins {" <<<"$S24"'
check "2.4: sieve_script personal" 'grep -qx "sieve_script personal {" <<<"$S24" && grep -qx "  path = ~/sieve" <<<"$S24" && grep -qx "  active_path = ~/.dovecot.sieve" <<<"$S24"'
check "2.4: no 2.3-only settings" '! grep -q "plugin {\|\$protocols\|\$mail_plugins" <<<"$S24"'
check "2.4: --listen local" 'grep -qx "    address = 127.0.0.1, ::1" <<<"$S24L" && ! grep -q "^    address = " <<<"$S24"'
check "braces balance (2.3 and 2.4)" '[ "$(tr -cd "{" <<<"$S23L" | wc -c)" = "$(tr -cd "}" <<<"$S23L" | wc -c)" ] && [ "$(tr -cd "{" <<<"$S24L" | wc -c)" = "$(tr -cd "}" <<<"$S24L" | wc -c)" ]'
check "no blank-line gap inside the service block" '! grep -A1 "port = 4190" <<<"$S24" | grep -q "^$"'
"$S/configure-sieve.sh" --print 3.0 > /dev/null 2>&1
check "unknown version rejected" '[ $? != 0 ]'
"$S/configure-sieve.sh" --listen sideways --print 2.3 > "$OUT" 2>&1
check "bad --listen rejected" '[ $? != 0 ] && has "$OUT" "--listen must be all or local"'
"$S/configure-sieve.sh" --bogus > "$OUT" 2>&1
check "unknown argument: exit 2" '[ $? = 2 ] && has "$OUT" "unknown argument: --bogus"'
check "-h prints the usage" '"$S/configure-sieve.sh" -h | grep -q "^Usage:"'
check "--force is accepted" '"$S/configure-sieve.sh" --force --print 2.4.1 >/dev/null'
if [ "$(uname -s)" != Linux ]; then
  "$S/configure-sieve.sh" > "$OUT" 2>&1
  check "refuses to run off Linux" '[ $? != 0 ] && has "$OUT" "Linux only"'
fi

# --------------------------------------------------------------------------
t "configure-sieve firewall plan (nftables)"
# a router-style ruleset: default-drop input chain that accepts IMAP per interface
# (a real one, trimmed) - clients of 4190 would just time out
NFT="$SANDBOX/nft-drop.txt"
cat > "$NFT" <<'EOF'
table inet filter {
        chain input {
                type filter hook input priority filter; policy drop;
                ct state invalid drop
                ct state established,related accept
                iifname "lo" accept
                iifname "lan0" tcp dport { 22, 53 } accept
                iifname "lan0" tcp dport 25 accept
                iifname "lan0" tcp dport { 143, 993 } accept
                iifname "lan0" tcp dport 8080 accept
                iifname "wan0" udp sport 67 udp dport 68 accept
                iifname "vr180" ip saddr { 192.168.123.253 } tcp dport 22 accept
        }

        chain forward {
                type filter hook forward priority filter; policy drop;
                iifname "lan0" oifname "wan0" accept
        }

        chain output {
                type filter hook output priority filter; policy accept;
        }
}
table ip nat {
        chain postrouting {
                type nat hook postrouting priority srcnat; policy accept;
                oifname "wan0" masquerade
        }
}
EOF
MAIL_SETUP_NFT_RULESET="$NFT" "$S/configure-sieve.sh" --firewall-plan > "$OUT" 2>&1
check "--firewall-plan exits 0, no root needed" '[ $? = 0 ]'
check "opens 4190 where IMAP already is (lan0 only)" '[ "$(cat "$OUT")" = "nft add rule inet filter input iifname \"lan0\" tcp dport 4190 accept" ]'
# a second IMAP interface and a bare (no iifname) IMAP rule
cat > "$NFT" <<'EOF'
table ip filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iifname "lan0" tcp dport 993 accept
    iifname "lan1" tcp dport { 143, 993 } accept
    iifname "lan0" tcp dport 143 accept
  }
}
EOF
MAIL_SETUP_NFT_RULESET="$NFT" "$S/configure-sieve.sh" --firewall-plan > "$OUT" 2>&1
check "one rule per interface, no duplicates" '[ "$(wc -l < "$OUT")" = 2 ] && has "$OUT" "iifname \"lan0\" tcp dport 4190" && has "$OUT" "iifname \"lan1\" tcp dport 4190"'
printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy drop;\n  tcp dport { 143, 993 } accept\n }\n}\n' > "$NFT"
MAIL_SETUP_NFT_RULESET="$NFT" "$S/configure-sieve.sh" --firewall-plan > "$OUT" 2>&1
check "IMAP rule without an interface: rule for every interface (just printed)" '[ "$(cat "$OUT")" = "nft add rule inet filter input tcp dport 4190 accept" ]'
# nothing to do
printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy drop;\n  tcp dport { 22, 993, 4190 } accept\n }\n}\n' > "$NFT"
MAIL_SETUP_NFT_RULESET="$NFT" "$S/configure-sieve.sh" --firewall-plan > "$OUT" 2>&1
check "4190 already accepted: nothing to add" '[ ! -s "$OUT" ]'
printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy accept;\n  tcp dport 993 accept\n }\n}\n' > "$NFT"
MAIL_SETUP_NFT_RULESET="$NFT" "$S/configure-sieve.sh" --firewall-plan > "$OUT" 2>&1
check "policy accept: nothing to add" '[ ! -s "$OUT" ]'
printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy drop;\n  iifname "ev\\"il;x" tcp dport 993 accept\n }\n}\n' > "$NFT"
MAIL_SETUP_NFT_RULESET="$NFT" "$S/configure-sieve.sh" --firewall-plan > "$OUT" 2>&1
check "odd interface names are never put in a command" '[ ! -s "$OUT" ]'
MAIL_SETUP_NFT_RULESET="$SANDBOX/no-such-file" "$S/configure-sieve.sh" --firewall-plan > "$OUT" 2>&1
check "no ruleset: nothing to add, exit 0" '[ $? = 0 ] && [ ! -s "$OUT" ]'
check "-h documents --open-firewall / --firewall-plan" '"$S/configure-sieve.sh" -h | grep -q -e "--open-firewall" && "$S/configure-sieve.sh" -h | grep -q -e "--firewall-plan"'

# --------------------------------------------------------------------------
t "mail-setup.sh"
"$M/mail-setup.sh" --role client --assume-no --caller tvmail > "$OUT" 2>&1
check "client, --assume-no: exits 0" '[ $? = 0 ] && has "$OUT" "mail-setup done (role: client)"'
check "client offers the shim, not Postfix" 'has "$OUT" "sendmail shim" && ! has "$OUT" "Postfix"'
"$M/mail-setup.sh" --role master --assume-no > "$OUT" 2>&1
check "master, --assume-no: exits 0" '[ $? = 0 ] && has "$OUT" "mail-setup done (role: master)"'
check "master offers Postfix, Dovecot, a puller" 'has "$OUT" "== Postfix" && has "$OUT" "== Dovecot" && has "$OUT" "puller: pop-pull"'
check "master offers the Webmin watchdog" 'has "$OUT" "== Webmin" && has "$OUT" "configure-webmin.sh now"'
check "master offers Sieve (default no)" 'has "$OUT" "== Sieve" && has "$OUT" "configure-sieve.sh now?"'
"$M/mail-setup.sh" --role master --puller none --assume-no > "$OUT" 2>&1
check "--puller none skips the puller" 'has "$OUT" "puller: none" && ! has "$OUT" "configure-mail-pull.sh now"'
"$M/mail-setup.sh" --role boss > /dev/null 2>&1
check "bad --role rejected" '[ $? != 0 ]'
"$M/mail-setup.sh" --puller fetchmail > /dev/null 2>&1
check "bad --puller rejected" '[ $? != 0 ]'
check "-h prints the usage" '"$M/mail-setup.sh" -h | grep -q "^Usage:"'
"$M/mail-setup.sh" --plus-users chris > "$OUT" 2>&1
check "--plus-users needs --plus-base" '[ $? != 0 ] && has "$OUT" "--plus-users needs --plus-base"'
"$M/mail-setup.sh" --role master --puller getmail --plus-base cwp@u-l.ca --assume-no > "$OUT" 2>&1
check "getmail + --plus-base needs --plus-users" '[ $? != 0 ] && has "$OUT" "getmail needs --plus-users"'
"$M/mail-setup.sh" --role master --plus-base cwp@u-l.ca --plus-users chris,miche --assume-no > "$OUT" 2>&1
check "--plus-base/--plus-users accepted" '[ $? = 0 ] && has "$OUT" "mail-setup done (role: master)"'
check "-h documents them" '"$M/mail-setup.sh" -h | grep -q -- "--plus-base ADDR"'

# --------------------------------------------------------------------------
t "pull timer (cron fallback)"
cat > "$FAKE/crontab" <<'EOF'
#!/bin/sh
f="$HOME/crontab.txt"
case "$1" in
  -l) [ -f "$f" ] && cat "$f" || { echo "no crontab for you" >&2; exit 1; } ;;
  -)  t=$(cat); printf '%s\n' "$t" > "$f" ;;     # read it all first, like crontab
esac
EOF
chmod 755 "$FAKE/crontab"
echo "0 3 * * * my-own-job" > "$HOME/crontab.txt"
MAIL_SETUP_NO_SYSTEMD=1 "$S/configure-mail-pull.sh" --pwfile "$PW" --timer 7 > "$OUT" 2>&1
check "exits 0" '[ $? = 0 ]'
check "crontab line every 7 min runs mail-pull" 'grep -q "^\*/7 \* \* \* \* $HOME/bin/mail-pull .*# mail-setup: mail-pull" "$HOME/crontab.txt"'
check "your other cron jobs kept" 'has "$HOME/crontab.txt" "my-own-job"'
MAIL_SETUP_NO_SYSTEMD=1 "$S/configure-getmail.sh" --pwfile "$PW" --timer 10 > /dev/null 2>&1
check "re-run replaces it, no duplicate" '[ "$(grep -c "mail-setup: mail-pull" "$HOME/crontab.txt")" = 1 ] && grep -q "^\*/10 " "$HOME/crontab.txt"'
MAIL_SETUP_NO_SYSTEMD=1 "$S/configure-mail-pull.sh" --pwfile "$PW" --timer 90 > "$OUT" 2>&1
check ">= 60 min rounds to hourly" 'grep -q "^0 \* \* \* \* .*mail-pull" "$HOME/crontab.txt" && has "$OUT" "rounded to hourly"'
"$S/configure-mail-pull.sh" --pwfile "$PW" > /dev/null 2>&1
check "no --timer leaves the schedule alone" 'grep -q "mail-setup: mail-pull" "$HOME/crontab.txt"'
rm "$FAKE/crontab"

# --------------------------------------------------------------------------
t "LAN network helpers"
cat > "$FAKE/ip" <<'EOF'
#!/bin/sh
echo "2: eth0    inet 192.168.7.42/24 brd 192.168.7.255 scope global dynamic eth0\       valid_lft 86000sec"
EOF
chmod 755 "$FAKE/ip"
LANOUT=$(bash -c '. "$1/lib/common.sh"; lan_cidr' _ "$M")
check "lan_cidr = this box's network" '[ "$LANOUT" = 192.168.7.0/24 ]'
check "cidr_check normalises" '[ "$(bash -c ". \"$M/lib/common.sh\"; cidr_check 10.1.2.3/8")" = 10.0.0.0/8 ]'
check "cidr_check rejects junk" '! bash -c ". \"$M/lib/common.sh\"; cidr_check not-a-net"'
rm "$FAKE/ip"
check "relay script documents --lan / --no-lan" '"$S/configure-sendmail-relay.sh" -h | grep -q -- "--lan CIDR|auto" && "$S/configure-sendmail-relay.sh" -h | grep -q -- "--no-lan"'
"$M/mail-setup.sh" --pull-every soon > /dev/null 2>&1
check "mail-setup.sh rejects a bad --pull-every" '[ $? != 0 ]'
"$M/mail-setup.sh" --role master --assume-no --lan=auto --pull-every=0 > "$OUT" 2>&1
check "mail-setup.sh takes --lan= / --pull-every=" '[ $? = 0 ]'

# --------------------------------------------------------------------------
t "syntax"
for f in "$M"/mail-setup.sh "$S"/*.sh "$M"/lib/*.sh; do
  bash -n "$f" || bad "bash -n $f"
done
ok "bash -n on every script"
for f in "$M"/bin/* "$M"/tests/live/*.py; do [ -f "$f" ] || continue; pycheck "$f" || bad "compile $f"; done
ok "python compiles bin/* and tests/live/*.py"

echo
echo "shell tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
