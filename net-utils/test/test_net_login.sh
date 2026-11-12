#!/bin/bash
# Tests for net-login (ssh-mfa / sudo-mfa / telnet-netrc) and get_mfa_code.py, with a fake ssh and a fake telnet that ask for
# a code / a password the way the real ones do.  Needs expect and python3; touches only a temp dir.   Run:  bash test/test_net_login.sh
here=$(cd "$(dirname "$0")/.." && pwd)
command -v expect >/dev/null || { echo "SKIP: expect is not installed"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 is not installed"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/netlogin-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok()   { pass=$((pass+1)); }
bad()  { failn=$((failn+1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    | /'; }
has()  { case "$3" in *"$2"*) ok ;; *) bad "$1 (wanted: $2)" "$3" ;; esac; }
eq()   { [ "$2" = "$3" ] && ok || bad "$1 (wanted '$2', got '$3')"; }

SECRET=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ          # RFC 6238 test secret ("12345678901234567890")  allowlist secret
cat >"$T/tokens.json" <<EOF
{"boxhost": {"alice": "$SECRET", "chris": "$SECRET"},"shared.example.org": "$SECRET", "oldlogin": "$SECRET"}
EOF
GET="$here/get_mfa_code.py"

# ---- get_mfa_code.py ----------------------------------------------------------------------------------------------------
v=$(python3 - "$GET" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gmc", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.totp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", now=59, digits=8), m.totp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", now=1111111109, digits=8))
print(m.totp("gezd gnbv-gy3t qojq gezdgnbvgy3tqojq", now=59))
EOF
)
eq "RFC 6238 vectors" "94287082 07081804
287082" "$v"
c1=$(MFA_NO_VAULT=1 MFA_TOKENS="$T/tokens.json" python3 "$GET" boxhost alice); [[ $c1 =~ ^[0-9]{6}$ ]] && ok || bad "host+user shape gives 6 digits: $c1"
c2=$(MFA_NO_VAULT=1 MFA_TOKENS="$T/tokens.json" python3 "$GET" boxhost chris); eq "host shape, other user" "$c1" "$c2"
c3=$(MFA_NO_VAULT=1 MFA_TOKENS="$T/tokens.json" python3 "$GET" shared.example.org); eq "host-keyed string" "$c1" "$c3"
c4=$(MFA_NO_VAULT=1 MFA_TOKENS="$T/tokens.json" python3 "$GET" shared); eq "short host name falls back" "$c1" "$c4"
c5=$(MFA_NO_VAULT=1 MFA_TOKENS="$T/tokens.json" python3 "$GET" otherhost oldlogin); eq "old shape keyed by login" "$c1" "$c5"
out=$(MFA_NO_VAULT=1 MFA_TOKENS="$T/tokens.json" python3 "$GET" nosuchhost 2>&1); rc=$?
eq "unknown host exits 1" 1 "$rc"; case "$out" in *"$SECRET"*) bad "secret leaked in error";; *) ok;; esac
python3 "$GET" >/dev/null 2>&1; eq "no args exits 2" 2 $?

# ---- fakes --------------------------------------------------------------------------------------------------------------
cat >"$T/fakessh" <<'EOF'
#!/bin/bash
# fake ssh: [-t] [opts] host [cmd...];  with "sudo" as the command it behaves like sudo with a password and a code
while [[ $1 == -* ]]; do case $1 in -o|-l|-p) shift ;; esac; shift; done
host=${1#*@}; shift
want() { MFA_NO_VAULT=1 MFA_TOKENS="$FAKE_TOKENS" python3 "$FAKE_GET" "$host" ${FAKE_USER:-} ; }
if [ "$1" = sudo ]; then
  shift; n=0
  while [ $n -lt 3 ]; do
    printf '[sudo] password for chris: '; read -r -s pw; echo
    if [ "$pw" != "$FAKE_PW" ]; then echo "Sorry, try again."; n=$((n+1)); continue; fi
    if [ -n "${FAKE_CODE:-1}" ]; then printf 'Verification code: '; read -r code; echo; [ "$code" = "$(want)" ] || { echo "Sorry, try again."; n=$((n+1)); continue; }; fi
    echo "sudo-ok: $*"; exit 7
  done
  echo "sudo: 3 incorrect password attempts"; exit 1   # allowlist secret
fi
printf 'Token: '; read -r code; echo
if [ "$code" != "$(want)" ]; then echo "Permission denied, please try again."; printf 'Token: '; read -r code; echo; [ "$code" = "$(want)" ] || { echo "Permission denied (publickey,keyboard-interactive)."; exit 255; }; fi
echo "Ready!"
if [ $# -gt 0 ]; then echo "ran on $host: $*"; exit 3; fi
echo "interactive on $host"; sleep 1; exit 0
EOF
cat >"$T/faketelnet" <<'EOF'
#!/bin/bash
printf 'Username: '; read -r u; echo
printf 'Password: '; read -r -s p; echo
if [ "$u" = "$FAKE_TUSER" ] && [ "$p" = "$FAKE_TPW" ]; then echo "Welcome to $1:$2"; sleep 1; echo "logged-in-as $u"; sleep 1; exit 0; fi
echo "Invalid login"; exit 1
EOF
chmod +x "$T/fakessh" "$T/faketelnet"
mkdir "$T/bin"; for n in ssh-mfa sudo-mfa telnet-netrc ssh-box sudo-box telnet-bad; do ln -s "$here/net-login" "$T/bin/$n"; done
printf 'box   boxhost   alice   Ready!\ndefault-telnet vax.example.org\n' >"$T/aliases"
{ echo '# comment'
  echo 'machine other.example.org login nobody password nope'                   # allowlist secret
  echo 'machine vax.example.org'
  echo '  login system password "pa ss\"w0rd"'                                   # allowlist secret
  echo 'machine boxhost login chris password sudopw'                            # allowlist secret
  echo 'machine boxhost login alice password alicepw'                           # allowlist secret
  echo 'default login anon password anonpw'; } >"$T/netrc"                       # allowlist secret
chmod 600 "$T/netrc"
export MFA_SSH="$T/fakessh" MFA_TELNET="$T/faketelnet" MFA_NETRC="$T/netrc" MFA_ALIASES="$T/aliases" MFA_GETCODE="$GET" MFA_QUIET=1
export FAKE_TOKENS="$T/tokens.json" FAKE_GET="$GET" MFA_NO_VAULT=1 MFA_TOKENS="$T/tokens.json" FAKE_PW=sudopw FAKE_TUSER=system FAKE_TPW='pa ss"w0rd'

# ---- ssh mode -----------------------------------------------------------------------------------------------------------
out=$(FAKE_USER=alice "$T/bin/ssh-mfa" alice@boxhost 'uptime -p' </dev/null 2>&1); rc=$?
has "ssh-mfa: command ran" "ran on boxhost: uptime -p" "$out"; eq "ssh-mfa: remote status passed on" 3 "$rc"
case "$out" in *"Token: "*) ok;; *) bad "ssh-mfa: saw the prompt" "$out";; esac
out=$(FAKE_USER=alice "$T/bin/ssh-box" -o StrictHostKeyChecking=no 'echo hi' </dev/null 2>&1); rc=$?
has "ssh-box alias: host from the aliases file" "ran on boxhost: echo hi" "$out"; eq "ssh-box: status" 3 "$rc"
out=$( (sleep 4) | FAKE_USER=alice "$T/bin/ssh-box" 2>&1 ); rc=$?
has "ssh-box interactive: reached the shell" "interactive on boxhost" "$out"; eq "ssh-box interactive: status 0" 0 "$rc"
out=$(FAKE_USER=alice "$T/bin/ssh-mfa" -l alice -p 2222 boxhost 'a b' </dev/null 2>&1); has "ssh-mfa: option with a value is not the host" "ran on boxhost: a b" "$out"
out=$(FAKE_USER=alice "$here/net-login" ssh alice@boxhost true </dev/null 2>&1); has "net-login ssh: mode as first word" "ran on boxhost: true" "$out"
out=$(FAKE_USER=wrong MFA_TRIES=1 "$T/bin/ssh-mfa" alice@boxhost true </dev/null 2>&1); rc=$?
case "$out" in *"login failed"*|*"giving up"*) ok;; *) bad "ssh-mfa: rejected code ends the login" "$out";; esac; eq "ssh-mfa: rejected exit status" 1 "$rc"
out=$("$T/bin/ssh-mfa" </dev/null 2>&1); rc=$?; eq "ssh-mfa: no host is a usage error" 2 "$rc"
out=$("$T/bin/ssh-mfa" --help </dev/null 2>&1); has "ssh-mfa --help" "ssh-mfa    HOST" "$out"

# ---- sudo mode ----------------------------------------------------------------------------------------------------------
out=$(FAKE_USER=chris "$T/bin/sudo-mfa" boxhost id -un </dev/null 2>&1); rc=$?
has "sudo-mfa: password and code answered" "sudo-ok: id -un" "$out"; eq "sudo-mfa: sudo's status passed on" 7 "$rc"
case "$out" in *sudopw*) bad "sudo-mfa: password echoed" "$out";; *) ok;; esac   # allowlist secret
out=$(FAKE_USER=chris FAKE_CODE= "$T/bin/sudo-mfa" boxhost id </dev/null 2>&1); has "sudo-mfa: password only (no code prompt)" "sudo-ok: id" "$out"
out=$(FAKE_USER=chris FAKE_PW=different "$T/bin/sudo-mfa" boxhost id </dev/null 2>&1); rc=$?
has "sudo-mfa: wrong password stops" "sudo password rejected" "$out"; eq "sudo-mfa: wrong password status" 1 "$rc"   # allowlist secret
out=$(FAKE_USER=alice FAKE_PW=alicepw "$T/bin/sudo-box" id </dev/null 2>&1); has "sudo-box: alias user picks that netrc login" "sudo-ok: id" "$out"
out=$(FAKE_USER=chris "$T/bin/sudo-mfa" nohost.example.org id </dev/null 2>&1); has "sudo-mfa: unknown host uses the netrc default entry (wrong password here)" "sudo password rejected" "$out"   # allowlist secret
out=$(MFA_NETRC="$T/missing" "$T/bin/sudo-mfa" boxhost id </dev/null 2>&1); rc=$?; eq "sudo-mfa: no netrc is an error" 1 "$rc"

# ---- sudo mode, local (no ssh) -------------------------------------------------------------------------------------------
cat >"$T/fakesudo" <<'EOF'
#!/bin/bash
# fake local sudo: password, then a code, then runs "as root"
host=$(hostname -s); me=$(id -un)
n=0
while [ $n -lt 3 ]; do
  printf '[sudo] password for %s: ' "$me"; read -r -s pw; echo
  if [ "$pw" != "$FAKE_LPW" ]; then echo "Sorry, try again."; n=$((n+1)); continue; fi
  printf 'Verification code: '; read -r code; echo
  [ "$code" = "$(MFA_NO_VAULT=1 MFA_TOKENS="$FAKE_TOKENS" python3 "$FAKE_GET" "$host" "$me")" ] || { echo "Sorry, try again."; n=$((n+1)); continue; }
  echo "local-sudo-ok: $*"; exit 4
done
echo "sudo: 3 incorrect password attempts"; exit 1   # allowlist secret
EOF
chmod +x "$T/fakesudo"
LH=$(hostname -s); LU=$(id -un)
printf '{"%s": {"%s": "%s"}}\n' "$LH" "$LU" "$SECRET" >"$T/ltokens.json"
printf 'machine %s login %s password localpw\n' "$LH" "$LU" >"$T/lnetrc"; chmod 600 "$T/lnetrc"      # allowlist secret
printf 'machine elsewhere login a password b\n' >"$T/lnetrc3"; chmod 600 "$T/lnetrc3"      # allowlist secret
ln -s "$here/net-login" "$T/bin/sudo-local"
export FAKE_LPW=localpw
lenv() { MFA_SUDO="$T/fakesudo" MFA_NETRC="$T/lnetrc" MFA_TOKENS="$T/ltokens.json" FAKE_TOKENS="$T/ltokens.json" "$@"; }
out=$(lenv "$T/bin/sudo-mfa" --local id -un </dev/null 2>&1); rc=$?
has "sudo-mfa --local: password and code answered" "local-sudo-ok: id -un" "$out"; eq "sudo-mfa --local: status passed on" 4 "$rc"
out=$(lenv "$T/bin/sudo-local" systemctl status ssh </dev/null 2>&1); has "sudo-local (by name)" "local-sudo-ok: systemctl status ssh" "$out"
out=$(lenv "$T/bin/sudo-mfa" "$LH" id </dev/null 2>&1); has "sudo-mfa with this machine's own name" "local-sudo-ok: id" "$out"
out=$(lenv "$T/bin/sudo-mfa" localhost -u root id </dev/null 2>&1); has "sudo-mfa localhost, sudo options kept" "local-sudo-ok: -u root id" "$out"
out=$(MFA_LOCAL=1 lenv "$T/bin/sudo-mfa" id </dev/null 2>&1); has "sudo-mfa with MFA_LOCAL=1" "local-sudo-ok: id" "$out"
out=$( (sleep 3) | lenv "$T/bin/sudo-mfa" --local -u root 2>&1 ); has "sudo-mfa --local with only options is interactive (runs, ok)" "local-sudo-ok: -u root" "$out"
out=$(FAKE_LPW=other lenv "$T/bin/sudo-mfa" --local id </dev/null 2>&1); rc=$?
has "sudo-mfa --local: wrong password stops" "sudo password rejected" "$out"; eq "sudo-mfa --local: wrong password status" 1 "$rc"   # allowlist secret
out=$(MFA_NETRC="$T/lnetrc3" MFA_SUDO="$T/fakesudo" "$T/bin/sudo-mfa" --local id </dev/null 2>&1); rc=$?
has "sudo-mfa --local: no netrc entry for this machine" "no entry for $LH" "$out"; eq "sudo-mfa --local: no entry status" 1 "$rc"

# ---- telnet mode --------------------------------------------------------------------------------------------------------
out=$( (sleep 5) | "$T/bin/telnet-netrc" vax.example.org 2323 2>&1 ); has "telnet-netrc: logged in with a quoted password" "logged-in-as system" "$out"
has "telnet-netrc: port passed" "Welcome to vax.example.org:2323" "$out"
out=$( (sleep 5) | "$T/bin/telnet-netrc" 2>&1 ); has "telnet-netrc: no host uses default-telnet" "Welcome to vax.example.org:23" "$out"
out=$( (sleep 5) | "$T/bin/telnet-netrc" vax 2>&1 ); has "telnet-netrc: short name matches" "Welcome to vax:23" "$out"
printf 'machine vax.example.org login system password wrong\n' >"$T/netrc2"; chmod 600 "$T/netrc2"   # allowlist secret
out=$(MFA_NETRC="$T/netrc2" "$T/bin/telnet-netrc" vax.example.org </dev/null 2>&1); has "telnet-netrc: bad password shows the host's answer" "Invalid login" "$out"
printf 'machine elsewhere login a password b\n' >"$T/netrc3"; chmod 600 "$T/netrc3"
out=$(MFA_NETRC="$T/netrc3" "$T/bin/telnet-netrc" vax.example.org </dev/null 2>&1); rc=$?
has "telnet-netrc: no entry" "no entry for vax.example.org" "$out"; eq "telnet-netrc: no entry status" 1 "$rc"
out=$("$T/bin/telnet-bad" </dev/null 2>&1); rc=$?; has "unknown shortcut" 'no shortcut "bad"' "$out"; eq "unknown shortcut status" 2 "$rc"
out=$("$here/net-login" 2>&1); rc=$?; eq "net-login with no mode is a usage error" 2 "$rc"

echo "net-login tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
