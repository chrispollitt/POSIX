#!/usr/bin/env bash
#
# test_lan_port.sh - tests for lan-port, against fixture lists and rulesets in a throwaway directory.
# Nothing outside it is touched: LAN_PORT_DIR, LAN_PORT_RULESET and LAN_PORT_ROUTER point into the sandbox,
# SUDO is empty and there is no nft.  Runs anywhere bash does (Linux, macOS, Cygwin).
#
# Exit 0 = all passed, 1 = something failed.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LP="$here/lan-port"

PASS=0; FAIL=0; CUR=""
t()    { CUR="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  ok    %s: %s\n' "$CUR" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s: %s\n' "$CUR" "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }        # check "what" 'test-expr'
has()  { grep -qF -- "$2" "$1"; }                                   # has FILE TEXT

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export SUDO=""
OUT="$SANDBOX/out"
RS="$SANDBOX/ruleset"; D="$SANDBOX/router-setup"
export LAN_PORT_DIR="$D" LAN_PORT_RULESET="$RS"
lp() { "$LP" "$@" > "$OUT" 2>&1; RC=$?; }                          # output in $OUT, status in $RC

# a fake setup-router.sh: "fw" loads every listed port into the ruleset file, as the real one would into nft
ROUTER="$SANDBOX/setup-router.sh"
cat > "$ROUTER" <<EOF
#!/bin/sh
# LAN_UDP_PORTS_FILE=...
[ "\$1" = fw ] || exit 2
echo "fw ran" >> "$SANDBOX/fw.log"
{ cat "$SANDBOX/base"; for pr in tcp udp; do
    [ -f "$D/lan0-\$pr-ports" ] || continue
    awk -v pr=\$pr '\$1 ~ /^[0-9]+\$/ { printf "\t\tiifname \"lan0\" %s dport %s accept\n", pr, \$1 }' "$D/lan0-\$pr-ports"; done
  echo "	}"; echo "}"; } > "$RS"
EOF
chmod +x "$ROUTER"; export LAN_PORT_ROUTER="$ROUTER"
cat > "$SANDBOX/base" <<'EOF'
table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept
		iifname "lan0" tcp dport { 22, 53 } accept
		iifname "lan0" udp dport { 53, 67 } accept
EOF
reset() {   # reset: lists with 443 and 25, the firewall loaded from them
  rm -rf "$D"; mkdir -p "$D"; rm -f "$SANDBOX/fw.log"
  printf '443  # Apache https\n25  # Postfix\n' > "$D/lan0-tcp-ports"
  "$ROUTER" fw
}
fws() { [ -f "$SANDBOX/fw.log" ] && wc -l < "$SANDBOX/fw.log" || echo 0; }

# --------------------------------------------------------------------------
t "specs"
reset
lp plan 99999 "x";      check "a port over 65535 is refused" '[ $RC = 1 ] && has "$OUT" "not a port"'
lp plan 0 "x";          check "port 0 is refused" '[ $RC = 1 ]'
lp plan 80/sctp "x";    check "only tcp and udp" '[ $RC = 1 ] && has "$OUT" "not a port"'
lp plan 6000-6100 "x";  check "a range of over 64 ports is refused" '[ $RC = 1 ] && has "$OUT" "at most 64"'
lp plan 6005-6001 "x";  check "a backwards range is refused" '[ $RC = 1 ]'
lp add 6697;            check "add without a comment is refused" '[ $RC = 1 ] && has "$OUT" "give a comment"'
lp;                     check "no command: the usage" '[ $RC = 0 ] && has "$OUT" "lan-port list"'
lp frob;                check "an unknown command: usage, exit 2" '[ $RC = 2 ]'

# --------------------------------------------------------------------------
t "plan on a cmpi-router box"
lp plan 6697 "Ergo IRC (chat-setup)"
check "not listed: would add it, then reload; exit 3" '[ $RC = 3 ] && has "$OUT" "would add '"'"'6697  # Ergo IRC (chat-setup)'"'"' to $D/lan0-tcp-ports" && has "$OUT" "then run setup-router.sh fw"'
check "  nothing changed" '! grep -q 6697 "$D/lan0-tcp-ports" && [ "$(fws)" = 1 ]'
lp plan 443 "x"
check "listed and open: nothing to do, exit 0" '[ $RC = 0 ] && has "$OUT" "already listed and open: 443/tcp" && ! has "$OUT" "then run"'
printf '6697  # Ergo\n' >> "$D/lan0-tcp-ports"
lp plan 6697 "x"
check "listed but not loaded yet: reload, exit 3" '[ $RC = 3 ] && has "$OUT" "listed, not open now: 6697/tcp" && has "$OUT" "then run setup-router.sh fw"'
reset
lp plan 5181-5183 "relay" 518/udp "talk"
check "a range and a second protocol: one line per port, one reload" '[ $RC = 3 ] && has "$OUT" "'"'"'5181  # relay'"'"' to $D/lan0-tcp-ports" && has "$OUT" "'"'"'5183  # relay'"'"'" && has "$OUT" "'"'"'518  # talk'"'"' to $D/lan0-udp-ports" && [ "$(grep -c "then run" "$OUT")" = 1 ]'
lp plan 443; check "plan needs no comment" '[ $RC = 0 ]'
# 143, 993 and 4190 and udp 5353 are open now but in no list: a reload would close them
sed -i 's/{ 22, 53 } accept/{ 22, 53 } accept\n\t\tiifname "lan0" tcp dport { 143, 993, 4190 } accept\n\t\tiifname "lan0" udp dport 5353 accept/' "$RS"
lp plan 6697 "Ergo"
check "open but unlisted ports: refused, naming them, exit 1" '[ $RC = 1 ] && has "$OUT" "REFUSED: that reload would close tcp/143 tcp/4190 tcp/993 udp/5353"'
lp plan 4190 "ManageSieve"
check "  a port being added is not one of them" '[ $RC = 1 ] && has "$OUT" "tcp/143 tcp/993 udp/5353" && ! has "$OUT" "tcp/4190"'
printf '143  # imap\n993  # imaps\n4190  # sieve\n' >> "$D/lan0-tcp-ports"; printf '5353  # mdns\n' > "$D/lan0-udp-ports"
lp plan 6697 "Ergo"
check "  listed: fine" '[ $RC = 3 ] && ! has "$OUT" "REFUSED"'
rm "$D/lan0-udp-ports"
lp plan 6697 "Ergo"
check "  a missing UDP list does not hide a live-only UDP port" '[ $RC = 1 ] && has "$OUT" "REFUSED: that reload would close udp/5353"'
reset
printf '#!/bin/sh\n' > "$SANDBOX/router-old"; chmod +x "$SANDBOX/router-old"
LAN_PORT_ROUTER="$SANDBOX/router-old" lp plan 518/udp "talk"
check "a setup-router.sh without a UDP list: refused" '[ $RC = 1 ] && has "$OUT" "REFUSED: setup-router.sh has no UDP list (lan0-udp-ports)"'
LAN_PORT_ROUTER="$SANDBOX/router-old" lp plan 518 "tvchat"
check "  (only for UDP)" '[ $RC = 3 ] && ! has "$OUT" "REFUSED"'
LAN_PORT_RULESET="$SANDBOX/no-such-file" lp plan 6697 "Ergo"
check "no readable ruleset: the list decides" '[ $RC = 3 ] && has "$OUT" "would add"'
LAN_PORT_RULESET="$SANDBOX/no-such-file" lp plan 443 "x"
check "  listed: nothing to do" '[ $RC = 0 ] && has "$OUT" "already listed: 443/tcp"'

# --------------------------------------------------------------------------
t "add and remove on a cmpi-router box"
reset
lp add 6697 "Ergo IRC (chat-setup)"
check "listed, reloaded, confirmed open" '[ $RC = 0 ] && grep -qx "6697  # Ergo IRC (chat-setup)" "$D/lan0-tcp-ports" && [ "$(fws)" = 2 ] && has "$OUT" "open: 6697/tcp"'
check "  the rest of the list kept" 'grep -qx "443  # Apache https" "$D/lan0-tcp-ports"'
lp add 6697 "Ergo IRC (chat-setup)"
check "again: already listed and open, no reload" '[ $RC = 0 ] && has "$OUT" "already listed and open" && [ "$(fws)" = 2 ] && [ "$(grep -c "^6697 " "$D/lan0-tcp-ports")" = 1 ]'
lp add 66 "not 6697"
check "66 is not 6697" '[ $RC = 0 ] && grep -qx "66  # not 6697" "$D/lan0-tcp-ports"'
printf '8080 # no newline at the end' >> "$D/lan0-tcp-ports"
lp add 8081 "after a list with no final newline"
check "a list without a final newline is not corrupted" '[ $RC = 0 ] && grep -qx "8080 # no newline at the end" "$D/lan0-tcp-ports" && grep -qx "8081  # after a list with no final newline" "$D/lan0-tcp-ports"'
reset
lp add 518/udp "talk" 518 "tvchat" 5181-5183 "relay"
check "several at once: all listed (udp list made), reloaded once" '[ $RC = 0 ] && grep -qx "518  # talk" "$D/lan0-udp-ports" && grep -qx "518  # tvchat" "$D/lan0-tcp-ports" && grep -qx "5183  # relay" "$D/lan0-tcp-ports" && [ "$(fws)" = 2 ] && has "$OUT" "open: 518/udp 518/tcp 5181/tcp 5182/tcp 5183/tcp"'
reset
printf '#!/bin/sh\nexit 0\n# LAN_UDP_PORTS_FILE\n' > "$SANDBOX/router-noop"; chmod +x "$SANDBOX/router-noop"
LAN_PORT_ROUTER="$SANDBOX/router-noop" lp add 6697 "Ergo"
check "a reload that does not open it: fails" '[ $RC = 1 ] && has "$OUT" "listed but not open"'
reset
sed -i 's/{ 22, 53 } accept/{ 22, 53 } accept\n\t\tiifname "lan0" tcp dport 4190 accept/' "$RS"
lp add 6697 "Ergo"
check "open-but-unlisted port: refused before anything is changed" '[ $RC = 1 ] && has "$OUT" "tcp/4190" && has "$OUT" "nothing was changed" && ! grep -q 6697 "$D/lan0-tcp-ports" && [ "$(fws)" = 1 ]'
reset
LAN_PORT_DRY=1 lp add 6697 "Ergo" 518/udp "talk"
check "LAN_PORT_DRY: says what it would do, does it not" '[ $RC = 0 ] && has "$OUT" "would run: append '"'"'6697  # Ergo'"'"'" && has "$OUT" "would run: $ROUTER fw" && ! grep -q 6697 "$D/lan0-tcp-ports" && [ "$(fws)" = 1 ]'
lp add 6697 "Ergo" 518/udp "talk"; lp remove 6697 518/udp 9999
check "remove: unlisted, reloaded once, others kept" '[ $RC = 0 ] && ! grep -q 6697 "$D/lan0-tcp-ports" && grep -qx "443  # Apache https" "$D/lan0-tcp-ports" && ! grep -q "^518 " "$D/lan0-udp-ports" && has "$OUT" "9999/tcp is not listed" && [ "$(fws)" = 3 ]'
lp remove 9999
check "  not listed: nothing to do, no reload" '[ $RC = 0 ] && [ "$(fws)" = 3 ]'
lp list
check "list: port/proto and the comment" '[ $RC = 0 ] && grep -qP "^25/tcp\tPostfix$" "$OUT"'

# --------------------------------------------------------------------------
t "check"
reset
lp check; check "lists and firewall agree" '[ $RC = 0 ] && has "$OUT" "lists and live firewall agree"'
sed -i 's/{ 22, 53 } accept/{ 22, 53 } accept\n\t\tiifname "lan0" tcp dport 4190 accept/' "$RS"
lp check; check "open but unlisted" '[ $RC = 1 ] && has "$OUT" "OPEN BUT UNLISTED  4190/tcp"'
reset; printf '8444  # web-ttyd\n' >> "$D/lan0-tcp-ports"
lp check; check "listed, not open" '[ $RC = 1 ] && has "$OUT" "LISTED, NOT OPEN   8444/tcp"'

# --------------------------------------------------------------------------
t "elsewhere than a cmpi-router box: runtime rules"
export LAN_PORT_DIR="$SANDBOX/no-router-dir"
cat > "$RS" <<'EOF'
table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept
		iifname "lan0" tcp dport { 22, 53 } accept
		iifname "lan0" tcp dport { 143, 993 } accept
	}
	chain output {
		type filter hook output priority filter; policy accept;
	}
}
EOF
lp plan 6697 "Ergo"
check "a drop chain without the port: the rule on lan0, exit 3" '[ $RC = 3 ] && [ "$(cat "$OUT")" = "nft add rule inet filter input iifname \"lan0\" tcp dport 6697 accept" ]'
LAN_PORT_IIF=eth1 lp plan 6697 "Ergo"
check "  LAN_PORT_IIF names the interface" 'has "$OUT" "iifname \"eth1\" tcp dport 6697"'
LAN_PORT_IIF= lp plan 6697 "Ergo"
check "  empty LAN_PORT_IIF: every interface" '[ "$(cat "$OUT")" = "nft add rule inet filter input tcp dport 6697 accept" ]'
LAN_PORT_IF=lan7 lp plan 6697 "Ergo"
check "  LAN_PORT_IF is the default interface" 'has "$OUT" "iifname \"lan7\" tcp dport 6697"'
LAN_PORT_LIKE="143 993" lp plan 4190 "ManageSieve"
check "  LAN_PORT_LIKE: where those ports are accepted (lan0 only)" '[ "$RC" = 3 ] && [ "$(cat "$OUT")" = "nft add rule inet filter input iifname \"lan0\" tcp dport 4190 accept" ]'
lp plan 518/udp "talk" 5181-5182 "relay"
check "udp and a range: a rule for each port" '[ "$(wc -l < "$OUT")" = 3 ] && has "$OUT" "udp dport 518 accept" && has "$OUT" "tcp dport 5182 accept"'
sed 's/{ 22, 53 }/{ 22, 53, 6697 }/' "$RS" > "$RS.open"
LAN_PORT_RULESET="$RS.open" lp plan 6697 "Ergo"
check "already accepted: nothing to open, exit 0" '[ $RC = 0 ] && has "$OUT" "nothing to open"'
sed 's/6697/16697/' "$RS.open" > "$RS.other"
LAN_PORT_RULESET="$RS.other" lp plan 6697 "Ergo"
check "16697 is not 6697" '[ $RC = 3 ] && has "$OUT" "tcp dport 6697 accept"'
sed 's/{ 22, 53 }/{ 22, 6690-6700 }/' "$RS" > "$RS.range"
LAN_PORT_RULESET="$RS.range" lp plan 6697 "Ergo"
check "a range that holds it counts" '[ $RC = 0 ]'
sed 's/policy drop/policy accept/' "$RS" > "$RS.accept"
LAN_PORT_RULESET="$RS.accept" lp plan 6697 "Ergo"
check "accept policy: nothing to open" '[ $RC = 0 ] && has "$OUT" "nothing to open"'
LAN_PORT_RULESET="$SANDBOX/no-such-file" lp plan 6697 "Ergo"
check "no ruleset: nothing to open" '[ $RC = 0 ] && has "$OUT" "nothing to open"'
cat > "$RS.two" <<'EOF'
table ip filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iifname "lan0" tcp dport 993 accept
    iifname "lan1" tcp dport { 143, 993 } accept
    iifname "lan0" tcp dport 143 accept
  }
}
EOF
LAN_PORT_RULESET="$RS.two" LAN_PORT_LIKE="143 993" lp plan 4190 "ManageSieve"
check "LAN_PORT_LIKE: one rule per interface, no duplicates" '[ "$(wc -l < "$OUT")" = 2 ] && has "$OUT" "iifname \"lan0\" tcp dport 4190" && has "$OUT" "iifname \"lan1\" tcp dport 4190"'
printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy drop;\n  tcp dport { 143, 993 } accept\n }\n}\n' > "$RS.bare"
LAN_PORT_RULESET="$RS.bare" LAN_PORT_LIKE="143 993" lp plan 4190 "ManageSieve"
check "LAN_PORT_LIKE without an interface in the rule: every interface" '[ "$(cat "$OUT")" = "nft add rule inet filter input tcp dport 4190 accept" ]'
printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy drop;\n  iifname "ev\\"il;x" tcp dport 993 accept\n }\n}\n' > "$RS.odd"
LAN_PORT_RULESET="$RS.odd" LAN_PORT_LIKE="143 993" lp plan 4190 "ManageSieve"
check "odd interface names are never put in a command" '! has "$OUT" "nft add rule"'
printf 'table inet filter {\n chain input {\n  type filter hook input priority 0; policy drop;\n  tcp dport { 22, 993, 4190 } accept\n }\n}\n' > "$RS.have"
LAN_PORT_RULESET="$RS.have" LAN_PORT_LIKE="143 993" lp plan 4190 "ManageSieve"
check "4190 already accepted: nothing to open" '[ $RC = 0 ]'
# add runs the rules that name an interface - here a fake nft
FAKE="$SANDBOX/fake"; mkdir -p "$FAKE"; printf '#!/bin/sh\necho "$@" >> "%s/nft.log"\n' "$SANDBOX" > "$FAKE/nft"; chmod +x "$FAKE/nft"
PATH="$FAKE:$PATH" lp add 6697 "Ergo"
check "add: runs the rule, warns that it is lost on reload" '[ $RC = 0 ] && grep -qx "add rule inet filter input iifname lan0 tcp dport 6697 accept" "$SANDBOX/nft.log" && has "$OUT" "lost when nftables reloads"'
rm -f "$SANDBOX/nft.log"
LAN_PORT_IIF= PATH="$FAKE:$PATH" lp add 6697 "Ergo"
check "add: a rule for every interface is only printed, exit 2" '[ $RC = 2 ] && [ ! -e "$SANDBOX/nft.log" ] && has "$OUT" "nft add rule inet filter input tcp dport 6697 accept"'
LAN_PORT_RUNTIME=0 PATH="$FAKE:$PATH" lp add 6697 "Ergo"
check "add with LAN_PORT_RUNTIME=0: prints the rule, runs nothing, exit 2" '[ $RC = 2 ] && [ ! -e "$SANDBOX/nft.log" ] && has "$OUT" "not a cmpi-router box"'
LAN_PORT_DRY=1 lp add 6697 "Ergo"
check "LAN_PORT_DRY: would run nft, did not" '[ $RC = 0 ] && has "$OUT" "would run: nft add rule inet filter input iifname lan0 tcp dport 6697 accept"'
lp remove 6697
check "remove: needs the lists" '[ $RC = 1 ] && has "$OUT" "not a cmpi-router box"'

echo
echo "lan-port tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
