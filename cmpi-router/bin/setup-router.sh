#!/usr/bin/env bash
# Turns a fresh Debian 13 install into a home router (IPv4 NAT, DHCP, DNS cache, nftables firewall).
#
#   sudo ./bin/setup-router.sh          install + write config (does NOT touch live networking)
#   sudo reboot                     config takes effect on reboot
#   sudo ./bin/setup-router.sh check    sanity checks after reboot
#
# Topology:   ISP/modem --> [WAN: USB ethernet = wan0]  BOX  [LAN: onboard NIC = lan0] --> switch/AP/clients
#
# Override anything via environment, e.g.  LAN_SUBNET=192.168.1 sudo -E ./bin/setup-router.sh
set -euo pipefail
ROOT="$(dirname "$(readlink -f "$0")")"; [[ -d $ROOT/traffic ]] || ROOT="$(dirname "$ROOT")"   # repo root, whether this script sits in it or in bin/

LAN_SUBNET="${LAN_SUBNET:-192.168.10}"      # /24, router is .1. Pick something different from your current router while testing.
DHCP_FROM="${DHCP_FROM:-100}"
DHCP_TO="${DHCP_TO:-250}"
LEASE="${LEASE:-12h}"
LAN_DOMAIN="${LAN_DOMAIN:-cmnet}"
LAN_IF_OVERRIDE="${LAN_IF:-}"               # current kernel name of the LAN NIC, if autodetect is wrong
WAN_IF_OVERRIDE="${WAN_IF:-}"               # current kernel name of the WAN NIC

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }

# ------------------------------------------------------------------ check mode
if [[ "${1:-}" == "check" ]]; then
  ok(){ printf '  [ ok ] %s\n' "$*"; }; bad(){ printf '  [FAIL] %s\n' "$*"; }
  for i in lan0 wan0; do ip -br addr show dev "$i" 2>&1 || bad "$i missing"; done
  [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] && ok "ip_forward on" || bad "ip_forward off"
  rules=$(nft list ruleset 2>&1 || true); routes=$(ip route show default)   # no `| grep -q`: SIGPIPE + pipefail gives false FAILs
  [[ $rules == *masquerade* ]] && ok "nftables NAT loaded" || bad "nftables NAT missing"
  systemctl is-active --quiet dnsmasq && ok "dnsmasq running" || bad "dnsmasq not running"
  [[ $routes == *wan0* ]] && ok "default route via wan0" || bad "no default route via wan0"
  wd=$(basename "$(readlink -f /sys/class/net/wan0/device/driver 2>/dev/null)" 2>/dev/null) || wd=""; wa=$(ip -4 -o addr show dev wan0 2>/dev/null | awk '{print $4}') || wa=""
  priv='^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)'   # private + carrier-grade NAT ranges
  note=""; [[ ${wa:-} =~ $priv ]] && note=" (not a public address: the upstream device does its own NAT)"
  echo "  [info] wan0 driver ${wd:-?}, address ${wa:-none}${note}"
  # ICMP to the internet is dropped by some upstreams (e.g. Android USB tethering), so fall back to a TCP check
  if ping -c2 -W2 -I wan0 1.1.1.1 >/dev/null 2>&1; then ok "internet reachable (ping 1.1.1.1)"
  elif curl -s -m 8 --interface wan0 -o /dev/null http://1.1.1.1; then ok "internet reachable (TCP to 1.1.1.1; ICMP is blocked upstream)"
  else bad "no internet via wan0 (neither ping nor TCP to 1.1.1.1)"; fi
  getent hosts debian.org >/dev/null && ok "DNS resolves" || bad "DNS failing"
  if [[ -e /etc/systemd/network/10-vr180.link ]]; then
    echo "  -- vr180 (building Wi-Fi) --"
    ip -br addr show dev vr180 2>&1 || bad "vr180 missing"
    link=$(iw dev vr180 link 2>&1 || true)
    [[ $link == Connected* ]] && ok "vr180 associated: $(grep -E 'SSID' <<<"$link" | xargs)" || bad "vr180 not associated"
    vaddr=$(ip -4 -o addr show dev vr180 | awk '{print $4}')
    [[ -n $vaddr ]] && ok "vr180 has $vaddr" || bad "vr180 has no IPv4 lease"
    [[ $routes == *vr180* ]] && bad "default route learned via vr180 (must not happen)" || ok "no default route via vr180"
    [[ -n $vaddr ]] && { ip route show dev vr180 | grep -q . && ok "subnet route via vr180: $(ip route show dev vr180 | head -1)" || bad "no subnet route via vr180"; }
    sf=$(cat /etc/router-setup/vr180-ssh-from 2>/dev/null || true)
    if [[ -n ${sf// /} ]]; then
      [[ $rules == *'iifname "vr180" ip saddr'*'tcp dport 22 accept'* ]] && ok "vr180 SSH/ping allowed from: $sf" || bad "vr180 SSH list saved ($sf) but no firewall rule loaded"
    else echo "  [info] no SSH from vr180 (emergency access: ./bin/setup-router.sh ssh <ip>...)"; fi
    gw=$(ip -4 neigh show dev vr180 | awk '{print $1; exit}')
    [[ -n $gw ]] && { ping -c2 -W2 -I vr180 "$gw" >/dev/null 2>&1 && ok "ping $gw via vr180" || bad "no reply from $gw via vr180"; }
  fi
  if [[ -e /etc/systemd/system/trafficgraph.service ]]; then
    echo "  -- traffic graphs --"
    gp=$(sed -n 's/.*TRAFFIC_PORT=\([0-9]*\).*/\1/p' /etc/systemd/system/trafficgraph.service)
    gb=$(sed -n 's/.*TRAFFIC_BIND=\([0-9.]*\).*/\1/p' /etc/systemd/system/trafficgraph.service)
    systemctl is-active --quiet trafficgraph && ok "trafficgraph running" || bad "trafficgraph not running"
    [[ $(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$gb:$gp/api/config") == 200 ]] && ok "web UI answers on $gb:$gp" || bad "web UI not answering on $gb:$gp"
    if [[ $gb == 127.* ]]; then ok "graphs backend is on loopback $gb:$gp (nginx TLS front: see setup-services.sh tls)"
    else [[ $rules == *"dport $gp accept"* ]] && ok "firewall allows $gp from lan0" || bad "no firewall rule for port $gp"; fi
    systemctl is-active --quiet trafficgraph-acct && ok "trafficgraph-acct (counter export) running" || bad "trafficgraph-acct not running"
    [[ $rules == *"table ip acct"* ]] && ok "per-device accounting rules loaded" || bad "per-device accounting rules missing"
    age=$(( $(date +%s) - $(stat -c %Y /run/trafficgraph/acct.json 2>/dev/null || echo 0) ))
    [[ $age -lt 30 ]] && ok "counter export is fresh (${age}s old)" || bad "counter export stale or missing (${age}s)"
    [[ $(curl -s -m 5 "http://$gb:$gp/api/hosts?range=1h" | grep -o '"key"' | wc -l) -gt 0 ]] && ok "per-device data present" || echo "  [info] no per-device data yet (needs LAN traffic through wan0)"
  fi
  exit 0
fi

# ------------------------------------------------------------------ find the NICs
declare -a PCI_NICS=() USB_NICS=()
for d in /sys/class/net/*; do
  n=${d##*/}; [[ $n == lo || ! -e $d/device || -d $d/wireless ]] && continue
  if [[ $(readlink -f "$d/device") == *usb* ]]; then USB_NICS+=("$n"); else PCI_NICS+=("$n"); fi
done
LAN_IF=${LAN_IF_OVERRIDE:-${PCI_NICS[0]:-}}
WAN_IF=${WAN_IF_OVERRIDE:-${USB_NICS[0]:-}}

# wan0 naming + DHCP client. $1 = MAC of the WAN NIC; empty = match any USB ethernet adapter (by bus path)
write_wan_cfg(){
  local m="Path=*-usb-*" nd="${NETWORKD_DIR:-/etc/systemd/network}"; [[ -z ${1:-} ]] || m="MACAddress=$1"
  install -d "$nd"
  cat > "$nd/10-wan0.link" <<EOF
[Match]
$m
[Link]
Name=wan0
EOF
  cat > "$nd/20-wan0.network" <<EOF
[Match]
Name=wan0
[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no
[DHCPv4]
UseDNS=yes
RouteMetric=100
EOF
}

bk(){ [[ -e $1 ]] && { cp -a --parents "$1" "$BK" 2>/dev/null || cp --parents "$1" "$BK"; }; true; }

# Firewall + NAT. The vr180 zone (Wi-Fi client of the building network) is included once `wifi` has been run.
# lan0 -> vr180 is allowed (and NATed); vr180 -> anything is dropped, so the building cannot reach the LAN.
#
# Emergency management from the building side: VR180_SSH_FROM="192.168.123.254 192.168.123.253" lets ONLY those hosts ping and SSH to
# cpbee's vr180 address. Saved in $SSH_FROM_FILE so every later run of this script keeps it; set it empty (or `ssh off`) to remove.
# Env var set (even empty) = override and save; unset = use the saved list. Entries: ipv4 or ipv4/24..32 (never the whole building).
SSH_FROM_FILE=/etc/router-setup/vr180-ssh-from
# Extra TCP ports opened to lan0 ONLY (one per line, '#' comments ok), e.g. the LibreNMS web UI written by setup-monitoring.sh.
# Kept in a file so every later run of this script keeps them (write_nft regenerates the whole ruleset).
LAN_PORTS_FILE=${LAN_PORTS_FILE:-/etc/router-setup/lan0-tcp-ports}
# The same for UDP (e.g. 518, talk(1): chat-setup's configure-talkd.sh), same format.
LAN_UDP_PORTS_FILE=${LAN_UDP_PORTS_FILE:-/etc/router-setup/lan0-udp-ports}
# UPnP / NAT-PMP for LAN clients (see `upnp` mode): the marker file makes write_nft add the chains miniupnpd fills in.
UPNP_MARK=${UPNP_MARK:-/etc/router-setup/upnp}
# Reload the saved ruleset.  `flush ruleset` also wipes the port mappings miniupnpd made, so restart it: it re-creates them from its lease file.
nft_load(){
  nft -f /etc/nftables.conf
  if systemctl is-active --quiet miniupnpd 2>/dev/null; then systemctl restart miniupnpd || echo "WARNING: miniupnpd did not restart: UPnP mappings are gone until it does" >&2; fi
}
check_ssh_from(){
  local e; for e in $1; do
    [[ $e =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/(2[4-9]|3[0-2]))?$ ]] || { echo "bad VR180_SSH_FROM entry '$e' (want ipv4 or ipv4/24..32)" >&2; return 1; }
  done
}
# Ports of PROTO that input chains accept, one per line, from an nft ruleset on stdin ("tcp dport 22 accept",
# "udp dport { 53, 67 } accept"). Rules tagged comment "svc-..." are skipped: setup-services.sh on/off keeps
# those live-only on purpose (ftp, telnet), so a reload closing them is expected.
nft_input_ports(){
  awk -v proto="$1" '
    /^[ \t]*chain / { hook = 0; next }
    /type filter hook input/ { hook = 1; next }
    hook && /comment "svc-/ { next }
    hook && $0 ~ (proto " dport") && /accept/ {
      s = $0; sub(".*" proto " dport[ \t]*", "", s)
      if (s ~ /^\{/) { sub(/^\{/, "", s); sub(/\}.*/, "", s) } else sub(/[ \t].*/, "", s)
      n = split(s, a, /[ ,\t]+/)
      for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9]+(-[0-9]+)?$/) print a[i]
    }' | sort -u
}
# Ports the LIVE firewall accepts that the ruleset in file $1 would not ("tcp 143" lines): loading it would close
# them. Those are ports opened at runtime (`nft add rule`) and listed nowhere - the Oct 2026 mail outage (143, 993,
# 4190 closed by a reload). Nothing live (first install) = nothing lost.
nft_lost_ports(){
  local live p
  live=$(nft list ruleset 2>/dev/null) || return 0
  for p in tcp udp; do
    comm -23 <(nft_input_ports "$p" <<<"$live") <(nft_input_ports "$p" < "$1") | sed "s/^/$p /"
  done
}
write_nft(){
  local vr_in="" vr_fwd="" vr_nat="" graph_in="" gport="" ssh_from="" vr_ssh="" extra_in="" xp=""
  if [[ -n ${VR180_SSH_FROM+x} ]]; then
    ssh_from=$VR180_SSH_FROM; check_ssh_from "$ssh_from" || exit 1
    install -d -m 755 "${SSH_FROM_FILE%/*}"; printf '%s\n' "$ssh_from" > "$SSH_FROM_FILE"
  else
    ssh_from=$(cat "$SSH_FROM_FILE" 2>/dev/null || true)
  fi
  # traffic graphs web UI (see `graphs` mode): open its port to lan0 only
  # (not when the service sits on loopback behind the nginx TLS front: that front's ports come from $LAN_PORTS_FILE, see setup-services.sh tls)
  gport=$(sed -n 's/.*TRAFFIC_PORT=\([0-9]*\).*/\1/p' /etc/systemd/system/trafficgraph.service 2>/dev/null || true)
  gbind=$(sed -n 's/.*TRAFFIC_BIND=\([0-9.]*\).*/\1/p' /etc/systemd/system/trafficgraph.service 2>/dev/null || true)
  [[ -z $gport || $gbind == 127.* ]] || graph_in="    iifname \"lan0\" tcp dport $gport accept"
  if [[ -r $LAN_PORTS_FILE ]]; then
    while read -r xp _; do
      if [[ $xp =~ ^[0-9]+$ ]] && (( xp >= 1 && xp <= 65535 )); then extra_in+=$'
'"    iifname \"lan0\" tcp dport $xp accept"; fi
    done < "$LAN_PORTS_FILE"
  fi
  if [[ -r $LAN_UDP_PORTS_FILE ]]; then
    while read -r xp _; do
      if [[ $xp =~ ^[0-9]+$ ]] && (( xp >= 1 && xp <= 65535 )); then extra_in+=$'
'"    iifname \"lan0\" udp dport $xp accept"; fi
    done < "$LAN_UDP_PORTS_FILE"
  fi
  if [[ -e /etc/systemd/network/10-vr180.link ]]; then
    vr_in='    iifname "vr180" udp sport 67 udp dport 68 accept'
    vr_fwd='    iifname "lan0" oifname "vr180" accept'
    vr_nat='    oifname "vr180" masquerade'
    if [[ -n ${ssh_from// /} ]]; then
      local -a sf; read -ra sf <<<"$ssh_from"; vr_ssh=$(IFS=,; echo "${sf[*]}"); vr_ssh=${vr_ssh//,/, }
      vr_in+=$'\n'"    # emergency access from named building-side hosts only (VR180_SSH_FROM)"
      vr_in+=$'\n'"    iifname \"vr180\" ip saddr { $vr_ssh } tcp dport 22 accept"
      vr_in+=$'\n'"    iifname \"vr180\" ip saddr { $vr_ssh } icmp type echo-request accept"
    fi
  fi
  # VAX zone (written by setup-vax.sh): a routed tap, reachable from lan0 and allowed to answer/ask the LAN, never to the internet
  local vx_in="" vx_fwd=""
  if [[ -e /etc/router-setup/vax-zone ]]; then
    vx_in=$'    iifname "vaxtap" ip protocol icmp accept\n    iifname "vaxtap" udp dport 53 accept\n    iifname "vaxtap" tcp dport 53 accept'
    # talk(1) from the VAX (chat-setup talkd): ntalk on UDP 518; the relay ports; and the caller's own TCP listener
    # (talk binds an ephemeral port; the callee - here the VAX - connects to it, and nothing helps conntrack see that coming)
    vx_in+=$'\n    iifname "vaxtap" udp dport 518 accept\n    iifname "vaxtap" tcp dport 5181-5188 accept\n    iifname "vaxtap" tcp dport 32768-60999 accept'
    vx_fwd=$'    iifname "lan0" oifname "vaxtap" accept\n    iifname "vaxtap" oifname "lan0" accept'
  fi
  # UPnP: miniupnpd (listening on lan0 only) adds its port mappings to these chains: a forward accept and a DNAT per mapping.
  # The input rules for it (SSDP, its HTTP port) are in the lan0 port lists, not here.
  local up_fwd="" up_chains="" up_in=""
  if [[ -e $UPNP_MARK ]]; then
    up_fwd=$'    iifname "wan0" oifname "lan0" ct status dnat jump miniupnpd'
    # cpbee finds the upstream router's UPnP by multicast search; the answer comes from the router's own address, which conntrack
    # does not match to the search, so allow SSDP answers (source port 1900) from private addresses to unprivileged ports on wan0
    up_in=$'    iifname "wan0" ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } udp sport 1900 udp dport 32768-60999 accept'
    up_chains=$'  chain miniupnpd { }\n  chain prerouting_miniupnpd { }\n  chain postrouting_miniupnpd { }\n  chain upnp_prerouting  { type nat hook prerouting priority dstnat; policy accept; iifname "wan0" jump prerouting_miniupnpd; }\n  chain upnp_postrouting { type nat hook postrouting priority srcnat; policy accept; oifname "lan0" jump postrouting_miniupnpd; }'
  fi
  local conf=${NFT_CONF_FILE:-/etc/nftables.conf} new lost
  new=$conf.new
  cat > "$new" <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;
    ct state invalid drop
    ct state established,related accept
    iifname "lo" accept
    # LAN may talk to the router: ping, DNS, DHCP, SSH
    iifname "lan0" ip protocol icmp accept
    iifname "lan0" meta l4proto ipv6-icmp accept
    iifname "lan0" udp dport { 53, 67 } accept
    iifname "lan0" tcp dport { 22, 53 } accept
$graph_in$extra_in
    # WAN: only DHCP replies and rate-limited ping
    iifname "wan0" udp sport 67 udp dport 68 accept
    iifname "wan0" icmp type echo-request limit rate 5/second accept
$up_in
$vr_in
$vx_in
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
    ct state invalid drop
    ct state established,related accept
$up_fwd
    oifname "wan0" tcp flags syn tcp option maxseg size set rt mtu
    iifname "lan0" oifname "wan0" accept
$vr_fwd
$vx_fwd
    # port forward example (also add a dnat rule in table ip nat):
    # iifname "wan0" oifname "lan0" ip daddr 192.168.10.20 tcp dport 443 ct status dnat accept
  }
  chain output { type filter hook output priority filter; policy accept; }
$up_chains
}

table ip nat {
  chain prerouting  { type nat hook prerouting priority dstnat; policy accept;
    # iifname "wan0" tcp dport 443 dnat to 192.168.10.20:443
  }
  chain postrouting { type nat hook postrouting priority srcnat; policy accept;
    oifname "wan0" masquerade
$vr_nat
  }
}

# Per-device accounting of the metered link (WAN only). Runs after the filter chains (priority +10), so it only sees
# packets that were actually allowed. Byte counters live in the sets/counters; trafficgraph-acct exports them (see \`graphs\`).
#   up   = bytes a LAN client sent to the internet      (keyed by the client's source address, before NAT)
#   down = bytes a LAN client received from the internet (keyed by the client's destination address, after un-NAT)
#   router_* = bytes cpbee itself sent/received on wan0 (mail, apt, DNS lookups on behalf of clients, ...)
table ip acct {
  set up   { type ipv4_addr; size 2048; flags dynamic; counter; }
  set down { type ipv4_addr; size 2048; flags dynamic; counter; }
  counter router_up { }
  counter router_down { }
  chain acct_fwd {
    type filter hook forward priority filter + 10; policy accept;
    iifname "lan0" oifname "wan0" update @up { ip saddr }
    iifname "wan0" oifname "lan0" update @down { ip daddr }
  }
  chain acct_out { type filter hook output priority filter + 10; policy accept; oifname "wan0" counter name "router_up"; }
  chain acct_in { type filter hook input priority filter + 10; policy accept; iifname "wan0" counter name "router_down"; }
}
EOF
  nft -c -f "$new" || { echo "the new ruleset does not parse - kept $conf, the new one is $new" >&2; exit 1; }  # check only, no load
  lost=$(nft_lost_ports "$new" | xargs)
  if [[ -n $lost && ${FW_FORCE:-0} != 1 ]]; then
    rm -f "$new"
    cat >&2 <<EOF2
REFUSED: the new firewall would close ports that are open now: $lost
  They are open only by live rules (nft add rule ...), in neither the ruleset nor
  $LAN_PORTS_FILE / $LAN_UDP_PORTS_FILE.
  To keep one: add "PORT  # what it is" to the list for its protocol, then re-run.
  To close them on purpose: re-run with FW_FORCE=1.  Nothing was changed.
EOF2
    exit 1
  fi
  [[ -z $lost ]] || echo "FW_FORCE=1: closing $lost" >&2
  bk "$conf"
  mv "$new" "$conf"
}

# ------------------------------------------------------------------ wifi mode: join the building Wi-Fi (VR180) on the onboard Intel card
# Replaces the Pi's bridge-cmpi.sh: NAT out the Wi-Fi link, NO default route from it, route to its subnet only.
#   sudo ./bin/setup-router.sh wifi            (optional: WIFI_SSID=... WIFI_COUNTRY=.. WIFI_IF=wlp2s0)
if [[ "${1:-}" == "wifi" ]]; then
  WIFI_SSID="${WIFI_SSID:-VR180}"
  WIFI_COUNTRY="${WIFI_COUNTRY:-CA}"          # regulatory domain; set it to where the box actually is
  WIFI_IF="${WIFI_IF:-}"
  if [[ -z $WIFI_IF ]]; then
    for d in /sys/class/net/*; do if [[ -d $d/wireless ]]; then WIFI_IF=${d##*/}; break; fi; done
  fi
  [[ -n $WIFI_IF ]] || { echo "No Wi-Fi interface found (is firmware-iwlwifi installed and rfkill off?)"; exit 1; }
  WIFI_MAC=$(< /sys/class/net/$WIFI_IF/address)
  BK=${BACKUP_ROOT:-/root}/router-setup-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
  export DEBIAN_FRONTEND=noninteractive
  # packages use the current network (wan0 via the phone/upstream)
  apt-get update
  apt-get install -y wpasupplicant iw rfkill
  systemctl disable --now wpa_supplicant.service 2>/dev/null || true   # generic dbus instance; we use a per-interface unit
  rfkill unblock wifi || true
  iw reg set "$WIFI_COUNTRY" || true

  echo "Scanning for $WIFI_SSID on $WIFI_IF ..."
  ip link set "$WIFI_IF" up
  sleep 2
  scan=$(iw dev "$WIFI_IF" scan 2>&1 || true)
  # one block per BSS; keep the ones for our SSID
  hits=$(awk -v s="$WIFI_SSID" 'BEGIN{RS="\nBSS "; ORS="\n--\n"} $0 ~ "SSID: "s"(\n|$)" {print}' <<<"$scan")
  if [[ -z $hits ]]; then
    echo "SSID '$WIFI_SSID' not seen. Visible networks:"; grep -E '^\s*SSID: .' <<<"$scan" | sort -u | head -20
    echo "(If the list is empty the card/firmware may not be working: check 'journalctl -k | grep -i iwlwifi'.)"
    exit 1
  fi
  echo "Found $WIFI_SSID:"; grep -E 'freq:|signal:|RSN:|WPA:|Authentication suites|Pairwise|SAE|PSK|802.1X|Privacy' <<<"$hits" | sort | uniq -c | head -20

  if grep -qE '(^|[^-])(RSN|WPA):' <<<"$hits"; then
    if grep -q '802.1X' <<<"$hits" && ! grep -qE 'PSK|SAE' <<<"$hits"; then
      echo "$WIFI_SSID uses WPA-Enterprise (802.1X); this script only does a passphrase network. Aborting."; exit 1
    fi
    read -rsp "Passphrase for $WIFI_SSID (not echoed, stored only in a root-only file on this box): " psk; echo
    [[ -n $psk ]] || { echo "empty passphrase"; exit 1; }
    sec="  key_mgmt=WPA-PSK WPA-PSK-SHA256 SAE
  ieee80211w=1
  psk=\"$psk\""
  else
    echo "WARNING: $WIFI_SSID is OPEN. If it has a captive portal / MAC registration, this will associate but have no connectivity."
    sec="  key_mgmt=NONE"
  fi

  bk /etc/wpa_supplicant/wpa_supplicant-vr180.conf
  install -d -m 755 /etc/wpa_supplicant
  ( umask 077; cat > /etc/wpa_supplicant/wpa_supplicant-vr180.conf <<EOF
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=0
country=$WIFI_COUNTRY
network={
  ssid="$WIFI_SSID"
  scan_ssid=1
$sec
}
EOF
  )
  chmod 600 /etc/wpa_supplicant/wpa_supplicant-vr180.conf; chown root:root /etc/wpa_supplicant/wpa_supplicant-vr180.conf
  unset psk sec

  cat > /etc/systemd/network/10-vr180.link <<EOF
[Match]
MACAddress=$WIFI_MAC
[Link]
Name=vr180
EOF
  cat > /etc/systemd/network/20-vr180.network <<EOF
[Match]
Name=vr180
[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no
[DHCPv4]
UseGateway=no
UseDNS=no
UseNTP=no
UseDomains=no
UseRoutes=no
EOF
  write_nft
  systemctl enable nftables "wpa_supplicant@vr180.service"

  # apply live: rename (needs the link down), start supplicant, let networkd pick it up, reload firewall
  ip link set "$WIFI_IF" down || true
  [[ $WIFI_IF == vr180 ]] || ip link set "$WIFI_IF" name vr180
  networkctl reload || true
  systemctl restart "wpa_supplicant@vr180.service"
  nft_load
  echo "Waiting for association + DHCP ..."
  for _ in $(seq 20); do ip -4 addr show dev vr180 2>/dev/null | grep -q 'inet ' && break; sleep 1; done
  iw dev vr180 link || true
  ip -br addr show vr180; ip route
  echo; echo "Now run: sudo ./bin/setup-router.sh check   (backups in $BK)"
  exit 0
fi

# ------------------------------------------------------------------ leases mode: fixed addresses + names for the wired machines
#   sudo ./bin/setup-router.sh leases [file]        default file: ./middle/devices.txt, one device per line:   name  mac  ip   (# = comment)
# Writes /etc/dnsmasq.d/leases.conf (dhcp-host lines). dnsmasq then hands each machine its fixed address and publishes its name
# (name and name.lan); the graphs page also uses these names. Fixed addresses must be in the LAN subnet and outside the dynamic
# pool, so they can never clash with a dynamically assigned one. Safe to run any time and to re-run after editing the file.
if [[ "${1:-}" == "leases" ]]; then
  src="${2:-$ROOT/middle/devices.txt}"
  dm="${DNSMASQ_D:-/etc/dnsmasq.d}"
  conf="$dm/lan.conf"
  [[ -f $src ]] || { echo "device list not found: $src"; exit 1; }
  [[ -f $conf ]] || { echo "$conf missing: run the full setup first"; exit 1; }
  lanip=$(sed -n 's/^dhcp-option=option:router,//p' "$conf" | head -1); prefix=${lanip%.*}
  pool_from=$(sed -n 's/^dhcp-range=[0-9.]*\.\([0-9]*\),.*/\1/p' "$conf" | head -1)
  pool_to=$(sed -n 's/^dhcp-range=[0-9.]*\.[0-9]*,[0-9.]*\.\([0-9]*\),.*/\1/p' "$conf" | head -1)
  [[ -n $lanip && -n $pool_from && -n $pool_to ]] || { echo "cannot read the LAN address/pool from $conf"; exit 1; }
  declare -A seen=(); out=(); n=0
  while read -r name mac ip _; do
    n=$((n+1)); [[ -z ${name:-} || $name == \#* ]] && continue
    mac=${mac,,}
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { echo "line $n: bad name '$name'"; exit 1; }
    [[ $mac =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || { echo "line $n ($name): bad MAC '$mac'"; exit 1; }
    [[ $ip =~ ^${prefix//./\\.}\.([0-9]{1,3})$ ]] || { echo "line $n ($name): $ip is not in ${prefix}.0/24"; exit 1; }
    last=${BASH_REMATCH[1]}
    (( last >= 2 && last <= 254 )) || { echo "line $n ($name): bad address $ip"; exit 1; }
    [[ $ip != "$lanip" ]] || { echo "line $n ($name): $ip is the router itself"; exit 1; }
    if (( last >= pool_from && last <= pool_to )); then echo "line $n ($name): $ip is inside the dynamic pool ${prefix}.${pool_from}-${pool_to}; pick one outside it"; exit 1; fi
    for k in "name:${name,,}" "mac:$mac" "ip:$ip"; do
      [[ -z ${seen[$k]:-} ]] || { echo "line $n ($name): duplicate ${k%%:*} (${k#*:}) also on line ${seen[$k]}"; exit 1; }
      seen[$k]=$n
    done
    out+=("dhcp-host=$mac,$name,$ip")
  done < "$src"
  [[ ${#out[@]} -gt 0 ]] || { echo "no devices in $src"; exit 1; }
  BK=${BACKUP_ROOT:-/root}/router-setup-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
  bk "$dm/leases.conf"
  printf '# written by setup-router.sh leases from %s\n%s\n' "$src" "$(printf '%s\n' "${out[@]}")" > "$dm/leases.conf"
  dnsmasq_bin=$(command -v dnsmasq || echo /usr/sbin/dnsmasq)
  if ! "$dnsmasq_bin" --test --conf-file="$dm/leases.conf" >/dev/null 2>&1; then
    echo "dnsmasq rejected the lease file; restoring"; rm -f "$dm/leases.conf"; [[ -e $BK$dm/leases.conf ]] && cp -a "$BK$dm/leases.conf" "$dm/"; exit 1
  fi
  [[ -n ${LEASES_NO_RESTART:-} ]] || { systemctl restart dnsmasq && sleep 1 && systemctl is-active --quiet dnsmasq || { echo "dnsmasq FAILED to restart"; exit 1; }; }
  echo "Static leases installed (${#out[@]}):"; sed 's/^dhcp-host=/  /; s/,/  /g' "$dm/leases.conf" | tail -n +2
  echo "Each machine gets its fixed address when it next renews or reconnects; names resolve as <name> and <name>.${LAN_DOMAIN}."
  exit 0
fi

# ------------------------------------------------------------------ plan mode: data plan meter, pacing and alerts
#   sudo ./bin/setup-router.sh plan --gb 199.76 --day 11 --used 14.87 --email you@example.com
#   sudo ./bin/setup-router.sh plan --show          (options: see traffic/plan.py --help)
# Writes /etc/trafficgraph/config.json; the running graphs service applies it within seconds (no restart).
# Test the alert channels (email relay / webhook):  sudo ./bin/setup-router.sh plan --test-alert
if [[ "${1:-}" == "plan" ]]; then
  shift
  planpy="$ROOT/traffic/plan.py"
  [[ -f $planpy ]] || { echo "missing $planpy"; exit 1; }
  [[ -d /etc/trafficgraph ]] || { echo "run './bin/setup-router.sh graphs' first"; exit 1; }
  if [[ "${1:-}" == "--test-alert" ]]; then       # send a test through the configured channels, as the service user would
    [[ -f /opt/trafficgraph/server.py ]] || { echo "run './bin/setup-router.sh graphs' first"; exit 1; }
    exec runuser -u trafficgraph -- env TRAFFIC_CONFIG=/etc/trafficgraph/config.json TRAFFIC_STATE=/tmp /usr/bin/python3 /opt/trafficgraph/server.py --test-alert
  fi
  exec python3 "$planpy" "$@"
fi

# ------------------------------------------------------------------ graphs mode: traffic graphing web UI (in/out per interface)
# Installs ./traffic/{server.py,index.html} as the `trafficgraph` systemd service (stdlib Python, no packages, no internet needed).
# Listens on the lan0 address only, port 80 by default (GRAPH_PORT=8080 to change); the firewall opens it to lan0 only.
# After `setup-services.sh tls` it listens on loopback only and nginx serves it over https (bind/port/URL come from /etc/router-setup/graphs-backend).
# Data plan meter, pacing and alerts: `sudo ./bin/setup-router.sh plan ...` (see above).
if [[ "${1:-}" == "graphs" ]]; then
  # /etc/router-setup/graphs-backend ("127.0.0.1 8081") is written by `setup-services.sh tls`: the service then hides behind nginx, so a re-run keeps it there
  gb_saved=$(cat /etc/router-setup/graphs-backend 2>/dev/null || true)
  GRAPH_PORT="${GRAPH_PORT:-$(awk '{print $2}' <<<"$gb_saved")}"; GRAPH_PORT="${GRAPH_PORT:-80}"      # file = "<bind> <port> <url>"
  GRAPH_BIND="${GRAPH_BIND:-$(awk '{print $1}' <<<"$gb_saved")}"
  GRAPH_URL="${GRAPH_URL:-$(awk '{print $3}' <<<"$gb_saved")}"      # link put into alert mails when behind the TLS front
  src="$ROOT/traffic"
  [[ -f $src/server.py && -f $src/index.html && -f $src/router.py && -f $src/router.html && -f $src/phone.py && -f $src/acct-export.py ]] || { echo "missing $src/server.py, index.html, router.py, router.html, phone.py or acct-export.py"; exit 1; }
  conf=/etc/dnsmasq.d/lan.conf
  lanip=$(sed -n 's/^dhcp-option=option:router,//p' "$conf" 2>/dev/null | head -1)
  [[ -n $lanip ]] || { echo "cannot find the LAN address in $conf: run the full setup first"; exit 1; }
  [[ $GRAPH_PORT =~ ^[0-9]+$ ]] || { echo "bad GRAPH_PORT"; exit 1; }
  GRAPH_BIND="${GRAPH_BIND:-$lanip}"
  BK=${BACKUP_ROOT:-/root}/router-setup-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
  command -v python3 >/dev/null || apt-get install -y python3
  id trafficgraph >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin trafficgraph
  install -d -m 755 /opt/trafficgraph /etc/trafficgraph
  install -m 644 "$src/server.py" "$src/index.html" "$src/router.py" "$src/router.html" "$src/phone.py" /opt/trafficgraph/
  install -m 755 "$src/acct-export.py" /opt/trafficgraph/        # root helper: only it may read the nftables counters
  if [[ ! -e /etc/trafficgraph/config.json ]]; then
    printf '{\n  "monthly_cap_gb": null,\n  "cap_iface": "wan0",\n  "billing_day": 1\n}\n' > /etc/trafficgraph/config.json
  fi
  bk /etc/systemd/system/trafficgraph.service
  cat > /etc/systemd/system/trafficgraph.service <<EOF
[Unit]
Description=cpbee traffic graphs (web UI on the LAN)
After=network.target trafficgraph-acct.service
Wants=trafficgraph-acct.service

[Service]
User=trafficgraph
Group=trafficgraph
Environment=TRAFFIC_BIND=$GRAPH_BIND TRAFFIC_PORT=$GRAPH_PORT TRAFFIC_STATE=/var/lib/trafficgraph TRAFFIC_CONFIG=/etc/trafficgraph/config.json${GRAPH_URL:+ TRAFFIC_URL=$GRAPH_URL}
ExecStart=/usr/bin/python3 /opt/trafficgraph/server.py
StateDirectory=trafficgraph
Restart=on-failure
RestartSec=3
TimeoutStopSec=10
# reads /proc/net/dev and binds one port; the Router page also runs read-only ip, iw and ping (AF_NETLINK is for read-only queries:
# with no capabilities the service cannot change any network setting)
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target
EOF
  # the only privileged piece: exports the per-device nftables byte counters (table ip acct) to /run/trafficgraph/acct.json
  bk /etc/systemd/system/trafficgraph-acct.service
  cat > /etc/systemd/system/trafficgraph-acct.service <<EOF
[Unit]
Description=cpbee traffic graphs: export per-device nftables counters
After=nftables.service
Wants=nftables.service

[Service]
ExecStart=/usr/bin/python3 /opt/trafficgraph/acct-export.py
RuntimeDirectory=trafficgraph
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
Restart=on-failure
RestartSec=5
# runs as root only to read nftables (netlink); nothing else is allowed
CapabilityBoundingSet=CAP_NET_ADMIN
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_NETLINK AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
IPAddressDeny=any

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  write_nft                                   # now includes the lan0-only rule for the port and the per-device accounting table
  nft_load
  systemctl enable trafficgraph-acct.service trafficgraph.service
  systemctl restart trafficgraph-acct.service trafficgraph.service
  sleep 4
  systemctl is-active --quiet trafficgraph-acct && echo "trafficgraph-acct running" || { echo "trafficgraph-acct FAILED:"; journalctl -u trafficgraph-acct -n 20 --no-pager; exit 1; }
  [[ -s /run/trafficgraph/acct.json ]] && echo "per-device counters exported: $(head -c 200 /run/trafficgraph/acct.json)" || echo "WARNING: /run/trafficgraph/acct.json not written yet"
  systemctl is-active --quiet trafficgraph && echo "trafficgraph running" || { echo "trafficgraph FAILED:"; journalctl -u trafficgraph -n 20 --no-pager; exit 1; }
  curl -s -m 5 -o /dev/null -w "GET http://$GRAPH_BIND:$GRAPH_PORT/ -> %{http_code}\n" "http://$GRAPH_BIND:$GRAPH_PORT/" || true
  if [[ $GRAPH_BIND == 127.* ]]; then echo "Backend on loopback; open it through the TLS front: ${GRAPH_URL:-see setup-services.sh tls}   Backups in $BK"
  else echo "Open from a LAN machine:  http://$lanip:$GRAPH_PORT/   (or http://$(hostname).${LAN_DOMAIN}:$GRAPH_PORT/)  Backups in $BK"; fi
  echo "Data plan meter, pacing and alerts:  sudo ./bin/setup-router.sh plan --gb <allowance> --day <cycle start day> [--used <carrier GB>] [--email you@example.com]"
  exit 0
fi

# ------------------------------------------------------------------ fw mode: regenerate and load the firewall (picks up $LAN_PORTS_FILE, $LAN_UDP_PORTS_FILE, the graphs port, the SSH list)
#   sudo ./bin/setup-router.sh fw
if [[ "${1:-}" == "fw" ]]; then
  BK=${BACKUP_ROOT:-/root}/router-setup-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
  write_nft
  nft_load
  echo "Firewall reloaded (backup in $BK). Extra lan0 TCP ports: $(grep -Eo '^[[:space:]]*[0-9]+' "$LAN_PORTS_FILE" 2>/dev/null | xargs || true); UDP: $(grep -Eo '^[[:space:]]*[0-9]+' "$LAN_UDP_PORTS_FILE" 2>/dev/null | xargs || true)"
  exit 0
fi

# ------------------------------------------------------------------ ssh mode: emergency SSH/ping to cpbee from named hosts on VR180
#   sudo ./bin/setup-router.sh ssh 192.168.123.254 192.168.123.253    allow only these hosts (replaces the list), applied live
#   sudo ./bin/setup-router.sh ssh off                                 remove the rule
#   sudo ./bin/setup-router.sh ssh                                     show the saved list
# Same as running any mode with VR180_SSH_FROM="..." set. Needs the vr180 link (`wifi` mode) to exist. Key auth only is advisable: SSH is
# reachable by those addresses only, but the building network is shared (addresses can be spoofed by anyone on that Wi-Fi).
if [[ "${1:-}" == "ssh" ]]; then
  shift
  if [[ $# -eq 0 ]]; then
    echo "saved VR180_SSH_FROM: $(cat "$SSH_FROM_FILE" 2>/dev/null || true)"
    exit 0
  fi
  [[ -e /etc/systemd/network/10-vr180.link ]] || { echo "no vr180 link configured: run 'wifi' mode first"; exit 1; }
  if [[ $1 == off ]]; then VR180_SSH_FROM=""; else VR180_SSH_FROM="$*"; fi
  BK=${BACKUP_ROOT:-/root}/router-setup-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
  write_nft
  nft_load
  echo "Firewall reloaded (backup in $BK). vr180 SSH/ping allowed from: ${VR180_SSH_FROM:-nobody}"
  echo "Test from one of those hosts:  ssh chris@$(ip -4 -o addr show dev vr180 | awk '{print $4}' | cut -d/ -f1)"
  exit 0
fi

# ------------------------------------------------------------------ upnp mode: UPnP / NAT-PMP for the LAN, passed on to the upstream router (cmrouter)
#   sudo ./bin/setup-router.sh upnp           install and start it (safe to re-run; also re-applies the settings below)
#   sudo ./bin/setup-router.sh upnp off       remove it (the miniupnpd package stays installed, stopped and disabled)
#   sudo ./bin/setup-router.sh upnp status    mappings now, and what the upstream router holds for them
# miniupnpd listens on lan0 only and, when a LAN client (Vuze, a game, ...) asks for a port, opens it on cpbee: a DNAT from
# wan0 plus a forward accept, in the chains `write_nft` creates when /etc/router-setup/upnp exists.  Clients may only map
# their own address and ports 1024-65535.  bin/upnp-sync-cmrouter then asks the router upstream of wan0 (cmrouter in TEST and
# MIDDLE) to forward the same port number to cpbee's wan0 address; with UPNP_FORWARD=0 that part is not installed.
# Its lan0 ports (SSDP 1900/udp, control $UPNP_HTTP_PORT/tcp, NAT-PMP 5351/udp) go in the lan-port lists like any other.
# NOTE the package's own stop script deletes the whole `inet filter` table (our firewall!), so its start/stop hooks are replaced.
if [[ "${1:-}" == "upnp" ]]; then
  UPNP_HTTP_PORT=${UPNP_HTTP_PORT:-5000}
  UPNP_FORWARD=${UPNP_FORWARD:-1}
  UPNP_CONF=/etc/miniupnpd/miniupnpd.conf
  UPNP_SYNC=/usr/local/sbin/upnp-sync-cmrouter
  upnp_list_add(){ # FILE PORT "what it is": append to a lan0 port list unless the port is already in it
    [[ -e $1 ]] || install -D -m 644 /dev/null "$1"
    grep -Eq "^[[:space:]]*$2([[:space:]]|\$)" "$1" || { [[ -z $(tail -c1 "$1") ]] || echo >> "$1"; printf '%s  # %s\n' "$2" "$3" >> "$1"; }
  }
  upnp_list_del(){ # FILE PORT: remove our line (the comment names miniupnpd), only
    [[ ! -e $1 ]] || sed -i -E "/^[[:space:]]*$2[[:space:]]+#.*miniupnpd/d" "$1"
  }
  case ${2:-on} in
  status)
    echo "miniupnpd: $(systemctl is-active miniupnpd 2>/dev/null || true)   marker: $([[ -e $UPNP_MARK ]] && echo present || echo absent)"
    lan-port upnp 2>/dev/null || cat /var/lib/miniupnpd/upnp.leases 2>/dev/null || echo "no mappings"
    [[ ! -x $UPNP_SYNC ]] || { echo "-- upstream router ($(ip -4 route show default dev wan0 | awk '{print $3; exit}')):"; "$UPNP_SYNC" status; }
    exit 0 ;;
  off)
    BK=${BACKUP_ROOT:-/root}/router-setup-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
    [[ ! -x $UPNP_SYNC ]] || "$UPNP_SYNC" clear || true      # take our forwards off the upstream router first
    systemctl disable --now upnp-sync-cmrouter.path upnp-sync-cmrouter.timer miniupnpd 2>/dev/null || true
    rm -f "$UPNP_MARK" /etc/systemd/system/upnp-sync-cmrouter.{service,path,timer} "$UPNP_SYNC"
    systemctl daemon-reload
    upnp_list_del "$LAN_PORTS_FILE" "$UPNP_HTTP_PORT"; upnp_list_del "$LAN_UDP_PORTS_FILE" 1900; upnp_list_del "$LAN_UDP_PORTS_FILE" 5351
    FW_FORCE=1 write_nft; nft_load      # the lists no longer name its ports: closing them is the point
    echo "UPnP removed (firewall reloaded, backup in $BK). Leases are kept in /var/lib/miniupnpd; 'upnp' turns it on again."
    exit 0 ;;
  on) ;;
  *) echo "usage: setup-router.sh upnp [on|off|status]"; exit 2 ;;
  esac

  BK=${BACKUP_ROOT:-/root}/router-setup-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
  export DEBIAN_FRONTEND=noninteractive
  # 1. hooks first, so that nothing the package does (start, stop, a failed start) can touch the running firewall
  install -d /etc/miniupnpd /var/lib/miniupnpd
  bk /etc/default/miniupnpd
  cat > /etc/default/miniupnpd <<'EOF'
# written by cmpi-router setup-router.sh upnp.  The package's stop script deletes the WHOLE `inet filter` table, which is our firewall.
# Our rules come from /etc/nftables.conf (the chains miniupnpd fills are in it), so: nothing to create at start, only empty its chains at stop.
MiniUPnPd_OTHER_OPTIONS=""
MiniUPnPd_ip6tables_enable=
MiniUPnPd_PRESTART_COMMAND="true"
MiniUPnPd_POSTSTOP_COMMAND="/usr/local/sbin/upnp-nft-flush"
EOF
  cat > /usr/local/sbin/upnp-nft-flush <<'EOF'
#!/bin/sh
# empty miniupnpd's chains (its mappings come back from its lease file at the next start); never fails, never touches anything else
for c in miniupnpd prerouting_miniupnpd postrouting_miniupnpd; do nft flush chain inet filter $c 2>/dev/null; done
exit 0
EOF
  chmod 755 /usr/local/sbin/upnp-nft-flush
  # 2. the package, without letting it start itself
  polrc=/usr/sbin/policy-rc.d; mine=0
  [[ -e $polrc ]] || { printf '#!/bin/sh\nexit 101\n' > $polrc; chmod 755 $polrc; mine=1; }
  apt-get update
  apt-get install -y miniupnpd-nftables miniupnpc
  [[ $mine = 0 ]] || rm -f $polrc
  # 3. config
  bk $UPNP_CONF
  uuid=$(sed -n 's/^uuid=//p' $UPNP_CONF 2>/dev/null | head -n1); [[ -n $uuid ]] || uuid=$(cat /proc/sys/kernel/random/uuid)
  cat > $UPNP_CONF <<EOF
# written by cmpi-router setup-router.sh upnp (re-running it rewrites this file)
ext_ifname=wan0
# wan0 is a private address while cpbee sits behind another router (TEST / MIDDLE); without this miniupnpd refuses to map anything
ext_allow_private_ipv4=yes
listening_ip=lan0
http_port=$UPNP_HTTP_PORT
enable_upnp=yes
enable_natpmp=yes
secure_mode=yes
system_uptime=yes
notify_interval=900
min_lifetime=120
max_lifetime=86400
friendly_name=cpbee
model_name=cpbee router (Debian)
uuid=$uuid
lease_file=/var/lib/miniupnpd/upnp.leases
# the chains write_nft creates (table inet filter)
upnp_table_name=filter
upnp_nat_table_name=filter
upnp_forward_chain=miniupnpd
upnp_nat_chain=prerouting_miniupnpd
upnp_nat_postrouting_chain=postrouting_miniupnpd
# LAN clients: unprivileged ports only, for themselves (secure_mode); everything else is refused
allow 1024-65535 ${LAN_SUBNET}.0/24 1024-65535
deny 0-65535 0.0.0.0/0 0-65535
EOF
  # 4. start only after nftables, so the chains exist and nothing flushes them later
  install -d /etc/systemd/system/miniupnpd.service.d
  cat > /etc/systemd/system/miniupnpd.service.d/router.conf <<'EOF'
[Unit]
After=nftables.service systemd-networkd.service
Wants=nftables.service
[Service]
Restart=on-failure
RestartSec=5
EOF
  # 5. the firewall: marker (adds the chains), the lan0 ports in the lists, reload
  : > "$UPNP_MARK"
  upnp_list_add "$LAN_UDP_PORTS_FILE" 1900 "UPnP SSDP discovery (miniupnpd)"
  upnp_list_add "$LAN_PORTS_FILE" "$UPNP_HTTP_PORT" "UPnP IGD control (miniupnpd)"
  upnp_list_add "$LAN_UDP_PORTS_FILE" 5351 "NAT-PMP / PCP (miniupnpd)"
  write_nft
  nft -f /etc/nftables.conf                       # the chains must exist before miniupnpd starts
  # 6. forwarding to the upstream router
  if [[ $UPNP_FORWARD = 1 ]]; then
    install -m 755 "$(dirname "$(readlink -f "$0")")/upnp-sync-cmrouter" "$UPNP_SYNC"
    cat > /etc/systemd/system/upnp-sync-cmrouter.service <<'EOF'
[Unit]
Description=Pass cpbee's UPnP port mappings on to the upstream router (cmrouter)
After=network-online.target miniupnpd.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/upnp-sync-cmrouter
EOF
    cat > /etc/systemd/system/upnp-sync-cmrouter.path <<'EOF'
[Unit]
Description=Watch cpbee's UPnP leases
[Path]
PathChanged=/var/lib/miniupnpd/upnp.leases
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/upnp-sync-cmrouter.timer <<'EOF'
[Unit]
Description=Refresh the UPnP mappings on the upstream router (they are leased for an hour)
[Timer]
OnBootSec=3min
OnUnitActiveSec=20min
[Install]
WantedBy=timers.target
EOF
  fi
  systemctl daemon-reload
  systemctl enable miniupnpd
  systemctl restart miniupnpd
  [[ $UPNP_FORWARD != 1 ]] || systemctl enable --now upnp-sync-cmrouter.path upnp-sync-cmrouter.timer
  sleep 2
  systemctl is-active --quiet miniupnpd && echo "miniupnpd running on lan0, port $UPNP_HTTP_PORT" || { echo "miniupnpd FAILED to start:"; journalctl -u miniupnpd -n 20 --no-pager; exit 1; }
  nft list table inet filter | grep -q 'chain miniupnpd' || { echo "the miniupnpd chains are missing from the firewall"; exit 1; }
  echo "Check from a LAN machine:  upnpc -l      (or run Vuze's connection test).  Mappings:  lan-port upnp   or   sudo ./bin/setup-router.sh upnp status"
  [[ $UPNP_FORWARD != 1 ]] || echo "Upstream router: UPnP must be ON in cmrouter's settings.  Test: sudo upnp-sync-cmrouter status   (backups in $BK)"
  exit 0
fi

# ------------------------------------------------------------------ reset-stats mode: start the traffic statistics from zero (e.g. at the MIDDLE cutover)
#   sudo ./bin/setup-router.sh reset-stats        asks you to type RESET;  add -y to skip the question
# Moves the history (traffic.db: graphs, per-device totals, sent-alert log) to /var/lib/trafficgraph/archive/<timestamp>/ (nothing is deleted),
# drops the plan's one-cycle offset (--used), zeroes the nftables per-device counters and starts a fresh database.
# Kept: plan size, billing day, thresholds, email/relay settings, device names. The service is stopped meanwhile (a few seconds of gap).
if [[ "${1:-}" == "reset-stats" ]]; then
  [[ -e /etc/systemd/system/trafficgraph.service ]] || { echo "traffic graphs are not installed: run 'graphs' first"; exit 1; }
  state=/var/lib/trafficgraph; ts=$(date +%Y%m%d-%H%M%S); arch=$state/archive/$ts
  echo "This archives the current statistics to $arch and restarts them from zero."
  if [[ ${2:-} != -y ]]; then read -rp "Type RESET to continue: " a; [[ $a == RESET ]] || { echo "aborted, nothing changed"; exit 1; }; fi
  systemctl stop trafficgraph
  install -d -m 750 -o trafficgraph -g trafficgraph "$state/archive" "$arch"
  shopt -s nullglob; dbf=("$state"/traffic.db*); shopt -u nullglob
  [[ ${#dbf[@]} -eq 0 ]] || mv "${dbf[@]}" "$arch"/
  printf 'statistics reset at %s (cpbee, by setup-router.sh reset-stats)\n' "$(date -Is)" > "$arch/README"
  # the offset (--used) belonged to the old numbers; every other setting stays
  python3 - <<'PY'
import json
p = "/etc/trafficgraph/config.json"
c = json.load(open(p))
dropped = [k for k in ("cycle_offset_gb", "cycle_offset_cycle", "cycle_offset_set_at") if c.pop(k, None) is not None]
json.dump(c, open(p, "w"), indent=2); open(p, "a").write("\n")
print("plan offset removed" if dropped else "no plan offset was set")
PY
  # Zero the firewall counters while the web service is down, then wait for the exporter to publish the zeroed values:
  # otherwise the new database would count the bytes the old counters already held.
  nft_load
  rm -f /run/trafficgraph/acct.json
  for _ in $(seq 1 30); do [[ -s /run/trafficgraph/acct.json ]] && break; sleep 1; done
  [[ -s /run/trafficgraph/acct.json ]] || echo "WARNING: the counter exporter has not written acct.json yet (is trafficgraph-acct running?)"
  systemctl start trafficgraph
  sleep 3; systemctl is-active --quiet trafficgraph && echo "trafficgraph restarted on an empty database" || { echo "trafficgraph FAILED to start:"; journalctl -u trafficgraph -n 20 --no-pager; exit 1; }
  echo "Old statistics: $arch"
  echo "The plan meter now counts from 0 for the current cycle. To add usage that cpbee cannot see: sudo ./bin/setup-router.sh plan --used <GB>"
  exit 0
fi

# ------------------------------------------------------------------ dns mode: names for hosts behind other interfaces (VR180)
# Writes /etc/dnsmasq.d/hosts.conf so every lan0 client can resolve them. Edit the list below, or override it, e.g.
#   VR180_HOSTS="vr180=192.168.123.1 mesh,meshvs8875-1=192.168.123.101" sudo -E ./bin/setup-router.sh dns
# Format: name[,alias...]=ipv4   (each name is also published as name.$LAN_DOMAIN)
# Also fixes dnsmasq handing LAN clients 127.0.1.1 for the router's own name (from Debian's /etc/hosts): `no-hosts` +
# an explicit record for this box's lan0 address.
if [[ "${1:-}" == "dns" ]]; then
  # default: every LAN name in middle/lan-hosts.txt (cmlaptop's host list), so cpbee's DNS is the one place the names live
  [[ -z ${VR180_HOSTS:-} && -r $ROOT/middle/lan-hosts.txt ]] && VR180_HOSTS=$(sed 's/#.*//' "$ROOT/middle/lan-hosts.txt" | tr -s ' \n' ' ')
  VR180_HOSTS="${VR180_HOSTS:-vr180=192.168.123.1 mesh,meshvs8875-1=192.168.123.101}"
  conf=/etc/dnsmasq.d/lan.conf
  [[ -e $conf ]] || { echo "$conf missing: run the full setup first"; exit 1; }
  dom=$(sed -n 's/^domain=//p' "$conf" | head -1); dom=${dom:-$LAN_DOMAIN}
  lanip=$(sed -n 's/^dhcp-option=option:router,//p' "$conf" | head -1)
  [[ -n $lanip ]] || { echo "cannot find the LAN address in $conf"; exit 1; }
  BK=${BACKUP_ROOT:-/root}/router-setup-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"
  me=$(hostname); me=${me%%.*}
  recs="host-record=$me,$me.$dom,$lanip"
  for e in $VR180_HOSTS; do
    names=${e%%=*}; ip=${e#*=}
    [[ $e == *=* && $names =~ ^[A-Za-z0-9._,-]+$ && $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "bad entry '$e' (want name[,alias]=ipv4)"; exit 1; }
    list=""; IFS=, read -ra arr <<<"$names"
    for n in "${arr[@]}"; do list+="${list:+,}$n,$n.$dom"; done
    recs+=$'\n'"host-record=$list,$ip"
  done
  bk /etc/dnsmasq.d/hosts.conf
  cat > /etc/dnsmasq.d/hosts.conf <<EOF
# written by setup-router.sh dns. no-hosts: do not serve /etc/hosts (it maps this box's name to 127.0.1.1)
no-hosts
$recs
EOF
  dnsmasq --test || { echo "dnsmasq rejected the config; restoring"; rm -f /etc/dnsmasq.d/hosts.conf; [[ -e $BK/etc/dnsmasq.d/hosts.conf ]] && cp -a "$BK/etc/dnsmasq.d/hosts.conf" /etc/dnsmasq.d/; exit 1; }
  systemctl restart dnsmasq
  sleep 1; systemctl is-active --quiet dnsmasq && echo "dnsmasq restarted with:" || { echo "dnsmasq FAILED to start"; exit 1; }
  sed 's/^/  /' /etc/dnsmasq.d/hosts.conf
  echo "Test from a LAN client:  nslookup mesh $lanip   (and nslookup $me $lanip -> $lanip, not 127.0.1.1)"
  exit 0
fi

# ------------------------------------------------------------------ wan mode: choose which USB device is wan0
#   sudo ./bin/setup-router.sh wan        pin wan0 to the one USB network device plugged in, by MAC (MIDDLE: USB Ethernet adapter)
#   sudo ./bin/setup-router.sh wan any    wan0 = whichever single USB network device is plugged in (FINAL: phone tether / data stick)
# With two USB network devices plugged in (e.g. phone tether + adapter) the choice is ambiguous, so it asks you to unplug one.
if [[ "${1:-}" == "wan" ]]; then
  if [[ "${2:-}" == "any" ]]; then
    write_wan_cfg ""
    echo "wan0 now matches ANY USB network device (phone tether, data stick, adapter). Keep only one plugged in. Reboot to apply."
    exit 0
  fi
  if [[ ${#USB_NICS[@]} -gt 1 && -z $WAN_IF_OVERRIDE ]]; then
    echo "More than one USB network device is plugged in, so I cannot tell which one is the WAN:"
    for n in "${USB_NICS[@]}"; do
      printf '  %-14s %s   driver %s\n' "$n" "$(< /sys/class/net/$n/address)" "$(basename "$(readlink -f /sys/class/net/$n/device/driver)")"
    done
    echo "Unplug the one you do NOT want as the WAN (the phone tether is usually rndis_host), or re-run with WAN_IF=<name>."
    exit 1
  fi
  [[ -n $WAN_IF ]] || { echo "No USB ethernet adapter found. Plug it in, or set WAN_IF=..."; exit 1; }
  WAN_MAC=$(< /sys/class/net/$WAN_IF/address)
  echo "Pinning wan0 to $WAN_IF ($WAN_MAC, driver $(basename "$(readlink -f /sys/class/net/$WAN_IF/device/driver)"))"
  write_wan_cfg "$WAN_MAC"
  echo "Done. Reboot (or replug the adapter after 'udevadm control --reload') to rename it to wan0."
  echo "A pinned MAC means a different device (phone, data stick) will NOT become wan0; use './bin/setup-router.sh wan any' to undo that."
  exit 0
fi

[[ -n $LAN_IF ]] || { echo "No wired PCI NIC found for the LAN. Set LAN_IF=... explicitly."; exit 1; }
[[ $LAN_IF != "${WAN_IF:-}" ]] || { echo "LAN and WAN resolved to the same NIC ($LAN_IF)"; exit 1; }
LAN_MAC=$(< /sys/class/net/$LAN_IF/address)
WAN_MAC=""
echo "LAN: $LAN_IF ($LAN_MAC) -> lan0   ${LAN_SUBNET}.1/24"
if [[ -n $WAN_IF ]]; then
  WAN_MAC=$(< /sys/class/net/$WAN_IF/address)
  echo "WAN: $WAN_IF ($WAN_MAC) -> wan0   DHCP"
else
  echo "WAN: no USB ethernet adapter found. DEFERRED: any USB adapter will become wan0 later"
  echo "     (run './bin/setup-router.sh wan' once it is plugged in to pin it by MAC)."
  echo "WARNING: after the reboot $LAN_IF becomes the LAN with a DHCP server on it. Do NOT leave it cabled"
  echo "         to your existing router/network, or it will hand out leases to the whole house."
fi
read -rp "Looks right? [y/N] " a; [[ $a =~ ^[Yy]$ ]] || exit 1

BK=${BACKUP_ROOT:-/root}/router-setup-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"

# ------------------------------------------------------------------ packages (uses the current network)
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nftables dnsmasq systemd-resolved ethtool tcpdump conntrack curl unattended-upgrades
systemctl stop dnsmasq || true              # package auto-starts with default config; real config starts at boot

# ------------------------------------------------------------------ NIC names + networkd
bk /etc/network/interfaces
install -d /etc/systemd/network
cat > /etc/systemd/network/10-lan0.link <<EOF
[Match]
MACAddress=$LAN_MAC
[Link]
Name=lan0
EOF
write_wan_cfg "$WAN_MAC"
cat > /etc/systemd/network/20-lan0.network <<EOF
[Match]
MACAddress=$LAN_MAC
[Network]
Address=${LAN_SUBNET}.1/24
ConfigureWithoutCarrier=yes
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
# hand networking over from ifupdown / NetworkManager to systemd-networkd (takes effect at reboot)
cat > /etc/network/interfaces <<EOF
# managed by systemd-networkd (see /etc/systemd/network). Original in $BK
auto lo
iface lo inet loopback
EOF
systemctl disable NetworkManager 2>/dev/null || true
systemctl enable systemd-networkd systemd-resolved

# resolver: resolved fetches upstream DNS from the WAN lease; dnsmasq serves LAN clients from that
install -d /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/router.conf
bk /etc/resolv.conf
# cpbee asks its own dnsmasq (it knows the LAN names, domain cmnet); dnsmasq forwards to the uplink servers resolved keeps current
rm -f /etc/resolv.conf
printf '# written by setup-router.sh: local dnsmasq, which forwards upstream (resolv-file=/run/systemd/resolve/resolv.conf)\nnameserver 127.0.0.1\nsearch cmnet\n' > /etc/resolv.conf

# ------------------------------------------------------------------ dnsmasq
bk /etc/dnsmasq.conf
cat > /etc/dnsmasq.d/lan.conf <<EOF
interface=lan0
interface=lo
no-dhcp-interface=lo
bind-dynamic
domain-needed
bogus-priv
resolv-file=/run/systemd/resolve/resolv.conf
cache-size=1000
local=/${LAN_DOMAIN}/
domain=${LAN_DOMAIN}
expand-hosts
dhcp-authoritative
dhcp-range=${LAN_SUBNET}.${DHCP_FROM},${LAN_SUBNET}.${DHCP_TO},255.255.255.0,${LEASE}
dhcp-option=option:router,${LAN_SUBNET}.1
dhcp-option=option:dns-server,${LAN_SUBNET}.1
# static leases:  dhcp-host=aa:bb:cc:dd:ee:ff,printer,${LAN_SUBNET}.20
EOF
install -d /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/router.conf <<EOF
[Unit]
After=systemd-networkd.service systemd-resolved.service
[Service]
Restart=on-failure
RestartSec=3
EOF
systemctl daemon-reload
systemctl enable dnsmasq

# ------------------------------------------------------------------ kernel
cat > /etc/sysctl.d/90-router.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.tcp_syncookies=1
net.ipv6.conf.all.forwarding=0
EOF

# ------------------------------------------------------------------ firewall
write_nft
systemctl enable nftables

cat <<EOF

Config written (backups in $BK). Live networking was NOT changed.

Next:
  1. sudo reboot
  2. Cable it:  USB adapter -> modem / upstream router,   onboard port -> switch / your devices
  3. sudo ./bin/setup-router.sh check
Client devices get ${LAN_SUBNET}.${DHCP_FROM}-${DHCP_TO} from DHCP, gateway/DNS ${LAN_SUBNET}.1.
EOF
