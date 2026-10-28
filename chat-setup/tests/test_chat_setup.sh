#!/usr/bin/env bash
#
# test_chat_setup.sh - tests for chat-setup's scripts.
#
# Only the parts that need no root, no network and no Linux: the ircd.yaml
# made from a default.yaml, the systemd unit, the download pin, the firewall
# plan, the option checks, ergo-register.py against a fake NickServ, and
# configure-tvchat.sh's edits of a tvchat.conf and ~/.netrc (offline), and
# talkd.py's own suite (test_talkd.py: fake terminals, a fake talk client).
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
reg taken
check "nick taken (433): exit 3 - a re-run after it was registered" '[ $? = 3 ] && has "$OUT" "is not available"'
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

# --------------------------------------------------------------------------
t "configure-talkd.sh"
K="$C/scripts/configure-talkd.sh"
check "bash -n" 'bash -n "$K"'
# lan0's subnet, as `ip` would give it on cpbee
talkd() { CHAT_SETUP_LAN_CIDR=192.168.10.1/24 CHAT_SETUP_LAN_PORTS="${LP-$SANDBOX/no-list}" \
  CHAT_SETUP_LAN_UDP_PORTS="${UP-$SANDBOX/no-udp-list}" "$K" "$@"; }
talkd --print-unit > "$SANDBOX/tunit"
check "the unit: talkd.py as talkd, group tty, only CAP_NET_BIND_SERVICE" 'has "$SANDBOX/tunit" "User=talkd" && has "$SANDBOX/tunit" "SupplementaryGroups=tty" && has "$SANDBOX/tunit" "AmbientCapabilities=CAP_NET_BIND_SERVICE" && has "$SANDBOX/tunit" "CapabilityBoundingSet=CAP_NET_BIND_SERVICE" && has "$SANDBOX/tunit" "NoNewPrivileges=yes"'
check "  port 518, the relay ports, loopback + lan0's subnet only" 'has "$SANDBOX/tunit" "/opt/talkd/talkd.py --port 518 --relay-ports 5181-5188 --allow 127.0.0.0/8 --allow 192.168.10.0/24"'
talkd --relay-ports 6000-6001 --allow 10.1.2.3/8 --print-unit > "$OUT"
check "  --relay-ports, --allow (normalised)" 'has "$OUT" "--relay-ports 6000-6001 --allow 127.0.0.0/8 --allow 10.0.0.0/8"'
for bad in 80-90 6000-7000 x 6001-6000 6000- ; do
  talkd --relay-ports "$bad" --print-unit > "$OUT" 2>&1
  check "--relay-ports $bad is refused" '[ $? != 0 ] && has "$OUT" "--relay-ports"'
done
talkd --allow 0.0.0.0/0 --print-unit > "$OUT" 2>&1
check "--allow 0.0.0.0/0 is refused" '[ $? != 0 ] && has "$OUT" "would answer everyone"'
talkd --allow lan --print-unit > "$OUT" 2>&1
check "--allow junk is refused" '[ $? != 0 ] && has "$OUT" "is not an IPv4 CIDR"'
printf '%s\n' 'talk	dgram	udp	wait	nobody.tty	/usr/sbin/in.talkd	in.talkd' '#ntalk  dgram udp wait nobody.tty /x' \
  '  ntalk	dgram	udp	wait	nobody.tty	/usr/sbin/in.ntalkd	in.ntalkd' 'ftp stream tcp nowait root /x' > "$SANDBOX/inetd.conf"
talkd --print-inetd "$SANDBOX/inetd.conf" > "$OUT"
check "inetd.conf: talk and ntalk commented out, the rest kept" '[ "$(grep -c "^#chat-setup# " "$OUT")" = 2 ] && grep -qx "#ntalk  dgram udp wait nobody.tty /x" "$OUT" && grep -qx "ftp stream tcp nowait root /x" "$OUT"'

# the firewall: a box without cmpi-router's lists - the nft rules to add
TN="$SANDBOX/truleset"
sed 's/{ 143, 993, 4190 }/{ 143, 993, 4190, 5181 }/' "$NFT" > "$TN"
CHAT_SETUP_NFT_RULESET="$TN" talkd --firewall-plan > "$OUT" 2>&1
check "no lists: udp 518, tcp 518 and the relay ports as nft rules" 'grep -qx "nft add rule inet filter input iifname \"lan0\" udp dport 518 accept" "$OUT" && grep -qx "nft add rule inet filter input iifname \"lan0\" tcp dport 518 accept" "$OUT" && grep -qx "nft add rule inet filter input iifname \"lan0\" tcp dport 5188 accept" "$OUT"'
check "  (5181 is open already)" '! has "$OUT" "dport 5181 "'
sed 's/policy drop/policy accept/' "$TN" > "$TN.acc"
CHAT_SETUP_NFT_RULESET="$TN.acc" talkd --firewall-plan > "$OUT" 2>&1
check "  an accept policy: nothing to do" '[ ! -s "$OUT" ]'
# a cmpi-router box: the lists, then setup-router.sh fw
printf '443  # Apache https\n' > "$SANDBOX/t-tcp"; : > "$SANDBOX/t-udp"
printf '#!/bin/sh\n# LAN_UDP_PORTS_FILE=...\n' > "$SANDBOX/router-new"; printf '#!/bin/sh\n' > "$SANDBOX/router-old"
chmod +x "$SANDBOX/router-new" "$SANDBOX/router-old"
cp "$TN" "$SANDBOX/tnft.conf"
tplan() { LP="$SANDBOX/t-tcp" UP="$SANDBOX/t-udp" CHAT_SETUP_NFT_CONF="$SANDBOX/tnft.conf" \
  CHAT_SETUP_NFT_RULESET="$TN" CHAT_SETUP_ROUTER="$SANDBOX/$1" talkd --firewall-plan > "$OUT" 2>&1; }
tplan router-new
check "lists: udp 518 to the UDP list, tcp 518 + relay ports to the TCP list" 'has "$OUT" "add '"'"'518  # talk(1), ntalk (chat-setup talkd)'"'"' to $SANDBOX/t-udp" && has "$OUT" "add '"'"'518  # tvchat to talkd (chat-setup)'"'"' to $SANDBOX/t-tcp" && has "$OUT" "add '"'"'5188  # talkd relay (chat-setup)'"'"' to $SANDBOX/t-tcp" && has "$OUT" "then run setup-router.sh fw"'
check "  (no runtime rules, nothing refused)" '! has "$OUT" "nft add rule" && ! has "$OUT" "REFUSED"'
tplan router-old
check "a setup-router.sh without a UDP list: refused" 'has "$OUT" "REFUSED: setup-router.sh has no UDP list (lan0-udp-ports)"'
# live-only ports, TCP and UDP, would close on the reload
{ cat "$TN"; } | sed 's/{ 22, 53 } accept/{ 22, 53 } accept\n\t\tiifname "lan0" udp dport 5353 accept/' > "$TN.live"
sed '/143, 993, 4190/d' "$TN" > "$SANDBOX/tnft.conf"
LP="$SANDBOX/t-tcp" UP="$SANDBOX/t-udp" CHAT_SETUP_NFT_CONF="$SANDBOX/tnft.conf" CHAT_SETUP_NFT_RULESET="$TN.live" \
  CHAT_SETUP_ROUTER="$SANDBOX/router-new" talkd --firewall-plan > "$OUT" 2>&1
check "runtime-only tcp and udp ports: refused, naming them" 'has "$OUT" "REFUSED: that reload would close tcp 143 tcp 4190 tcp 5181 tcp 993 udp 5353"'
printf '518  # talk\n' > "$SANDBOX/t-udp"
printf '%s\n' 518 5181 5182 5183 5184 5185 5186 5187 5188 >> "$SANDBOX/t-tcp"
tplan router-new
check "everything listed: nothing to do" '[ ! -s "$OUT" ]'
# Oct 22 on cpbee: two silent stops under set -euo pipefail
# 1. no lan0-udp-ports yet (before the first --open-firewall): the would-close
#    check read the missing list and the plan died after printing half of itself
rm -f "$SANDBOX/t-udp"; printf '443  # Apache https\n' > "$SANDBOX/t-tcp"
cp "$TN" "$SANDBOX/tnft.conf"
LP="$SANDBOX/t-tcp" UP="$SANDBOX/t-udp" CHAT_SETUP_NFT_CONF="$SANDBOX/tnft.conf" CHAT_SETUP_NFT_RULESET="$TN.live" \
  CHAT_SETUP_ROUTER="$SANDBOX/router-new" talkd --firewall-plan > "$OUT" 2>&1
check "no UDP list yet: the whole plan, the would-close check included" '[ $? = 0 ] && has "$OUT" "then run setup-router.sh fw" && has "$OUT" "REFUSED: that reload would close udp 5353" && ! has "$OUT" "ERROR"'
# 2. nothing on UDP 518: the empty "who holds it" pipeline ended the install
eval "$(sed -n '/^port_holder() {/,/^}/p' "$K")"
ss() { printf '%s' "${SS_OUT:-}"; }
PORT=518
got=$(set -euo pipefail; SS_OUT="" port_holder; echo "rc=$?")
check "port_holder: nothing on 518 -> empty, and success" '[ "$got" = "rc=0" ]'
got=$(SS_OUT='UNCONN 0 0 0.0.0.0:518 0.0.0.0:* users:(("inetutils-inetd",pid=9,fd=5))' port_holder)
check "  inetd on 518 -> named" '[ "$got" = "\"inetutils-inetd\"" ]'
got=$(SS_OUT='UNCONN 0 0 0.0.0.0:518 0.0.0.0:* users:(("python3",pid=7,fd=3)) /opt/talkd/talkd.py' port_holder)
check "  our own talkd.py -> not a conflict" '[ -z "$got" ]'
unset -f ss
# any stop says where, never silently
talkd --print-inetd "$SANDBOX/no-such-inetd.conf" > "$OUT" 2>&1
check "a failure says where it stopped" '[ $? != 0 ] && has "$OUT" "ERROR: configure-talkd.sh stopped at line"'

# --------------------------------------------------------------------------
t "configure-tvchat-delta.sh"
VD="$C/scripts/configure-tvchat-delta.sh"
HD="$SANDBOX/homed"; mkdir -p "$HD"
td() { env -u TVCHAT_CONF TVCHAT_BACKEND="" HOME="$HD" "$VD" --no-check --no-install "$@"; }
td > "$OUT" 2>&1
check "no --addr: exit 1" '[ $? = 1 ] && has "$OUT" "--addr is required"'
td --addr nodomain@host > "$OUT" 2>&1
check "an address without a dotted domain is refused" '[ $? = 1 ] && has "$OUT" "needs a domain with a dot"'
td --addr a@b.c --bogus > "$OUT" 2>&1
check "unknown option: exit 2" '[ $? = 2 ]'
CHAT_SETUP_PASS=pw1 td --addr delta@cpbee.cmnet --host cpbee --self-signed --autoconnect --name "Me" > "$OUT" 2>&1
check "first run: exit 0, account created" '[ $? = 0 ] && has "$OUT" "[account:delta] created"'
DC="$HD/.config/tvchat/tvchat.conf"
check "  parses, bare login, 587, self-signed, autoconnect" '"$PY" -c "
import configparser, sys
c = configparser.ConfigParser(interpolation=None); c.read(sys.argv[1])
a = c[\"account:delta\"]
assert (a[\"protocol\"], a[\"addr\"], a[\"imap_user\"], a[\"imap_server\"], a[\"smtp_port\"], a[\"verify\"], a[\"name\"]) == (\"deltachat\", \"delta@cpbee.cmnet\", \"delta\", \"cpbee\", \"587\", \"false\", \"Me\"), dict(a)
assert c[\"chat\"][\"autoconnect\"] == \"delta\"
" "$DC"'
check "  the password went to ~/.netrc, not the conf" 'grep -qx "machine cpbee login delta password pw1" "$HD/.netrc" && ! grep -q pw1 "$DC"'
CHAT_SETUP_PASS=pw2 td --addr delta@cpbee.cmnet --host cpbee > "$OUT" 2>&1
check "second run: the password is found, not asked" '[ $? = 0 ] && has "$OUT" "tvchat will use the one in ~/.netrc"'
check "  the account is replaced, not doubled" '[ "$(grep -c "^\[account:delta\]" "$DC")" = 1 ]'

# --------------------------------------------------------------------------
t "configure-floyd.sh (the floyd.conf and the unit it would write)"
FL="$C/scripts/configure-floyd.sh"
fl() { "$FL" --tvchat-dir "$FIX" "$@"; }
check "bash -n configure-floyd.sh" 'bash -n "$FL"'
check "-h prints the usage" '"$FL" -h | grep -q "^Usage:"'
fl --print-config > "$SANDBOX/floyd.conf" 2> "$OUT"
check "--print-config: exit 0, no root needed" '[ $? = 0 ]'
FC="$SANDBOX/floyd.conf"
check "  the nick, account and admins of the defaults" 'grep -qx "\[account:cpbee\]" "$FC" && grep -qx "nick     = Floyd" "$FC" && grep -qx "sasl     = Floyd" "$FC" && grep -qx "admins   = chris" "$FC" && grep -qx "attach   = cpbee/\*" "$FC"'
check "  Claude works in the service user's home" 'grep -qx "claude_dir      = ~" "$FC"'
check "  it still parses as a tvchat.conf" '"$PY" -c "
import configparser, sys
c = configparser.ConfigParser(interpolation=None); c.read(sys.argv[1])
assert c[\"account:cpbee\"][\"protocol\"] == \"irc\" and c[\"account:floyd\"][\"protocol\"] == \"floyd\"
" "$FC"'
fl --nick Bot --account lan --admins "chris, ops" --claude-dir /srv/notes --print-config > "$FC" 2> "$OUT"
check "options: account, nick, admins, claude dir" 'grep -qx "\[account:lan\]" "$FC" && grep -qx "nick     = Bot" "$FC" && grep -qx "sasl     = Bot" "$FC" && grep -qx "admins   = chris, ops" "$FC" && grep -qx "attach   = lan/\*" "$FC" && grep -qx "claude_dir      = /srv/notes" "$FC" && ! grep -q "cpbee/" "$FC"'
fl --claude-cmd /home/floyd/.local/bin/claude --print-config | grep -qx "claude_cmd = /home/floyd/.local/bin/claude"
check "--claude-cmd: the path of his claude goes in the config" '[ $? = 0 ]'
fl --claude-cmd claude --print-config > "$OUT" 2>&1
check "--claude-cmd must be a full path" '[ $? != 0 ] && has "$OUT" "--claude-cmd"'
fl --no-clone --clone https://example.org/x.git --no-claude-install --no-login --no-install-tvchat --print-config > "$OUT" 2>&1
check "the step switches are accepted" '[ $? = 0 ]'
fl --irc-host 192.168.10.1 --print-config | grep -qx "host     = 192.168.10.1"
check "--irc-host: where he connects to Ergo" '[ $? = 0 ]'
fl --irc-host 'bad host' --print-config > "$OUT" 2>&1
check "a bad --irc-host is refused" '[ $? != 0 ] && has "$OUT" "--irc-host"'
fl --print-unit > "$SANDBOX/floyd.service" 2> "$OUT"
FU="$SANDBOX/floyd.service"
check "--print-unit: runs as the floyd user by default" '[ $? = 0 ] && grep -qx "User=floyd" "$FU"'
check "  the backend, the config and the password file" 'grep -qE "^ExecStart=.*tvchat-backend floyd-daemon --conf /etc/tvchat/floyd.conf$" "$FU" && grep -qx "EnvironmentFile=-/etc/tvchat/floyd.env" "$FU"'
fl --user fbot --service-user chris --conf-file /srv/f.conf --env-file /srv/f.env --print-unit > "$FU" 2> "$OUT"
check "  --service-user, --conf-file and --env-file" 'grep -qx "User=chris" "$FU" && grep -q "floyd-daemon --conf /srv/f.conf$" "$FU" && grep -qx "EnvironmentFile=-/srv/f.env" "$FU"'
fl --user fbot --print-unit | grep -qx "User=fbot"
check "  the service user follows --user" '[ $? = 0 ]'
"$FL" --tvchat-dir "$SANDBOX/nowhere" --print-config > "$OUT" 2>&1
check "no tvchat files: fails, says --tvchat-dir" '[ $? != 0 ] && has "$OUT" "--tvchat-dir"'
fl --admins 'a;b' --print-config > "$OUT" 2>&1
check "--admins with odd characters is refused" '[ $? != 0 ] && has "$OUT" "--admins"'
fl --nick 'bad nick' --print-config > "$OUT" 2>&1
check "a bad --nick is refused" '[ $? != 0 ] && has "$OUT" "--nick"'

# --------------------------------------------------------------------------
t "talkd"
"$PY" -m unittest discover -s "$here" -p test_talkd.py > "$OUT" 2>&1
check "talkd.py unit tests (test_talkd.py)" '[ $? = 0 ]' || sed "s/^/    /" "$OUT"

echo
echo "chat-setup tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
