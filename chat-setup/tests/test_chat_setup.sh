#!/usr/bin/env bash
#
# test_chat_setup.sh - tests for chat-setup's scripts.
#
# Only the parts that need no root, no network and no Linux: the ircd.yaml
# made from a default.yaml, the systemd unit, the download pin, the firewall
# plan, the option checks, and ergo-register.py against a fake NickServ.
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

echo
echo "chat-setup tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
