#!/bin/bash
# test-upnp.sh - end-to-end test of the UPnP port forward chain, run from cmlaptop:
#
#   cmlaptop --UPnP--> cpbee (miniupnpd) --UPnP--> cmrouter --> internet <-- phone (adb, mobile data)
#
# 0. needs administrator rights: if the shell isn't elevated it re-runs itself in an elevated window (one UAC prompt)
# 1. fixes the local Windows firewall for nc.exe: deletes every existing nc.exe rule (Windows leaves Block rules
#    behind when its "allow nc.exe?" pop-up is cancelled, and a Block rule beats any Allow rule), then adds one
#    inbound Allow rule for nc.exe, all ports, Private + Public networks.  That rule is left in place.
# 2. asks cpbee to forward PORT (TCP) to this PC
# 3. checks the mapping shows up on cpbee, and was passed on to cmrouter (via cpbee's WAN-side address)
# 4. listens on PORT here and checks it is reachable from the LAN (cpbee connects to it: tests the firewall)
# 5. connects from the phone to the public address and checks the data arrived
# 6. removes the UPnP mapping again (always, even on error / ctrl-C)
#
# On a failed step it prints diagnostics (listener, firewall, LAN reachability, phone network, ...).
#
# Usage: test-upnp.sh [-p port] [-P public-ip] [-n] [-F] [-h]
#   -p port       port to test (default 16880)
#   -P public-ip  public address to connect to from the phone (default: ask the routers)
#   -n            skip the phone test (check the mappings and LAN reachability only)
#   -F            don't touch the Windows firewall (then administrator rights are not needed either)
#
# Exit status: 0 = every check passed, 1 = something failed, 2 = bad usage / missing tool.
# Note: stop BiglyBT (or pick another port with -p) if it is already listening on PORT.

addr1=192.168.10.73   # cmlaptop
addr2=192.168.10.1    # cpbee
addr3=192.168.1.68    # cpbee's address on cmrouter's LAN
addr4=192.168.1.254   # cmrouter (web page shows the WAN address)
addr5=209.121.12.33   # public address, fallback if the routers won't tell us
port=16870            # port to test
phone=1               # test from phone
firewall=1            # open local firewall
lease=600             # seconds; the mapping expires by itself if we crash

orig_args=("$@")
while getopts p:P:nFh o; do
    case $o in
        p) port=$OPTARG ;;
        P) addr5=$OPTARG; given_pub=1 ;;
        n) phone=0 ;;
        F) firewall=0 ;;
        h) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "usage: ${0##*/} [-p port] [-P public-ip] [-n] [-F]" >&2; exit 2 ;;
    esac
done
case $port in ''|*[!0-9]*) echo "bad port: $port" >&2; exit 2 ;; esac
[ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || { echo "port must be 1024-65535" >&2; exit 2; }

fail=0
pass() { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fail=1; }
info() { echo "----  $*"; }
diag() { echo "diag: $*"; }
indent() { sed 's/^/        /'; }

for t in upnpc nc ssh; do
    command -v $t >/dev/null || { echo "missing tool: $t" >&2; exit 2; }
done
if [ $phone = 1 ] && ! command -v adb >/dev/null; then
    info "adb not found: skipping the phone test"; phone=0
fi
if [ $firewall = 1 ] && ! command -v powershell.exe >/dev/null; then
    info "powershell.exe not found: not touching the Windows firewall"; firewall=0
fi

# --- administrator rights (needed to edit the Windows firewall) -------------------------------------------------
is_admin() { net session >/dev/null 2>&1; }

if [ $firewall = 1 ] && ! is_admin; then
    if [ -n "$TEST_UPNP_ELEVATED" ]; then
        echo "still not administrator after elevating: giving up (use -F to skip the firewall step)" >&2; exit 2
    fi
    info "not running as administrator: re-running in an elevated window (accept the UAC prompt)"
    wrapper=$(mktemp /tmp/test-upnp-elevated.XXXXXX) || exit 2
    {
        echo "export TEST_UPNP_ELEVATED=1"
        printf 'cd %q\n' "$PWD"
        printf '%q' "$(readlink -f "$0")"; printf ' %q' "${orig_args[@]}"; echo
        echo 'rc=$?'
        echo 'echo; read -r -p "test-upnp finished (exit $rc). Press Enter to close. "'
        echo "rm -f $(printf '%q' "$wrapper")"
    } > "$wrapper"
    bashw=$(cygpath -w /bin/bash.exe)
    wrapw=$(cygpath -u "$wrapper")
    powershell.exe -NoProfile -NonInteractive -Command \
        "Start-Process -Verb RunAs -FilePath '$bashw' -ArgumentList '-l','$wrapw'" 2>&1 | tr -d '\r'
    echo "The test is running in the elevated window; its result is shown there."
    exit 0
fi

# --- Windows firewall helpers ---------------------------------------------------------------------------------
ps() { powershell.exe -NoProfile -NonInteractive -Command "$1" 2>&1 | tr -d '\r'; }

ncpath=$(readlink -f "$(command -v nc)")          # Cygwin resolves /usr/bin/nc to /usr/bin/nc.exe
[ -f "$ncpath" ] || ncpath=$ncpath.exe
ncwin=$(cygpath -w "$ncpath")
case $ncwin in *.[eE][xX][eE]) ;; *) ncwin=$ncwin.exe ;; esac   # the rule needs the real .exe path; a wrong path matches nothing and Windows shows its pop-up
[ -f "$ncpath" ] || [ "$firewall" = 0 ] || { echo "cannot find nc.exe (looked for $ncwin)" >&2; exit 2; }
rule="nc.exe (test-upnp)"

fw_open() {
    info "firewall: removing every existing nc.exe rule"
    ps "
        \$ErrorActionPreference = 'SilentlyContinue'
        \$byProg = Get-NetFirewallApplicationFilter | Where-Object { \$_.Program -like '*\nc.exe' } | Get-NetFirewallRule
        \$byName = Get-NetFirewallRule | Where-Object { \$_.DisplayName -match '^(nc|nc\.exe)( |\$)' -or \$_.DisplayName -like 'test-upnp*' -or \$_.DisplayName -eq '$rule' }
        \$all = @(\$byProg) + @(\$byName) | Sort-Object -Property Name -Unique
        foreach (\$r in \$all) { '  deleted: {0} ({1}, {2})' -f \$r.DisplayName, \$r.Direction, \$r.Action; \$r | Remove-NetFirewallRule }
        if (-not \$all) { '  (none found)' }
    "
    ps "New-NetFirewallRule -DisplayName '$rule' -Direction Inbound -Action Allow -Program '$ncwin' -Protocol Any -Profile Private,Public | Out-Null"
    n=$(ps "@(Get-NetFirewallRule -DisplayName '$rule' -ErrorAction SilentlyContinue | Where-Object { \$_.Enabled -eq 'True' -and \$_.Action -eq 'Allow' }).Count")
    if [ "$n" = 1 ]; then pass "Windows firewall: $ncwin may accept connections on all ports (Private + Public networks)"
    else bad "could not create the firewall rule for $ncwin"; echo "$n" | indent; fi
}

tmp=$(mktemp -d) || exit 2
server_pid=
mapped=0
r1desc=http://$addr2:5000/rootDesc.xml   # cpbee's miniupnpd; skips SSDP discovery (many virtual adapters here)

cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
    if [ $mapped = 1 ]; then
        upnpc -u "$r1desc" -d "$port" TCP >/dev/null 2>&1 && info "mapping $port/TCP removed" \
            || info "WARNING: could not remove $port/TCP on cpbee (it expires in ${lease}s)"
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- 0. is the port free here? --------------------------------------------------------------------------------
listening() { netstat -an 2>/dev/null | grep -Ei "[:.]$port[[:space:]].*LISTEN"; }
if listening >/dev/null; then
    echo "port $port is already in use on this PC (BiglyBT?).  Stop it or use -p." >&2
    listening | indent >&2
    exit 2
fi

# --- 1. firewall ----------------------------------------------------------------------------------------------
[ $firewall = 1 ] && fw_open

# --- 2. can we reach cpbee's UPnP at all? ---------------------------------------------------------------------
list1=$(upnpc -u "$r1desc" -l 2>&1)
if ! echo "$list1" | grep -q 'Found valid IGD'; then
    echo "$list1" | tail -5 | indent
    diag "ping to cpbee:"; ping -n 2 "$addr2" 2>&1 | tail -3 | indent
    echo "cpbee's UPnP ($r1desc) did not answer" >&2
    exit 1
fi
pass "cpbee UPnP answers"

# --- 3. add the mapping ---------------------------------------------------------------------------------------
if out=$(upnpc -u "$r1desc" -e test-upnp -a "$addr1" "$port" "$port" TCP "$lease" 2>&1); then
    :
else
    # some routers report an error although the mapping exists: judge by the list below
    info "upnpc -a reported an error (judging by the list instead):"; echo "$out" | tail -3 | indent
fi
mapped=1

# is it on cpbee?
list1=$(upnpc -u "$r1desc" -l 2>&1)
if echo "$list1" | grep -E "TCP +$port->$addr1:$port" >/dev/null; then
    pass "cpbee lists $port/TCP -> $addr1"  # allowlist secret
else
    bad "cpbee does not list $port/TCP -> $addr1"
    diag "mappings on cpbee mentioning $port or $addr1:"
    echo "$list1" | grep -E "$port|$addr1|ExternalIP" | indent
    diag "is $addr1 really this PC's address?"; ipconfig 2>/dev/null | tr -d '\r' | grep -E "IPv4" | indent
fi

# did cpbee pass it on to cmrouter? (ask from cpbee, bound to its cmrouter-side address)
list2=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$addr2" "upnpc -m $addr3 -l" 2>&1)
if echo "$list2" | grep -E "TCP +$port->" >/dev/null; then
    pass "cmrouter lists $port/TCP: $(echo "$list2" | grep -E "TCP +$port->" | head -1 | sed 's/^ *[0-9]* *//')"
else
    bad "cmrouter does not list $port/TCP (cpbee's miniupnpd did not forward it, or ssh/upnpc on cpbee failed)"
    diag "output of 'upnpc -m $addr3 -l' on cpbee:"; echo "$list2" | tail -6 | indent
    diag "does cpbee's miniupnpd forward to cmrouter?  look at its log on cpbee"
fi

# --- 4. the public address ------------------------------------------------------------------------------------
if [ -z "$given_pub" ]; then
    # cmrouter's status page carries its WAN address:  var wanEthStatus_IPAddress = htmlDecodeStr('1.2.3.4');
    ext=$(curl -s -m 5 "http://$addr4/" 2>/dev/null | sed -n "/wanEthStatus_IPAddress.*htmlDecodeStr/s/.*htmlDecodeStr('\([0-9.]*\)').*/\1/p" | head -1)
    [ -n "$ext" ] && info "cmrouter's web page gives the WAN address $ext"
    # otherwise ask UPnP
    [ -z "$ext" ] && ext=$(printf '%s\n%s\n' "$list1" "$list2" | sed -n 's/^ExternalIPAddress *= *//p' | tr -d '\r' | head -1)
    case $ext in
        '')   info "no router reported an external address, using $addr5" ;;
        10.*|192.168.*|172.1[6-9].*|172.2?.*|172.3[01].*)
              info "external address $ext is private (double NAT): the forward will not work from outside; using $addr5" ;;
        100.6[4-9].*|100.[7-9]?.*|100.1[01]?.*|100.12[0-7].*)
              info "external address $ext is carrier-grade NAT: inbound will not work from outside; using $addr5" ;;
        *)    addr5=$ext; info "router says the public address is $ext" ;;
    esac
fi
info "public address used: $addr5"

# --- 5. a listener here, and is it reachable from the LAN? ----------------------------------------------------
if nc -h 2>&1 | grep -q -- '-46'; then listen="nc -k -l $port"; else listen="nc -l -p $port"; fi
: > "$tmp/server.log"
$listen > "$tmp/server.log" 2> "$tmp/server.err" &
server_pid=$!
sleep 1
if ! kill -0 "$server_pid" 2>/dev/null; then
    bad "listener '$listen' died at once"; indent < "$tmp/server.err"
    server_pid=
elif ! listening >/dev/null; then
    bad "listener '$listen' is running but $port is not in netstat's LISTEN list"
else
    pass "listening on $port here ($listen)"
    # cpbee connecting to this PC's LAN address goes through the Windows firewall
    lan=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$addr2" "nc -zv -w 3 $addr1 $port" 2>&1)
    if echo "$lan" | grep -Eiq 'succeeded|open|connected'; then
        pass "cpbee can connect to $addr1:$port (LAN path and Windows firewall are fine)"  # allowlist secret
    else
        bad "cpbee cannot connect to $addr1:$port: the Windows firewall (or a security product) is blocking it"
        echo "$lan" | indent
        diag "firewall state:"; ps "Get-NetFirewallProfile | Select Name,Enabled | Format-Table -HideTableHeaders" | indent
        diag "rules for this port:"
        ps "Get-NetFirewallPortFilter -Protocol TCP | Where-Object { \$_.LocalPort -eq '$port' } | Get-NetFirewallRule | Select DisplayName,Enabled,Direction,Action | Format-Table -HideTableHeaders -AutoSize" | indent
        diag "inbound Block rules for the listener program (a Block rule beats any Allow rule; usually left by clicking Cancel on Windows' 'allow nc.exe?' prompt):"
        ps "Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True | ForEach-Object { \$a = (\$_ | Get-NetFirewallApplicationFilter).Program; if (\$a -like '*\\nc.exe' -or \$a -eq 'Any') { '{0} | {1}' -f \$_.DisplayName, \$a } }" | indent
        diag "to remove them (elevated PowerShell): Get-NetFirewallRule -DisplayName 'nc' -Action Block | Remove-NetFirewallRule   (listener is $ncwin)"
    fi
fi

# --- 6. real traffic from outside -----------------------------------------------------------------------------
if [ $phone = 1 ]; then
    if [ -z "$(adb devices | sed 1d | grep -w device)" ]; then
        bad "no phone attached to adb (or not authorised)"; adb devices 2>&1 | indent
    else
        adb_out=$(adb shell "echo hello-from-phone | nc -w 5 $addr5 $port; echo nc-exit=\$?" 2>&1 | tr -d '\r')
        for _ in 1 2 3 4 5; do grep -q hello-from-phone "$tmp/server.log" && break; sleep 1; done
        if grep -q hello-from-phone "$tmp/server.log"; then
            pass "phone reached $addr1:$port through $addr5"  # allowlist secret
        else
            bad "nothing arrived from the phone"
            diag "what the phone's nc said:"; echo "$adb_out" | indent
            diag "which network is the phone using? (wlan = wifi: bad, rmnet/ccmni = mobile data: good)"
            adb shell "ip route get 8.8.8.8 2>&1 | head -1" 2>&1 | tr -d '\r' | indent
            diag "the phone's public address (should differ from your home address $addr5):"
            adb shell "(curl -s -m 5 https://api.ipify.org || wget -qO- -T 5 http://api.ipify.org) 2>&1" 2>&1 | tr -d '\r' | head -2 | indent
            diag "listener still up here? $(kill -0 "$server_pid" 2>/dev/null && echo yes || echo NO)"
            listening | indent
            diag "is cmrouter's mapping there, and does the public address match? (hairpin test from cpbee, may not work on all routers):"
            ssh -o BatchMode=yes -o ConnectTimeout=10 "$addr2" "nc -zv -w 3 $addr5 $port" 2>&1 | indent
            diag "hints: wrong public address / double NAT / ISP blocks inbound => a port scanner (e.g. canyouseeme.org) shows the same;"
            diag "        cmrouter's own firewall or a 'cpbee (LAN UPnP)' lease that has expired are the next things to look at."
        fi
    fi
fi

[ $fail = 0 ] && echo "ALL OK" || echo "SOME CHECKS FAILED"
exit $fail

# --- reference ---
# upnpc -e description | -u url (skip discovery) | -m address/interface (SSDP source) | -a ip int ext proto [lease] | -d ext proto | -l list
