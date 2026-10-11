#!/bin/bash

# ==============================================================================
# Script: multi-hop-trace.sh
# Purpose: Runs local traceroute, then SSHs into intermediate hops to run
#          OS-specific routing, interface, and traceroute commands.
# Usage:   ./multi-hop-trace.sh <target_ip_or_hostname> [ssh_username]
# Env:     SKIP_REMOTE_TRACE=1   skip the (slow) traceroute run on each hop
#          MAX_HOPS=20           max TTL for traceroutes
#          SNIFF=1               also listen passively for STP/LLDP/CDP frames on each
#                                hop (needs tcpdump there, plus root, passwordless sudo, or file caps)
#          SNIFF_SECS=35         how long to listen per hop (LLDP is sent every 30s)
#          SNMP_COMMUNITY=name   query hops and L2 devices (switch/AP) over SNMP v2c from
#                                this machine: sysName/sysDescr, and which port of the
#                                device each neighbouring hop's MAC was learned on.
#                                Needs snmpget/snmpwalk (apt: snmp; Cygwin: net-snmp-utils).
#                                SNMP_VERSION=auto|2c|1 (auto: try v2c then v1 per device)
#                                SNMP_TIMEOUT=2 (seconds per query)
# Notes:   Works with iputils/traceroute-db, GNU inetutils (Cygwin), tracepath,
#          and Windows tracert locally; Linux/BSD/macOS/Windows on the hops.
#          Hops need key-based SSH (BatchMode) - others are reported + skipped.
# ==============================================================================

TARGET=$1
SSH_USER=${2:-${USER:-$(id -un)}}
SKIP_REMOTE_TRACE=${SKIP_REMOTE_TRACE:-0}
MAX_HOPS=${MAX_HOPS:-20}
SNIFF=${SNIFF:-0}
SNIFF_SECS=${SNIFF_SECS:-35}
SNMP_COMMUNITY=${SNMP_COMMUNITY:-}
SNMP_VERSION=${SNMP_VERSION:-auto}
SNMP_TIMEOUT=${SNMP_TIMEOUT:-2}

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <target_ip_or_hostname> [ssh_username]"
    exit 1
fi

# TARGET is interpolated into remote commands, so keep it to hostname/IP chars.
case "$TARGET" in
    *[!A-Za-z0-9._:-]*) echo "Invalid target: $TARGET"; exit 1 ;;
esac

# Options to prevent hanging and password prompts
SSH_OPTS=(-o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR)

have() { command -v "$1" >/dev/null 2>&1; }

if [ -n "$SNMP_COMMUNITY" ] && ! { have snmpget && have snmpwalk; }; then
    echo "Note: SNMP_COMMUNITY set but snmpget/snmpwalk not found (apt install snmp, or Cygwin net-snmp-utils); SNMP skipped."
    SNMP_COMMUNITY=
fi

echo "========================================================"
echo " MULTI-HOP PATH ANALYSIS"
echo " Target: $TARGET | SSH User: $SSH_USER"
echo "========================================================"

# ------------------------------------------------------------------------------
# 1. Local trace -> list of hop IPs
# ------------------------------------------------------------------------------
echo -e "\n[1] DISCOVERING INTERMEDIATE HOPS (Local Traceroute)..."

local_trace() {
    local help
    case "$(uname -s)" in
        CYGWIN*|MINGW*|MSYS*)
            # Native Windows tracert is the most reliable here (no raw-socket issues)
            if have tracert; then
                tracert -d -h "$MAX_HOPS" -w 2000 "$TARGET" 2>&1 | tr -d '\r'
                return
            fi ;;
    esac

    if have traceroute; then
        help=$(traceroute --help 2>&1)
        if [[ "$help" == *resolve-hostnames* ]]; then
            # GNU inetutils: numeric by default, no -n / -I
            traceroute -q 1 -w 2 -m "$MAX_HOPS" "$TARGET" 2>&1
        else
            # iputils/traceroute-db style. ICMP (-I) needs root; fall back to UDP.
            local out
            out=$(traceroute -n -I -q 1 -w 2 -m "$MAX_HOPS" "$TARGET" 2>&1)
            if [[ "$out" == *[Pp]rivilege* || "$out" == *"not permitted"* || "$out" == *"nvalid option"* ]]; then
                out=$(traceroute -n -q 1 -w 2 -m "$MAX_HOPS" "$TARGET" 2>&1)
            fi
            echo "$out"
        fi
    elif have tracepath; then
        tracepath -n -m "$MAX_HOPS" "$TARGET" 2>&1
    elif have tracert; then
        tracert -d -h "$MAX_HOPS" -w 2000 "$TARGET" 2>&1 | tr -d '\r'
    else
        echo "No traceroute, tracepath or tracert found (try: apt install traceroute)"
    fi
}

LOCAL_TRACE=$(local_trace)
echo "$LOCAL_TRACE"

# Hop lines start with a hop number (traceroute "1  ip", tracepath "1:  ip",
# tracert "  1  <1 ms ... ip"). Take the first IPv4 on each such line.
HOPS=$(echo "$LOCAL_TRACE" | awk '
    /^[ \t]*[0-9]+[?:]?[ \t]/ {
        if (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/))
            print substr($0, RSTART, RLENGTH)
    }' | awk '!seen[$0]++')

# Remote hops may not resolve a name that only this machine knows, so hand them
# an IP: use the one the local trace printed in its header, e.g.
# "traceroute to NAME (1.2.3.4)" or "Tracing route to NAME [1.2.3.4]".
if ! [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    RESOLVED=$(echo "$LOCAL_TRACE" | head -3         | grep -oE '[[(][0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[])]' | head -1 | tr -d '[]()')
    if [ -z "$RESOLVED" ] && have getent; then
        RESOLVED=$(getent ahostsv4 "$TARGET" 2>/dev/null | awk 'NR==1{print $1}')
    fi
    if [ -n "$RESOLVED" ]; then
        echo "(remote hops will use $RESOLVED for $TARGET)"
        TARGET=$RESOLVED
    fi
fi

if [ -z "$HOPS" ]; then
    echo "No valid hops found. Target might be on local subnet or fully filtered."
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. Iterate through each hop and SSH in
# ------------------------------------------------------------------------------
echo -e "\n[2] QUERYING INTERMEDIATE HOPS VIA SSH..."
echo "========================================================"

# Script run on Unix-like hops (via 'sh -s' on stdin, so one connection does it all)
unix_script() {
    cat <<EOF
T='$TARGET'
HIP='$IP'
PIP='$PREV_IP'
BRS=''
PATH="\$PATH:/usr/sbin:/sbin"   # bridge, lldpctl live here; not on a non-login ssh PATH
SKIP=$SKIP_REMOTE_TRACE
SNIFF=$SNIFF
SNIFFSECS=$SNIFF_SECS
MAXH=$MAX_HOPS
OS=\$(uname -s)
echo "Detected OS: \$OS"
# '@@' lines are machine-readable facts for the final summary (hidden from output)
echo "@@HOST \$(hostname 2>/dev/null)"
echo "@@OS \$OS"
if command -v ip >/dev/null 2>&1; then
  RG=\$(ip route get "\$T" 2>/dev/null | head -1)
  INIF=\$(ip -o -4 addr show 2>/dev/null | awk -v a="\$HIP" '{split(\$4,p,"/"); if (p[1]==a) {print \$2; exit}}')
  OUTDEV=\$(echo "\$RG" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
  echo "@@RGET \$RG"
  echo "@@INIF \$INIF"
  for d in \$(printf '%s\n' "\$INIF" "\$OUTDEV" | awk 'NF && !s[\$0]++'); do
    echo "@@MAC \$d \$(cat "/sys/class/net/\$d/address" 2>/dev/null)"
  done
  # For Wi-Fi interfaces: signal level + who is on the segment (the access point
  # shows up as a neighbour of both ends of a Wi-Fi hop)
  for d in \$(printf '%s\n' "\$INIF" "\$OUTDEV" | awk 'NF && !s[\$0]++'); do
    [ -d "/sys/class/net/\$d/wireless" ] || continue
    echo "@@WIFI \$d \$(awk -v d="\$d:" '\$1==d {print \$4+0}' /proc/net/wireless 2>/dev/null)"
    ip -4 neigh show dev "\$d" 2>/dev/null | awk '\$2=="lladdr" {print \$1, \$3}' | while read nip nmac; do
      echo "@@NEIGH \$d \$nip \$nmac \$(getent hosts "\$nip" 2>/dev/null | awk '{print \$2; exit}')"
    done
  done

  # Bridges: is the in/out interface a bridge (or a port of one)? Which bridge
  # port is the previous / next hop's MAC learned on (bridge fdb)?
  isbr() { [ -d "/sys/class/net/\$1/bridge" ]; }
  portof() {   # <ip> <bridge dev> -> bridge port that ip's MAC is learned on
    [ -n "\$1" ] && [ -n "\$2" ] && isbr "\$2" || return 0
    m=\$(ip -4 neigh show to "\$1" dev "\$2" 2>/dev/null | awk '\$2=="lladdr" {print \$3; exit}')
    [ -n "\$m" ] || return 0
    bridge fdb show br "\$2" 2>/dev/null | awk -v m="\$m" '\$1==m {for (i=2;i<=NF;i++) if (\$i=="dev") {print \$(i+1); exit}}'
  }
  for d in \$(printf '%s\n' "\$INIF" "\$OUTDEV" | awk 'NF && !s[\$0]++'); do
    if isbr "\$d"; then BR=\$d
    elif [ -L "/sys/class/net/\$d/master" ]; then BR=\$(basename "\$(readlink "/sys/class/net/\$d/master")")
    else continue; fi
    echo "@@BRIDGE \$d \$BR \$(ls "/sys/class/net/\$BR/brif" 2>/dev/null | tr '\n' ',')"
    case " \$BRS " in *" \$BR "*) ;; *) BRS="\$BRS \$BR" ;; esac
  done
  # PROMISC flag: set on bridge ports, and while a capture (tcpdump etc.) runs
  for d in \$(printf '%s\n' \$INIF \$OUTDEV \$(for b in \$BRS; do ls "/sys/class/net/\$b/brif" 2>/dev/null; done) | awk 'NF && !s[\$0]++'); do
    ip link show dev "\$d" 2>/dev/null | head -1 | grep -q PROMISC && echo "@@PROMISC \$d"
  done
  if [ -n "\$BRS" ]; then
    NH=\$(echo "\$RG" | sed -n 's/.* via \([^ ]*\).*/\1/p'); [ -n "\$NH" ] || NH=\$T
    case "\$RG" in
      local*) ;;
      *) p=\$(portof "\$NH" "\$OUTDEV"); [ -n "\$p" ] && echo "@@EGRESS \$OUTDEV \$p" ;;
    esac
    p=\$(portof "\$PIP" "\$INIF"); [ -n "\$p" ] && echo "@@INGRESS \$INIF \$p"
    for br in \$BRS; do
      bridge fdb show br "\$br" 2>/dev/null | awk -v b="\$br" '!/permanent/ && !/ self/ {for (i=2;i<=NF;i++) if (\$i=="dev") print "@@FDB", b, \$(i+1), \$1}'
    done
  fi
fi

# LLDP neighbours (lldpd): "@@LLDP <iface> <name|ip|mac|port|pdesc> <value>"
if command -v lldpctl >/dev/null 2>&1; then
  lldpctl -f keyvalue 2>/dev/null | sed -n \
    -e 's/^lldp\.\(.*\)\.chassis\.name=\(.*\)/@@LLDP \1 name \2/p' \
    -e 's/^lldp\.\(.*\)\.chassis\.mgmt-ip=\(.*\)/@@LLDP \1 ip \2/p' \
    -e 's/^lldp\.\(.*\)\.chassis\.mac=\(.*\)/@@LLDP \1 mac \2/p' \
    -e 's/^lldp\.\(.*\)\.port\.ifname=\(.*\)/@@LLDP \1 port \2/p' \
    -e 's/^lldp\.\(.*\)\.port\.descr=\(.*\)/@@LLDP \1 pdesc \2/p'
fi
echo '>> ROUTE:'
case "\$OS" in
  Darwin|*BSD) route -n get "\$T" 2>/dev/null || netstat -rn | head -20 ;;
  *)
    if command -v ip >/dev/null 2>&1; then
      ip route get "\$T" 2>/dev/null || ip route
    else
      route -n 2>/dev/null | grep -v Kernel
    fi ;;
esac
echo '>> INTERFACES:'
if [ "\$OS" = Linux ] && command -v ip >/dev/null 2>&1; then
  ip -br addr 2>/dev/null || ip addr
else
  ifconfig -a 2>/dev/null | grep -E '^[a-z]|inet '
fi
if [ "\$SKIP" -eq 0 ]; then
  echo '>> TRACEROUTE:'
  TO=''; command -v timeout >/dev/null 2>&1 && TO='timeout 90'
  if command -v traceroute >/dev/null 2>&1; then
    if [ "\$OS" = Linux ]; then
      sudo -n traceroute -n -I -q 1 -w 2 -m "\$MAXH" "\$T" 2>/dev/null \
        || traceroute -n -I -q 1 -w 2 -m "\$MAXH" "\$T" 2>/dev/null \
        || \$TO traceroute -n -q 1 -w 2 -m "\$MAXH" "\$T"
    else
      \$TO traceroute -n -q 1 -w 2 -m "\$MAXH" "\$T"
    fi
  elif command -v tracepath >/dev/null 2>&1; then
    \$TO tracepath -n -m "\$MAXH" "\$T"
  else
    echo '(no traceroute/tracepath installed)'
  fi
fi
if [ -n "\$BRS" ]; then
  echo '>> BRIDGE:'
  for br in \$BRS; do
    echo "\$br ports: \$(ls "/sys/class/net/\$br/brif" 2>/dev/null | tr '\n' ' ')"
    bridge fdb show br "\$br" 2>/dev/null | grep -v permanent | head -30
  done
fi
if command -v lldpctl >/dev/null 2>&1; then
  echo '>> LLDP:'
  lldpctl 2>/dev/null | head -60
fi
if [ "\$SNIFF" -eq 1 ]; then
  # Passive listen for the frames switches/bridges send to reserved multicast
  # addresses: STP (01:80:c2:00:00:00), LLDP (01:80:c2:00:00:0e), CDP (01:00:0c:cc:cc:cc).
  # Frames from this host's own interfaces are dropped.
  echo ">> SNIFF (listening \$SNIFFSECS s for STP/LLDP/CDP):"
  SUDO=''; [ "\$(id -u)" = 0 ] || SUDO='sudo -n'
  # tcpdump with file capabilities (setup-monitoring.sh tools, WITH_SNIFF=1) needs no sudo at all
  TB=\$(readlink -f "\$(command -v tcpdump 2>/dev/null)" 2>/dev/null)
  if [ -n "\$TB" ] && command -v getcap >/dev/null 2>&1 && getcap "\$TB" 2>/dev/null | grep -q cap_net_raw; then SUDO=''; fi
  DEVS=\$(printf '%s\n' \$INIF \$OUTDEV \$(for b in \$BRS; do ls "/sys/class/net/\$b/brif" 2>/dev/null; done) | awk 'NF && !s[\$0]++')
  if ! command -v tcpdump >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    echo '(skipped: needs tcpdump and timeout)'
  elif [ -z "\$DEVS" ]; then
    echo '(skipped: no interface found)'
  elif ! \$SUDO tcpdump --version >/dev/null 2>&1; then
    echo '(skipped: needs root, or passwordless sudo for tcpdump)'
  else
    SD=\$(mktemp -d)
    for d in \$DEVS; do
      timeout "\$SNIFFSECS" \$SUDO tcpdump -i "\$d" -l -nn -e -v -s 512 -c 50 'ether dst 01:80:c2:00:00:00 or ether dst 01:80:c2:00:00:0e or ether dst 01:00:0c:cc:cc:cc' >"\$SD/\$d.cap" 2>/dev/null &
    done
    wait
    cat /sys/class/net/*/address > "\$SD/own" 2>/dev/null
    for d in \$DEVS; do
      awk -v dev="\$d" -v ownf="\$SD/own" '
        BEGIN { while ((getline l < ownf) > 0) own[tolower(l)] = 1; q = "\047[^\047]*\047"; reset() }
        function reset() { type=""; sa=""; nm="-"; pt="-"; ip="-"; bid="-"; rid="-"; pidflag=0 }
        function flush() {
          if (type != "" && !(sa in own) && !seen[type, sa]++) {
            if (type == "stp") print "@@SNIFF " dev "|stp|" sa "|" bid "|" rid "|-"
            else print "@@SNIFF " dev "|" type "|" sa "|" nm "|" pt "|" ip
          }
          reset()
        }
        /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
          flush()
          if (match(\$0, /[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f] >/)) sa = tolower(substr(\$0, RSTART, 17))
          if (\$0 ~ /01:80:c2:00:00:0e|LLDP/) type = "lldp"
          else if (\$0 ~ /01:00:0c:cc:cc:cc|CDP/) type = "cdp"
          else type = "stp"
          if (match(\$0, /bridge-id [^,]+/)) bid = substr(\$0, RSTART + 10, RLENGTH - 10)
          next
        }
        type == "stp" && match(\$0, /root-id [^,]+/) { rid = substr(\$0, RSTART + 8, RLENGTH - 8) }
        type == "stp" && bid == "-" && match(\$0, /bridge-id [^,]+/) { bid = substr(\$0, RSTART + 10, RLENGTH - 10) }
        type == "lldp" && /System Name TLV/ { v = \$0; sub(/^.*length [0-9]+: */, "", v); nm = v }
        type == "lldp" && /Port ID TLV/ { pidflag = 1; next }
        type == "lldp" && pidflag && /Subtype/ { v = \$0; sub(/^.*\): */, "", v); pt = v; pidflag = 0 }
        type == "lldp" && /AFI IPv4/ && match(\$0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) { ip = substr(\$0, RSTART, RLENGTH) }
        type == "cdp" && /Device-ID/ && match(\$0, q) { nm = substr(\$0, RSTART + 1, RLENGTH - 2) }
        type == "cdp" && /Port-ID/ && match(\$0, q) { pt = substr(\$0, RSTART + 1, RLENGTH - 2) }
        type == "cdp" && /IPv4/ && match(\$0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) { ip = substr(\$0, RSTART, RLENGTH) }
        END { flush() }
      ' "\$SD/\$d.cap" >> "\$SD/found"
    done
    cat "\$SD/found"                                  # tagged, parsed by the caller
    if [ -s "\$SD/found" ]; then sed 's/^@@SNIFF /  heard on /; s/|/  /g' "\$SD/found"; else echo '(nothing heard)'; fi
    rm -rf "\$SD"
  fi
fi
EOF
}

# First round-trip time shown on the local trace line that contains $1
rtt_for() {
    echo "$LOCAL_TRACE" | awk -v ip="$1" '
        { r = "(^|[^0-9.])" ip; gsub(/\./, "\\.", r); r = r "($|[^0-9.])" }
        $0 ~ r && match($0, /<?[0-9.]+ ?ms/) { print substr($0, RSTART, RLENGTH); exit }'
}

# Per-hop facts for the summary (indexed by hop number)
TMP=$(mktemp); SNMP_CACHE=$(mktemp)
trap 'rm -f "$TMP" "$SNMP_CACHE"' EXIT
H_IP=(); H_NAME=(); H_OS=(); H_RTT=(); H_IN=(); H_OUT=(); H_NOTE=()
H_IMAC=(); H_OMAC=(); H_SNIFF=(); H_PROM=(); H_BRIDGE=(); H_FDB=(); H_EGR=(); H_ING=(); H_LLDP=()   # bridge facts, LLDP neighbours "iface key value"
H_IDEV=(); H_ODEV=(); H_WIFI=(); H_NEIGH=()   # in/out interface, Wi-Fi "dev dBm", neighbours "dev ip mac name"

HOP_NUM=0
for IP in $HOPS; do
    HOP_NUM=$((HOP_NUM + 1))
    DEST="$SSH_USER@$IP"
    echo -e "\n--- HOP $HOP_NUM: $IP ---"
    PREV_IP=${H_IP[HOP_NUM-1]}     # lets the hop find which bridge port we arrive on
    H_IP[HOP_NUM]=$IP
    H_RTT[HOP_NUM]=$(rtt_for "$IP")
    : > "$TMP"

    # Probe: Unix-like?
    OUT=$(ssh "${SSH_OPTS[@]}" "$DEST" "uname -s" 2>&1 </dev/null)
    RC=$?
    if [ $RC -eq 255 ]; then
        # ssh itself failed (refused / timeout / auth)
        echo "⚠️  SSH failed: $(echo "$OUT" | tail -1). Skipping."
        H_NOTE[HOP_NUM]="no SSH access: $(echo "$OUT" | tail -1 | sed 's/^[A-Za-z0-9_.@-]*: //')"
        continue
    fi

    OS_TYPE="UNKNOWN"
    case "$OUT" in
        Linux*|Darwin*|*BSD*) OS_TYPE="UNIX" ;;
        CYGWIN*|MINGW*|MSYS*) OS_TYPE="WINDOWS" ;;
        *)
            # Native Windows OpenSSH (cmd or PowerShell shell) has no 'uname';
            # 'cmd.exe /c ver' works under both.
            VER=$(ssh "${SSH_OPTS[@]}" "$DEST" "cmd.exe /c ver" 2>/dev/null </dev/null)
            [[ "$VER" == *Windows* ]] && OS_TYPE="WINDOWS"
            ;;
    esac

    if [ "$OS_TYPE" == "UNKNOWN" ]; then
        echo "⚠️  OS could not be determined (uname said: $(echo "$OUT" | head -1)). Skipping."
        H_NOTE[HOP_NUM]="OS not recognised"
        continue
    fi

    echo "--------------------------------------------------------"

    case "$OS_TYPE" in
        UNIX)
            unix_script | ssh "${SSH_OPTS[@]}" "$DEST" "sh -s" | tee "$TMP" | grep -v '^@@'

            H_NAME[HOP_NUM]=$(sed -n 's/^@@HOST //p' "$TMP" | head -1)
            H_OS[HOP_NUM]=$(sed -n 's/^@@OS //p' "$TMP" | head -1)
            INIF=$(sed -n 's/^@@INIF //p' "$TMP" | head -1)
            RG=$(sed -n 's/^@@RGET //p' "$TMP" | head -1)
            [ -n "$INIF" ] && H_IN[HOP_NUM]="$INIF $IP"
            H_IDEV[HOP_NUM]=$INIF
            H_IMAC[HOP_NUM]=$(sed -n 's/^@@MAC //p' "$TMP" | awk -v d="$INIF" '$1==d {print $2; exit}')
            H_WIFI[HOP_NUM]=$(sed -n 's/^@@WIFI //p' "$TMP")
            H_NEIGH[HOP_NUM]=$(sed -n 's/^@@NEIGH //p' "$TMP")
            H_BRIDGE[HOP_NUM]=$(sed -n 's/^@@BRIDGE //p' "$TMP")
            H_PROM[HOP_NUM]=$(sed -n 's/^@@PROMISC //p' "$TMP" | tr '
' ' ')
            H_SNIFF[HOP_NUM]=$(sed -n 's/^@@SNIFF //p' "$TMP")
            R_DEV=
            H_FDB[HOP_NUM]=$(sed -n 's/^@@FDB //p' "$TMP")
            H_EGR[HOP_NUM]=$(sed -n 's/^@@EGRESS [^ ]* //p' "$TMP" | head -1)
            H_ING[HOP_NUM]=$(sed -n 's/^@@INGRESS [^ ]* //p' "$TMP" | head -1)
            H_LLDP[HOP_NUM]=$(sed -n 's/^@@LLDP //p' "$TMP")
            case "$RG" in
                "")     ;;
                local*) H_OUT[HOP_NUM]="(target is this host)" ;;
                *)
                    R_VIA=$(echo "$RG" | sed -n 's/.* via \([^ ]*\).*/\1/p')
                    R_DEV=$(echo "$RG" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
                    R_SRC=$(echo "$RG" | sed -n 's/.* src \([^ ]*\).*/\1/p')
                    H_ODEV[HOP_NUM]=$R_DEV
                    if [ -n "$R_VIA" ]; then R_NEXT="via $R_VIA"; else R_NEXT="direct to $TARGET"; fi
                    H_OUT[HOP_NUM]="$R_DEV${R_SRC:+ $R_SRC} -> $R_NEXT"
                    ;;
            esac
            [ -n "$R_DEV" ] && H_OMAC[HOP_NUM]=$(sed -n 's/^@@MAC //p' "$TMP" | awk -v d="$R_DEV" '$1==d {print $2; exit}')
            ;;

        WINDOWS)
            # Plain executables only (no ; & > or quotes), so this behaves the
            # same whether the remote shell is cmd, PowerShell or Cygwin bash.
            echo "Detected OS: WINDOWS"
            H_OS[HOP_NUM]="Windows"
            H_NAME[HOP_NUM]=$(ssh "${SSH_OPTS[@]}" "$DEST" "hostname" 2>/dev/null </dev/null | tr -d '\r')
            H_NOTE[HOP_NUM]="interface/route detail not summarised for Windows"
            echo ">> ROUTE:"
            ssh "${SSH_OPTS[@]}" "$DEST" "route print -4" 2>/dev/null </dev/null | tr -d '\r' \
                | sed -n '/Active Routes/,/Persistent Routes/p'
            echo ">> INTERFACES:"
            ssh "${SSH_OPTS[@]}" "$DEST" "ipconfig" 2>/dev/null </dev/null | tr -d '\r' \
                | grep -E 'adapter|IPv4|Gateway'
            if [ "$SKIP_REMOTE_TRACE" -eq 0 ]; then
                echo ">> TRACEROUTE:"
                ssh "${SSH_OPTS[@]}" "$DEST" "tracert -d -h $MAX_HOPS -w 2000 $TARGET" 2>&1 </dev/null | tr -d '\r'
            fi
            ;;
    esac
done

echo -e "\n========================================================"
echo " ANALYSIS COMPLETE"
echo "========================================================"

# ------------------------------------------------------------------------------
# 3. Summary: the traceroute path annotated with what each router told us
# ------------------------------------------------------------------------------
echo -e "\n[3] PATH SUMMARY"
echo "========================================================"

# --- Layer-2 devices ---------------------------------------------------------
# Two routers on the same Wi-Fi network are one IP hop apart, so traceroute never
# shows the access point between them. If a hop leaves via a Wi-Fi interface (or
# the next one is entered via one), find the box both sides can see on that
# segment (the AP/gateway is in both neighbour tables) and list it as a step.
# --- SNMP (run from this machine; all OIDs numeric so no MIBs are needed) -----------
snmp_on()  { [ -n "$SNMP_COMMUNITY" ]; }
# snmp_ver <ip>: protocol version to use for that device. With SNMP_VERSION=auto the first
# call probes sysDescr with v2c, then v1, and remembers the answer ("none" = silent device).
snmp_ver() {
    [ "$SNMP_VERSION" = auto ] || { echo "$SNMP_VERSION"; return; }
    local v found=none
    v=$(awk -v i="$1" '$1 == i {print $2; exit}' "$SNMP_CACHE")
    if [ -n "$v" ]; then echo "$v"; return; fi
    for v in 2c 1; do
        if snmpget -v"$v" -c "$SNMP_COMMUNITY" -t "$SNMP_TIMEOUT" -r 0 -m '' -Oqv "$1" .1.3.6.1.2.1.1.1.0 >/dev/null 2>&1 </dev/null; then found=$v; break; fi
    done
    echo "$1 $found" >> "$SNMP_CACHE"
    echo "$found"
}
snmp_get() {   # <ip> <oid> -> value (empty if no answer / no such object)
    local v; v=$(snmp_ver "$1"); [ "$v" = none ] && return 1
    snmpget -v"$v" -c "$SNMP_COMMUNITY" -t "$SNMP_TIMEOUT" -r 0 -m '' -Oqv "$1" "$2" 2>/dev/null </dev/null         | head -1 | sed 's/^"//; s/"$//' | grep -viE '^(no such|error|timeout|end of mib)' | grep .
}
snmp_ident() { # <ip> -> "sysName - sysDescr" (fails if the device does not answer)
    local d n
    d=$(snmp_get "$1" .1.3.6.1.2.1.1.1.0)
    [ -n "$d" ] || return 1
    n=$(snmp_get "$1" .1.3.6.1.2.1.1.5.0)
    echo "${n:-?} - ${d:0:70}"
}
mac_oid() {    # aa:bb:cc:dd:ee:ff -> 170.187.204.221.238.255
    local IFS=:; set -- $1
    [ $# -eq 6 ] || return 1
    printf '%d.%d.%d.%d.%d.%d' "0x$1" "0x$2" "0x$3" "0x$4" "0x$5" "0x$6"
}
snmp_fdb_port() {  # <ip> <mac> -> "port N (ifName)" where the device learned that MAC
    local oid port ifx nm
    oid=$(mac_oid "$2") || return 1
    port=$(snmp_get "$1" ".1.3.6.1.2.1.17.4.3.1.2.$oid")                 # BRIDGE-MIB
    if [ -z "$port" ]; then                                                # Q-BRIDGE (per VLAN)
        port=$(snmpwalk -v"$(snmp_ver "$1")" -c "$SNMP_COMMUNITY" -t "$SNMP_TIMEOUT" -r 0 -m '' -On -Oq "$1" .1.3.6.1.2.1.17.7.1.2.2.1.2 2>/dev/null </dev/null             | awk -v o=".$oid" '{ if (length($1) > length(o) && substr($1, length($1) - length(o) + 1) == o) {print $2; exit} }')
    fi
    case "$port" in ""|0|*[!0-9]*) return 1 ;; esac
    ifx=$(snmp_get "$1" ".1.3.6.1.2.1.17.1.4.1.2.$port")
    if [ -n "$ifx" ]; then
        nm=$(snmp_get "$1" ".1.3.6.1.2.1.31.1.1.1.1.$ifx") || nm=$(snmp_get "$1" ".1.3.6.1.2.1.2.2.1.2.$ifx")
    fi
    echo "port $port${nm:+ ($nm)}"
}
# snmp_l2_info <device ip> <mac A> <name A> <mac B> <name B>
snmp_l2_info() {
    snmp_on || return 0
    local ip=$1 id pa='' pb=''
    [ -n "$ip" ] || return 0
    id=$(snmp_ident "$ip") || { echo "        snmp: no answer from $ip"; return 0; }
    echo "        snmp: $id"
    [ -n "$2" ] && pa=$(snmp_fdb_port "$ip" "$2")
    [ -n "$4" ] && pb=$(snmp_fdb_port "$ip" "$4")
    [ -n "$pa$pb" ] && echo "        learned MACs: ${pa:+$3 on $pa}${pa:+${pb:+; }}${pb:+$5 on $pb}"
    return 0
}

is_wifi()  { printf '%s\n' "${H_WIFI[$1]}" | awk -v d="$2" '$1==d {f=1} END {exit !f}'; }
wifi_sig() { printf '%s\n' "${H_WIFI[$1]}" | awk -v d="$2" '$1==d {print $2; exit}'; }
# neigh_of <hop> <dev> <other hop>: "ip mac name" of neighbours, minus the two hops themselves
neigh_of() {
    printf '%s\n' "${H_NEIGH[$1]}" | awk -v d="$2" -v a="${H_IP[$1]}" -v b="${H_IP[$3]}" \
        'NF && $1==d && $2!=a && $2!=b {print $2, $3, $4}'
}
# print_ap <hop before> <hop after> <steps so far>; prints nothing unless a Wi-Fi segment is involved
print_ap() {
    local a=$1 b=$2 ad=${H_ODEV[$1]} bd=${H_IDEV[$2]} A='' B='' CAND='' wa='' wb='' how='' sa sb nm
    [ -n "$ad" ] && is_wifi "$a" "$ad" && wa=1
    [ -n "$bd" ] && is_wifi "$b" "$bd" && wb=1
    [ -z "$wa$wb" ] && return
    [ -n "$wa" ] && A=$(neigh_of "$a" "$ad" "$b")
    [ -n "$wb" ] && B=$(neigh_of "$b" "$bd" "$a")
    if [ -n "$A" ] && [ -n "$B" ]; then
        CAND=$(awk 'NR==FNR {m[$2]; next} ($2 in m)' <(echo "$A") <(echo "$B"))
    else
        CAND=$(printf '%s\n%s\n' "$A" "$B" | awk 'NF && !s[$2]++')
        how="seen from one side only, unconfirmed"
    fi
    sa=$(wifi_sig "$a" "$ad"); sb=$(wifi_sig "$b" "$bd")
    echo "      |"
    echo "      v"
    if [ -z "$CAND" ]; then
        echo "  [$(($3 + 1))] Wi-Fi access point  (not identified)  [layer 2]"
    elif [ "$(echo "$CAND" | wc -l)" -eq 1 ]; then
        read -r ip mac nm <<< "$CAND"
        [ -z "$nm" ] && nm=$(printf '%s
%s
' "$A" "$B" | awk -v i="$ip" '$1==i && $3 {print $3; exit}')
        echo "  [$(($3 + 1))] ${nm:+$nm  }$ip  [Wi-Fi access point / layer 2]"
        echo "        mac $mac${how:+  ($how)}"
        snmp_l2_info "$ip" "${H_OMAC[$a]}" "${H_NAME[$a]:-${H_IP[$a]}}" "${H_IMAC[$b]}" "${H_NAME[$b]:-${H_IP[$b]}}"
    else
        echo "  [$(($3 + 1))] Wi-Fi access point  [layer 2]  (candidates: ${how:-in both neighbour tables})"
        while read -r ip mac nm; do
            [ -z "$nm" ] && nm=$(printf '%s
%s
' "$A" "$B" | awk -v i="$ip" '$1==i && $3 {print $3; exit}')
            echo "        ${nm:+$nm  }$ip  mac $mac"
            snmp_l2_info "$ip" "${H_OMAC[$a]}" "${H_NAME[$a]:-${H_IP[$a]}}" "${H_IMAC[$b]}" "${H_NAME[$b]:-${H_IP[$b]}}"
        done <<< "$CAND"
    fi
    echo "        link: ${H_NAME[$a]:-${H_IP[$a]}} $ad${sa:+ ${sa} dBm}  <->  ${H_NAME[$b]:-${H_IP[$b]}} $bd${sb:+ ${sb} dBm}"
}

# Interfaces on hop <hop> to look at for LLDP: the bridge port we know traffic
# uses (from the fdb), else all ports of the bridge, else the interface itself.
side_ifaces() {   # <hop> <dev> <known port or empty>
    local ports
    [ -n "$3" ] && { echo "$3"; return; }
    ports=$(printf '%s\n' "${H_BRIDGE[$1]}" | awk -v d="$2" '$1==d && $1==$2 {print $3}' | tr ',' ' ')
    echo "${ports:-$2}"
}
# lldp_nb <hop> <ifaces> <hop A> <hop B>
# -> "name|ip|mac|port" per neighbour, minus the two hops that are in the trace themselves
lldp_nb() {
    printf '%s\n' "${H_LLDP[$1]}" | awk -v want=" $2 " -v ia="${H_IP[$3]}" -v ib="${H_IP[$4]}" \
        -v na="${H_NAME[$3]}" -v nb="${H_NAME[$4]}" '
        NF >= 3 { i=$1; k=$2; v=$0; sub(/^[^ ]+ [^ ]+ /, "", v); r[i,k]=v; seen[i]=1 }
        END {
            for (i in seen) {
                if (index(want, " " i " ") == 0) continue
                n=r[i,"name"]; a=r[i,"ip"]; m=r[i,"mac"]; p=r[i,"port"]; if (p=="") p=r[i,"pdesc"]
                if ((a!="" && (a==ia || a==ib)) || (n!="" && (tolower(n)==tolower(na) || tolower(n)==tolower(nb)))) continue
                print n "|" a "|" m "|" p
            }
        }'
}
# sniff_nb <hop> <ifaces> <hop A> <hop B>: same output as lldp_nb, from frames heard
# with SNIFF=1 ("dev|type|src mac|f1|f2|f3"; type lldp/cdp/stp). The 5th field names the source.
sniff_nb() {
    printf '%s
' "${H_SNIFF[$1]}" | awk -F'|' -v want=" $2 " -v ia="${H_IP[$3]}" -v ib="${H_IP[$4]}"         -v na="${H_NAME[$3]}" -v nb="${H_NAME[$4]}" '
        NF >= 6 && index(want, " " $1 " ") {
            t=$2; mac=$3; n=$4; p=$5; a=$6; kind=""
            if (t == "stp") { kind = "STP bridge (heard)"; b = $4; sub(/\.[0-9a-f]+$/, "", b); p = (b == $5 ? "root bridge" : "root " $5); n = "STP bridge " b }
            else kind = toupper(t) " neighbour (heard)"
            if (a == "-") a = ""
            if (n == "-") n = ""
            if (p == "-") p = ""
            if ((a != "" && (a == ia || a == ib)) || (n != "" && (tolower(n) == tolower(na) || tolower(n) == tolower(nb)))) next
            print n "|" a "|" mac "|" p "|" kind
        }'
}
# print_lldp <hop before> <hop after> <steps so far>: switches/bridges announced via LLDP
print_lldp() {
    local a=$1 b=$2 base=$3 A B ALL k=0 nm ip mac port ifs lbl
    ifs=$(side_ifaces "$a" "${H_ODEV[$a]}" "${H_EGR[$a]}")
    A=$(lldp_nb "$a" "$ifs" "$a" "$b"; sniff_nb "$a" "$ifs" "$a" "$b")
    ifs=$(side_ifaces "$b" "${H_IDEV[$b]}" "${H_ING[$b]}")
    B=$(lldp_nb "$b" "$ifs" "$a" "$b"; sniff_nb "$b" "$ifs" "$a" "$b")
    # the same box seen from both ends is one step (match on MAC, else name)
    ALL=$(printf '%s\n%s\n' "$A" "$B" | awk -F'|' 'NF && !s[($3 != "" ? $3 : $1)]++')
    [ -z "$ALL" ] && return
    while IFS='|' read -r nm ip mac port kind; do
        k=$((k + 1))
        lbl="${nm}${nm:+${ip:+  }}${ip}"; [ -z "$lbl" ] && lbl="(unnamed)"
        echo "      |"
        echo "      v"
        echo "  [$((base + k))] $lbl  [${kind:-LLDP neighbour} / layer 2]"
        [ -n "$mac$port" ] && echo "        ${mac:+mac $mac  }${port:+port $port}"
        snmp_l2_info "$ip" "${H_OMAC[$a]}" "${H_NAME[$a]:-${H_IP[$a]}}" "${H_IMAC[$b]}" "${H_NAME[$b]:-${H_IP[$b]}}"
    done <<< "$ALL"
}
# bridge_info <hop>: bridge ports, MACs learned per port, and the in/out port
bridge_info() {
    local n=$1 seen=" " dev br ports learned
    while read -r dev br ports; do
        [ -z "$br" ] && continue
        case "$seen" in *" $br "*) continue ;; esac
        seen="$seen$br "
        ports=${ports//,/ }
        echo "        bridge: $br  ports: ${ports% }"
        learned=$(printf '%s\n' "${H_FDB[$n]}" | awk -v b="$br" '$1==b {c[$2]++} END {for (p in c) printf "%s(%d) ", p, c[p]}')
        [ -n "$learned" ] && echo "        learned MACs: ${learned% }"
    done <<< "${H_BRIDGE[$n]}"
    if [ -n "${H_ING[$n]}${H_EGR[$n]}" ]; then
        echo "        L2 path: in via port ${H_ING[$n]:-?}, out via port ${H_EGR[$n]:-?}"
    fi
}

echo "  $(hostname 2>/dev/null || echo localhost)  (this machine)"
STEP=0
for n in $(seq 1 "$HOP_NUM"); do
    if [ "$n" -gt 1 ]; then
        APOUT=$(print_ap $((n - 1)) "$n" "$STEP")
        if [ -n "$APOUT" ]; then printf '%s
' "$APOUT"; STEP=$((STEP + 1)); fi
        LLOUT=$(print_lldp $((n - 1)) "$n" "$STEP")
        if [ -n "$LLOUT" ]; then
            printf '%s
' "$LLOUT"
            STEP=$((STEP + $(printf '%s
' "$LLOUT" | grep -c '^  \[')))
        fi
    fi
    STEP=$((STEP + 1))
    echo "      |   ${H_RTT[n]:+rtt ${H_RTT[n]}}"
    echo "      v"
    LABEL="${H_NAME[n]:+${H_NAME[n]}  }${H_IP[n]}"
    [ -n "${H_OS[n]}" ] && LABEL="$LABEL  [${H_OS[n]}]"
    [ "${H_IP[n]}" = "$TARGET" ] && LABEL="$LABEL  <== TARGET"
    echo "  [$STEP] $LABEL"
    [ -n "${H_IN[n]}" ]   && echo "        in : ${H_IN[n]}"
    [ -n "${H_OUT[n]}" ]  && echo "        out: ${H_OUT[n]}"
    [ -n "${H_BRIDGE[n]}" ] && bridge_info "$n"
    [ -n "${H_PROM[n]}" ]   && echo "        promiscuous: ${H_PROM[n]% }  (bridge port or capture running)"
    if snmp_on; then
        SID=$(snmp_ident "${H_IP[n]}") && echo "        snmp: $SID" || echo "        snmp: no answer"
    fi
    [ -n "${H_NOTE[n]}" ] && echo "        note: ${H_NOTE[n]}"
done
if [[ "$TARGET" =~ ^[0-9.]+$ ]] && [ "${H_IP[HOP_NUM]}" != "$TARGET" ]; then
    echo "      |"
    echo "      v"
    echo "  [?] $TARGET  (not reached by the local trace)"
fi
echo "========================================================"
