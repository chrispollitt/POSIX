#!/usr/bin/env bash
#
# test_chat_setup.sh - tests for chat-setup's scripts.
#
# Only the parts that need no root, no network and no Linux: the ircd.yaml
# made from a default.yaml, the systemd unit, the download pin, the firewall
# plan, the option checks, ergo-register.py against a fake NickServ, and
# configure-tvchat.sh's edits of a tvchat.conf and ~/.netrc (offline).
# Installing Ergo for real is left to a run on the box itself.
#
# Exit 0 = all passed, 1 = something failed.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
C=$(CDPATH= cd -- "$here/.." && pwd)
E="$C/scripts/configure-ergo.sh"
FIX="$here/fixtures"

PASS=0; FAIL=0; CUR=""
t()    { CUR="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  ok    %s: %s\n' "$CUR" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s: %s\n' "$CUR" "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }        # check "what" 'test-expr'
has()  { grep -qF -- "$2" "$1"; }                                   # has FILE TEXT

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CHAT_SETUP_SUDO=""
export CHAT_SETUP_IFACE=lan0                 # the box's interfaces don't matter here
export CHAT_SETUP_LAN_PORTS="$SANDBOX/no-ports-file"
PY=$(command -v python3)
OUT="$SANDBOX/out"
ergo() { "$E" --listen 192.168.10.1 --server-name cpbee.lan --network cmnet "$@"; }

# --------------------------------------------------------------------------
t "syntax"
check "bash -n configure-ergo.sh" 'bash -n "$E"'
check "ergo-register.py compiles" '"$PY" -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], \"exec\")" "$C/scripts/ergo-register.py"'
check "-h prints the usage" '"$E" -h | grep -q "^Usage:"'

# --------------------------------------------------------------------------
t "ircd.yaml from default.yaml"
ergo --print-config "$FIX/default.yaml" > "$SANDBOX/ircd.yaml" 2> "$OUT"
check "exits 0" '[ $? = 0 ]'
Y="$SANDBOX/ircd.yaml"
check "says where it came from" 'head -1 "$Y" | grep -q "written by chat-setup/scripts/configure-ergo.sh from Ergo 2.19.1"'
check "network name" 'grep -qx "    name: cmnet" "$Y"'
check "server name" 'grep -qx "    name: cpbee.lan" "$Y"'
check "TLS on the LAN address only" 'grep -qx "        \"192.168.10.1:6697\":" "$Y" && ! grep -q "^        \":6697\":" "$Y"'
check "absolute certificate paths" 'grep -qx "                cert: /etc/ergo/tls/fullchain.pem" "$Y" && grep -qx "                key: /etc/ergo/tls/privkey.pem" "$Y"'
check "the commented websocket example is untouched" 'grep -qx "        #         cert: fullchain.pem" "$Y"'
check "plaintext stays on loopback" 'grep -q "^        \"127.0.0.1:6667\":" "$Y"'
check "motd + languages paths" 'grep -qx "    motd: /etc/ergo/ergo.motd" "$Y" && grep -qx "    path: /opt/ergo/current/languages" "$Y"'
ergo --port 7000 --print-config "$FIX/default.yaml" | grep -qx '        "192.168.10.1:7000":'
check "--port" '[ $? = 0 ]'
# a default.yaml that moved on: stop, write nothing half-done
sed 's/name: ErgoTest/name: SomethingElse/' "$FIX/default.yaml" > "$SANDBOX/changed.yaml"
ergo --print-config "$SANDBOX/changed.yaml" > "$SANDBOX/half.yaml" 2> "$OUT"
check "a changed default.yaml fails" '[ $? != 0 ]'
check "  and says which block" 'has "$OUT" "expected exactly one" && has "$OUT" "name: ErgoTest"'
check "  and prints no config" '[ ! -s "$SANDBOX/half.yaml" ]'
# the real default.yaml, when a copy is at hand (ERGO_DEFAULT_YAML=...)
if [ -n "${ERGO_DEFAULT_YAML:-}" ] && [ -f "$ERGO_DEFAULT_YAML" ]; then
  check "the real default.yaml converts" 'ergo --print-config "$ERGO_DEFAULT_YAML" > /dev/null'
fi

# --------------------------------------------------------------------------
t "systemd unit + download"
"$E" --print-unit > "$SANDBOX/unit"
check "runs /opt/ergo/current/ergo with /etc/ergo/ircd.yaml" 'has "$SANDBOX/unit" "ExecStart=/opt/ergo/current/ergo run --conf /etc/ergo/ircd.yaml"'
check "as the ergo user, in /var/lib/ergo" 'has "$SANDBOX/unit" "User=ergo" && has "$SANDBOX/unit" "WorkingDirectory=/var/lib/ergo"'
check "sandboxed: only /var/lib/ergo writable" 'has "$SANDBOX/unit" "ProtectSystem=strict" && has "$SANDBOX/unit" "ReadWritePaths=/var/lib/ergo"'
check "reload is a HUP" 'has "$SANDBOX/unit" "ExecReload=/bin/kill -HUP \$MAINPID"'
CHAT_SETUP_ARCH=x86_64 "$E" --print-download > "$OUT"
check "x86_64: the release URL" 'has "$OUT" "https://github.com/ergochat/ergo/releases/download/v2.19.1/ergo-2.19.1-linux-x86_64.tar.gz"'
check "x86_64: the pinned SHA-256" 'has "$OUT" "c275f2de8e8eb074c38707136392290172400b5b78616cb9f660351527924b47"'
CHAT_SETUP_ARCH=aarch64 "$E" --print-download > "$OUT"
check "aarch64 -> linux-arm64" 'has "$OUT" "ergo-2.19.1-linux-arm64.tar.gz" && has "$OUT" "3f68fee0"'
CHAT_SETUP_ARCH=x86_64 "$E" --version 2.18.0 --print-download > "$OUT"
check "another version: no pin, says so" 'has "$OUT" "v2.18.0/ergo-2.18.0-linux-x86_64.tar.gz" && has "$OUT" "no pinned SHA-256"'
CHAT_SETUP_ARCH=sparc64 "$E" --print-download > "$OUT" 2>&1
check "an unknown CPU fails" '[ $? != 0 ] && has "$OUT" "no Ergo release for this CPU"'

# --------------------------------------------------------------------------
t "firewall plan"
NFT="$SANDBOX/ruleset"
cat > "$NFT" <<'EOF'
table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept
		iifname "lan0" tcp dport { 22, 53 } accept
		iifname "lan0" tcp dport { 143, 993, 4190 } accept
	}
	chain output {
		type filter hook output priority filter; policy accept;
	}
}
EOF
CHAT_SETUP_NFT_RULESET="$NFT" ergo --firewall-plan > "$OUT" 2>&1
check "drop policy, no rule: the nft rule on lan0" 'grep -qx "nft add rule inet filter input iifname \"lan0\" tcp dport 6697 accept" "$OUT"'
sed 's/{ 22, 53 }/{ 22, 53, 6697 }/' "$NFT" > "$NFT.open"
CHAT_SETUP_NFT_RULESET="$NFT.open" ergo --firewall-plan > "$OUT" 2>&1
check "already accepted: nothing to do" '[ ! -s "$OUT" ]'
sed 's/6697/16697/' "$NFT.open" > "$NFT.other"
CHAT_SETUP_NFT_RULESET="$NFT.other" ergo --firewall-plan > "$OUT" 2>&1
check "16697 is not 6697" 'has "$OUT" "tcp dport 6697 accept"'
sed 's/policy drop/policy accept/' "$NFT" > "$NFT.accept"
CHAT_SETUP_NFT_RULESET="$NFT.accept" ergo --firewall-plan > "$OUT" 2>&1
check "accept policy: nothing to do" '[ ! -s "$OUT" ]'
printf '443  # Apache https\n25  # Postfix\n' > "$SANDBOX/lan0-tcp-ports"
CHAT_SETUP_LAN_PORTS="$SANDBOX/lan0-tcp-ports" CHAT_SETUP_NFT_RULESET="$NFT" ergo --firewall-plan > "$OUT" 2>&1
check "cmpi-router's port list: add it there" 'has "$OUT" "add '"'"'6697  # Ergo IRC (chat-setup)'"'"' to $SANDBOX/lan0-tcp-ports, then run setup-router.sh fw"'
check "  (and no runtime rule)" '! has "$OUT" "nft add rule"'
printf '6697  # Ergo IRC (chat-setup)\n' >> "$SANDBOX/lan0-tcp-ports"
CHAT_SETUP_LAN_PORTS="$SANDBOX/lan0-tcp-ports" CHAT_SETUP_NFT_RULESET="$NFT" ergo --firewall-plan > "$OUT" 2>&1
check "  already listed: nothing to do" '[ ! -s "$OUT" ]'
# a reload rebuilds the ruleset from the file: ports open only at runtime
# (143, 993, 4190 here - live, in neither file) would close
printf '443  # Apache https\n' > "$SANDBOX/lan0-tcp-ports"
sed '/143, 993, 4190/d' "$NFT" > "$SANDBOX/nftables.conf"
CHAT_SETUP_NFT_CONF="$SANDBOX/nftables.conf" CHAT_SETUP_LAN_PORTS="$SANDBOX/lan0-tcp-ports" \
  CHAT_SETUP_NFT_RULESET="$NFT" ergo --firewall-plan > "$OUT" 2>&1
check "runtime-only ports: the reload is refused, naming them" 'has "$OUT" "REFUSED: that reload would close tcp 143 4190 993"'
printf '143  # imap\n993  # imaps\n4190  # sieve\n' >> "$SANDBOX/lan0-tcp-ports"
CHAT_SETUP_NFT_CONF="$SANDBOX/nftables.conf" CHAT_SETUP_LAN_PORTS="$SANDBOX/lan0-tcp-ports" \
  CHAT_SETUP_NFT_RULESET="$NFT" ergo --firewall-plan > "$OUT" 2>&1
check "  listed in lan0-tcp-ports: fine" 'has "$OUT" "then run setup-router.sh fw" && ! has "$OUT" "REFUSED"'
cp "$NFT" "$SANDBOX/nftables.conf"; printf '443  # Apache https\n' > "$SANDBOX/lan0-tcp-ports"
CHAT_SETUP_NFT_CONF="$SANDBOX/nftables.conf" CHAT_SETUP_LAN_PORTS="$SANDBOX/lan0-tcp-ports" \
  CHAT_SETUP_NFT_RULESET="$NFT" ergo --firewall-plan > "$OUT" 2>&1
check "  in the ruleset file already: fine" '! has "$OUT" "REFUSED"'

# --------------------------------------------------------------------------
t "options"
"$E" --listen 0.0.0.0 --print-unit > "$OUT" 2>&1
check "--listen 0.0.0.0 is refused" '[ $? != 0 ] && has "$OUT" "would serve the WAN"'
"$E" --listen lan0 --print-unit > "$OUT" 2>&1
check "--listen must be an address" '[ $? != 0 ]'
"$E" --port 70000 --print-unit > "$OUT" 2>&1
check "--port out of range" '[ $? != 0 ]'
"$E" --network 'a b' --print-unit > "$OUT" 2>&1
check "--network with a space" '[ $? != 0 ]'
"$E" --register '-x' --print-unit > "$OUT" 2>&1
check "--register a bad nick" '[ $? != 0 ] && has "$OUT" "not a valid nickname"'
"$E" --server-name cpbee --print-unit > "$OUT" 2>&1
check "--server-name without a dot" '[ $? != 0 ] && has "$OUT" "must hold a dot"'
"$E" --cert /x --print-unit > "$OUT" 2>&1
check "--cert without --key" '[ $? != 0 ] && has "$OUT" "go together"'
"$E" --bogus > "$OUT" 2>&1
check "an unknown option exits 2" '[ $? = 2 ]'

# --------------------------------------------------------------------------
t "ergo-register.py"
reg() {   # reg MODE [PASSWORD] -> client output in $OUT, server log in $OUT.srv; $? = client exit
  "$PY" "$here/fake_nickserv.py" "$1" > "$OUT.port" 2> "$OUT.srv" &
  local spid=$! port="" i
  for i in $(seq 50); do port=$(head -1 "$OUT.port" 2>/dev/null); [ -n "$port" ] && break; sleep 0.1; done
  CHAT_SETUP_PASS="${2-s3cret}" "$PY" "$C/scripts/ergo-register.py" 127.0.0.1 "$port" tester > "$OUT" 2>&1
  local rc=$?
  wait "$spid" 2>/dev/null
  return $rc
}
reg created
check "created: exit 0" '[ $? = 0 ] && has "$OUT" "account tester created"'
check "  sent NICK, USER, then REGISTER" 'has "$OUT.srv" "NICK tester" && has "$OUT.srv" "PRIVMSG NickServ :REGISTER s3cret"'
check "  answered the PING" 'has "$OUT.srv" "PONG :fake"'
check "  the password is not in its own output" '! has "$OUT" "s3cret"'
reg exists
check "already exists: exit 0, says the password is unchanged" '[ $? = 0 ] && has "$OUT" "already exists (its password is unchanged)"'
reg refuse
check "refused: exit 1 with NickServ's words" '[ $? = 1 ] && has "$OUT" "Passphrase contains forbidden characters"'
reg silent
check "no answer: exit 1" '[ $? = 1 ] && has "$OUT" "no answer from NickServ"'
CHAT_SETUP_PASS="" "$PY" "$C/scripts/ergo-register.py" 127.0.0.1 1 tester > "$OUT" 2>&1
check "no password: exit 2" '[ $? = 2 ]'

# --------------------------------------------------------------------------
t "configure-tvchat.sh"
V="$C/scripts/configure-tvchat.sh"
H="$SANDBOX/home"; TC="$H/.config/tvchat/tvchat.conf"
mkdir -p "$H/.config/tvchat"
printf '%s\n' "-----BEGIN CERTIFICATE-----" "MIIB" "-----END CERTIFICATE-----" > "$SANDBOX/ca.pem"
cat > "$TC" <<'EOF'
# my notes
[chat]
# connect these
autoconnect = libera

[account:libera]
protocol = irc
host     = irc.libera.chat
realname = Some Body
channels = #tvmail-test

# Delta Chat, later
#[account:delta]
EOF
cp "$TC" "$SANDBOX/before.conf"
# owner only: 600 (Cygwin may show 700 - it maps chmod onto Windows ACLs)
private() { case "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")" in [67]00) return 0 ;; esac; return 1; }
# TVCHAT_BACKEND= : no tvchat-backend, whatever is installed here
tv() { env -u TVCHAT_PASS_CPBEE -u TVCHAT_CONF TVCHAT_BACKEND="${TVB-}" HOME="$H" "$V" --ca "$SANDBOX/ca.pem" --no-check "$@"; }
CHAT_SETUP_PASS=pw1 tv --nick chris-pollitt --autoconnect > "$OUT" 2>&1
check "first run: exit 0" '[ $? = 0 ] && has "$OUT" "[account:cpbee] added to"'
check "  the CA copied" 'cmp -s "$SANDBOX/ca.pem" "$H/.config/tvchat/cpbee-ca.pem"'
check "  cafile is a full path" 'grep -qx "cafile   = $H/.config/tvchat/cpbee-ca.pem" "$TC"'
check "  parses, values clean, autoconnect added" '"$PY" -c "
import configparser, sys
c = configparser.ConfigParser(interpolation=None); c.read(sys.argv[1])
a = c[\"account:cpbee\"]
assert (a[\"host\"], a[\"sasl\"], a[\"channels\"], a[\"display\"]) == (\"cpbee\", \"chris-pollitt\", \"#test\", \"cpbee\"), dict(a)
assert c[\"chat\"][\"autoconnect\"] == \"libera, cpbee\"
" "$TC"'
check "  realname from the libera account" 'grep -qx "realname = Some Body" "$TC"'
# everything that was there is still there, in order, the new section after it
check "  the rest of the file kept" '"$PY" -c "
import sys
old = [l for l in open(sys.argv[1]) if not l.startswith(\"autoconnect\")]
new = [l for l in open(sys.argv[2]) if not l.startswith(\"autoconnect\")]
assert new[:len(old)] == old and new[len(old):len(old) + 2] == [\"\n\", \"[account:cpbee]\n\"], new
" "$SANDBOX/before.conf" "$TC"'
check "  password in ~/.netrc, owner only" 'grep -qx "machine cpbee login chris-pollitt password pw1" "$H/.netrc" && private "$H/.netrc"'
check "  backed up" 'ls "$TC".bak.* >/dev/null 2>&1'
nbak=$(ls "$TC".bak.* | wc -l)
tv --nick chris-pollitt --autoconnect > "$OUT" 2>&1
check "second run: unchanged, no new backup" '[ $? = 0 ] && has "$OUT" "unchanged in" && [ "$(ls "$TC".bak.* | wc -l)" = "$nbak" ]'
check "  one section, one netrc line, autoconnect once" '[ "$(grep -c "^\[account:cpbee\]" "$TC")" = 1 ] && [ "$(grep -c "machine cpbee" "$H/.netrc")" = 1 ] && grep -qx "autoconnect = libera, cpbee" "$TC"'
tv --nick chris-pollitt --channels '#a,#b' > "$OUT" 2>&1
check "a changed option replaces the section" '[ $? = 0 ] && has "$OUT" "replaced in" && grep -qx "channels = #a,#b" "$TC" && [ "$(grep -c "^\[account:cpbee\]" "$TC")" = 1 ]'
tv --nick someoneelse > "$OUT" 2>&1
check "~/.netrc for another login: refused" '[ $? != 0 ] && has "$OUT" "for login chris-pollitt, not someoneelse"'
check "  before tvchat.conf is touched" 'grep -qx "nick     = chris-pollitt" "$TC"'
tv --nick x --no-sasl --account lan2 --host other.lan > "$OUT" 2>&1
check "--no-sasl: no sasl line" '[ $? = 0 ] && "$PY" -c "
import configparser, sys
c = configparser.ConfigParser(interpolation=None); c.read(sys.argv[1])
sys.exit(\"sasl\" in c[\"account:lan2\"])" "$TC"'
check "  display NAME (HOST) when they differ" 'grep -qx "display  = lan2 (other.lan)" "$TC"'
tv --nick x --channels '#a #b' --no-sasl > "$OUT" 2>&1
check "a value with \" #\" is refused" '[ $? != 0 ] && has "$OUT" "no newlines"'
HOME="$H" "$V" > "$OUT" 2>&1
check "--nick is required" '[ $? != 0 ] && has "$OUT" "--nick is required"'
rm -rf "$H"; mkdir -p "$H"
CHAT_SETUP_PASS=pw tv --nick n1 > "$OUT" 2>&1
check "no tvchat.conf yet: created, owner only" '[ $? = 0 ] && has "$OUT" "created" && private "$TC"'
# the password as tvchat will find it: the backend's own lookup
cat > "$SANDBOX/new-backend" <<'EOF2'
def find_password_where(account, host, login, scheme):
    return ("t", "~/.mu-tickets") if (account, host, login) == ("cpbee", "cpbee", "n1") else (None, None)
EOF2
printf 'def find_password(*a):
    return "mailpw"
' > "$SANDBOX/old-backend"
TVB="$SANDBOX/new-backend" tv --nick n1 > "$OUT" 2>&1
check "the backend's lookup is the one asked" '[ $? = 0 ] && has "$OUT" "tvchat will use the one in ~/.mu-tickets" && ! has "$OUT" "WARN"'
TVB="$SANDBOX/old-backend" tv --nick n1 > "$OUT" 2>&1
check "an old backend: a warning, ~/.netrc used" '[ $? = 0 ] && has "$OUT" "predates bug #46" && has "$OUT" "tvchat will use the one in ~/.netrc"'
TVB="$SANDBOX/new-backend" CHAT_SETUP_PASS=pw2 tv --nick n2 --host n2.lan > "$OUT" 2>&1
check "  the backend does not find a password just added: an error" '[ $? != 0 ] && has "$OUT" "does not find the password just added"'
# the old ~/.config/tvmail/tvchat.conf (chat was part of tvmail): copied, then edited
rm -rf "$H"; mkdir -p "$H/.config/tvmail"
OLD="$H/.config/tvmail/tvchat.conf"
printf '%s\n' '[account:libera]' 'protocol = irc' 'host     = irc.libera.chat' 'realname = Old Name' > "$OLD"
cp "$OLD" "$SANDBOX/old.conf"
tv --nick n3 --no-sasl > "$OUT" 2>&1
check "an old tvmail tvchat.conf: copied to ~/.config/tvchat" '[ $? = 0 ] && has "$OUT" "copied to $TC" && has "$TC" "[account:libera]" && has "$TC" "[account:cpbee]"'
check "  realname from it, the old file untouched" 'grep -qx "realname = Old Name" "$TC" && cmp -s "$OLD" "$SANDBOX/old.conf"'
check "  the CA in ~/.config/tvchat" 'grep -qx "cafile   = $H/.config/tvchat/cpbee-ca.pem" "$TC"'
tv --nick n3 --no-sasl > "$OUT" 2>&1
check "  not copied again" '[ $? = 0 ] && ! has "$OUT" "copied to" && has "$OUT" "unchanged in"'

echo
echo "chat-setup tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
