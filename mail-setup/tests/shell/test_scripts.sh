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
check_mode() {   # check_mode "what" FILE
  _f=$2   # check() evals in its own scope, where $2 is the expression
  if [ "$MODES" = 1 ]; then check "$1" '[ "$(mode "$_f")" = 600 ]'
  else ok "$1 (skipped: this filesystem ignores chmod)"; fi
}

cat > "$FAKE/mda" <<'EOF'
#!/bin/sh
cat >> "$HOME/delivered"
EOF
cat > "$FAKE/getmail" <<'EOF'
#!/bin/sh
echo "fake-getmail $*"
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
t "configure-mailutils"
printf 'mhost\n143\nme\nmhost\n25\np@ss:w/rd\n' \
  | ASSUME=yes "$S/configure-mailutils.sh" --role client > "$OUT" 2>&1
check "exits 0" '[ $? = 0 ]'
check "finds (fake) Mailutils, no install" 'has "$OUT" "GNU Mailutils: found"'
check "~/.mail mailbox + folder + mailer" 'has "$HOME/.mail" "mailbox-pattern \"imap://me@mhost:143/INBOX\";" && has "$HOME/.mail" "folder \"imap://me@mhost:143/\";" && has "$HOME/.mail" "url \"smtp://mhost:25\";"'
check "~/.mu-tickets URL-encodes the password" 'has "$HOME/.mu-tickets" "*://me:p%40ss%3Aw%2Frd@mhost"'
check_mode "~/.mu-tickets is mode 600" "$HOME/.mu-tickets"
printf 'mhost\n143\nme\nmhost\n25\nnewpw\n' | ASSUME=yes "$S/configure-mailutils.sh" > /dev/null 2>&1
check "re-run replaces that host's ticket, doesn't duplicate" '[ "$(grep -c "@mhost$" "$HOME/.mu-tickets")" = 1 ] && has "$HOME/.mu-tickets" "me:newpw@mhost"'
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
t "mail-setup.sh"
"$M/mail-setup.sh" --role client --assume-no --caller tvmail > "$OUT" 2>&1
check "client, --assume-no: exits 0" '[ $? = 0 ] && has "$OUT" "mail-setup done (role: client)"'
check "client offers the shim, not Postfix" 'has "$OUT" "sendmail shim" && ! has "$OUT" "Postfix"'
"$M/mail-setup.sh" --role master --assume-no > "$OUT" 2>&1
check "master, --assume-no: exits 0" '[ $? = 0 ] && has "$OUT" "mail-setup done (role: master)"'
check "master offers Postfix, Dovecot, a puller" 'has "$OUT" "== Postfix" && has "$OUT" "== Dovecot" && has "$OUT" "puller: pop-pull"'
"$M/mail-setup.sh" --role master --puller none --assume-no > "$OUT" 2>&1
check "--puller none skips the puller" 'has "$OUT" "puller: none" && ! has "$OUT" "configure-mail-pull.sh now"'
"$M/mail-setup.sh" --role boss > /dev/null 2>&1
check "bad --role rejected" '[ $? != 0 ]'
"$M/mail-setup.sh" --puller fetchmail > /dev/null 2>&1
check "bad --puller rejected" '[ $? != 0 ]'
check "-h prints the usage" '"$M/mail-setup.sh" -h | grep -q "^Usage:"'

# --------------------------------------------------------------------------
t "syntax"
for f in "$M"/mail-setup.sh "$S"/*.sh "$M"/lib/*.sh; do
  bash -n "$f" || bad "bash -n $f"
done
ok "bash -n on every script"
for f in "$M"/bin/*; do [ -f "$f" ] || continue; pycheck "$f" || bad "compile $f"; done
ok "python compiles bin/*"

echo
echo "shell tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
