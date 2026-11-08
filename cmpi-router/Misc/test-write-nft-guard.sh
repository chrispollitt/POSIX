#!/usr/bin/env bash
# Offline test of cmpi-router setup-router.sh's write_nft guard: its functions
# lifted out of the script, nft stubbed, files in a sandbox.
set -uo pipefail
R=$1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "  ok    $1"; else FAIL=$((FAIL+1)); echo "  FAIL  $1"; fi; }

# the functions, and the settings write_nft reads
eval "$(sed -n '/^bk(){/p' "$R")"
eval "$(sed -n '/^check_ssh_from(){/,/^}/p; /^nft_input_ports(){/,/^}/p; /^nft_lost_ports(){/,/^}/p' "$R")"
# write_nft holds a heredoc with lines that are just "}": up to the "}" after its mv
eval "$(awk '/^write_nft\(\)\{/ { on = 1 } on { print } on && /mv "\$new" "\$conf"/ { mv = 1 } mv && /^}$/ { exit }' "$R")"
LAN_PORTS_FILE=$T/tcp; LAN_UDP_PORTS_FILE=$T/udp; SSH_FROM_FILE=$T/ssh-from; BK=$T/bk; mkdir -p "$BK"
export NFT_CONF_FILE=$T/nftables.conf
NFT_PARSES=1
nft() {   # list ruleset: $LIVE (absent: fails, as with no ruleset); -c -f: $NFT_PARSES
  case "$1 ${2:-}" in
    "list ruleset") [ -f "$LIVE" ] && cat "$LIVE" ;;
    "-c -f") [ "$NFT_PARSES" = 1 ] ;;
  esac
}
live() {   # live RULE... -> a live ruleset whose input chain holds the base rules + RULE lines
  { printf 'table inet filter {\n\tchain input {\n\t\ttype filter hook input priority filter; policy drop;\n'
    printf '\t\tiifname "lan0" udp dport { 53, 67 } accept\n\t\tiifname "lan0" tcp dport { 22, 53 } accept\n'
    printf '\t\tiifname "lan0" tcp dport 443 accept\n'
    for r in "$@"; do printf '\t\t%s\n' "$r"; done
    printf '\t}\n}\n'; } > "$T/live"
  LIVE=$T/live
}
run() { echo "old" > "$NFT_CONF_FILE"; rm -f "$NFT_CONF_FILE.new"; ( write_nft ) > "$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
has() { grep -qF -- "$1" "$T/out"; }
printf '443  # https\n' > "$LAN_PORTS_FILE"; : > "$LAN_UDP_PORTS_FILE"

live 'iifname "lan0" tcp dport 143 accept'
run
check "a live-only tcp port: refused, named" '[ "$(rc)" = 1 ] && has "REFUSED: the new firewall would close ports that are open now: tcp 143"'
check "  the ruleset file untouched, no .new left" '[ "$(cat "$NFT_CONF_FILE")" = old ] && [ ! -e "$NFT_CONF_FILE.new" ]'
FW_FORCE=1 run
check "FW_FORCE=1: written, says what it closes" '[ "$(rc)" = 0 ] && has "FW_FORCE=1: closing tcp 143" && grep -q "flush ruleset" "$NFT_CONF_FILE"'
check "  the old one backed up" '[ -n "$(find "$BK" -name nftables.conf)" ]'
printf '143  # imap\n' >> "$LAN_PORTS_FILE"
run
check "listed in lan0-tcp-ports: written" '[ "$(rc)" = 0 ] && grep -q "tcp dport 143 accept" "$NFT_CONF_FILE" && [ ! -s "$T/out" ]'
live 'iifname "lan0" tcp dport { 21, 40000-40009 } accept comment "svc-ftp"' 'iifname "lan0" tcp dport 23 accept comment "svc-telnet"'
run
check "svc-* (setup-services.sh on/off) ignored" '[ "$(rc)" = 0 ]'
live 'iifname "lan0" udp dport 518 accept'
run
check "a live-only udp port: refused" '[ "$(rc)" = 1 ] && has "udp 518"'
printf '518  # talk\n' > "$LAN_UDP_PORTS_FILE"
run
check "listed in lan0-udp-ports: written, with the udp rule" '[ "$(rc)" = 0 ] && grep -q "udp dport 518 accept" "$NFT_CONF_FILE"'
LIVE=$T/none
run
check "nothing live (first install): written" '[ "$(rc)" = 0 ]'
NFT_PARSES=0
run
check "a ruleset that does not parse: refused, file kept" '[ "$(rc)" = 1 ] && has "does not parse" && [ "$(cat "$NFT_CONF_FILE")" = old ]'
NFT_PARSES=1
# the real ruleset shape cpbee has: every listed port present -> nothing lost
live 'iifname "lan0" tcp dport 143 accept' 'iifname "lan0" udp dport 518 accept'
run
check "cpbee-like: nothing lost, written" '[ "$(rc)" = 0 ]'
echo "guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
