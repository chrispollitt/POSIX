<#
.SYNOPSIS
  Open BiglyBT's listen port range (n to n+9) with UPnP, then start BiglyBT.

.DESCRIPTION
  1. Reads the port from %APPDATA%\BiglyBT\java.vmoptions (first line that looks like "...port...=NNNN",
     or override with -Port).
  2. Asks the router (cpbee's miniupnpd, which passes it on to cmrouter) to forward that port, TCP and UDP,
     to this PC.  Uses upnpc.exe (miniupnpc) if it is on PATH, otherwise Windows' built-in UPnP COM object
     (HNetCfg.NATUPnP), so nothing needs installing.
  2b. Windows Firewall: allows ports n..n+9 (TCP + UDP, inbound) and BiglyBT.exe itself (all ports, Private + Public),
      and deletes any Block rules for BiglyBT (left by a cancelled "allow?" pop-up).  A UAC prompt appears when a rule
      is missing; -FixFirewall forces the step.
  3. Starts BiglyBT.exe.  With -CleanupOnExit it waits for BiglyBT to quit and removes the mappings.

  Run:   powershell -ExecutionPolicy Bypass -File .\biglybt-launch.ps1
  Check: on cpbee, `lan-port upnp` lists the mapping and who asked for it.

.PARAMETER Port           Use this port instead of reading java.vmoptions.
.PARAMETER VmOptions      Path of java.vmoptions.
.PARAMETER Exe            Path of BiglyBT.exe.
.PARAMETER CleanupOnExit  Wait for BiglyBT to exit, then delete the mappings.
#>
[CmdletBinding()]
param(
    [int]    $Port,
    [string] $VmOptions = (Join-Path $env:APPDATA 'BiglyBT\java.vmoptions'),
    [string] $Exe       = 'C:\Program Files\BiglyBT\BiglyBT.exe',
    [string] $DescUrl,      # router's UPnP description URL, e.g. http://192.168.10.1:5000/rootDesc.xml (skips discovery)
    [switch] $CleanupOnExit,
    [switch] $NoFirewall,   # don't touch the Windows firewall
    [switch] $FixFirewall   # re-do the firewall step even if the rules exist: clears Block rules for BiglyBT
)

$ErrorActionPreference = 'Stop'
$Desc   = 'BiglyBT'
$Protos = 'TCP', 'UDP'

function Say($m) { Write-Host "biglybt-launch: $m" }

# --- 1. the port ------------------------------------------------------------------------------------------
if (-not $Port) {
    if (-not (Test-Path -LiteralPath $VmOptions)) { throw "$VmOptions not found (give -Port NNNN)" }
    foreach ($line in Get-Content -LiteralPath $VmOptions) {
        $l = ($line -replace '#.*$', '').Trim()
        if ($l -match '(?i)port[^=\s]*\s*=\s*(\d{2,5})\b') { $Port = [int]$Matches[1]; Say "port $Port from: $l"; break }
    }
    if (-not $Port) { throw "no 'port=NNNN' line in $VmOptions (give -Port NNNN)" }
}
if ($Port -lt 1 -or $Port -gt 65535) { throw "bad port $Port" }
$Last = $Port + 9                       # BiglyBT gets the range n .. n+9
if ($Last -gt 65535) { throw "port range $Port-$Last runs past 65535" }
Say "port range $Port-$Last"

# --- 2. this PC's LAN address: the interface that holds the default route (many virtual adapters here) ----
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
if (-not $route) { throw 'no default route: not on a network' }
$ip = (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
if (-not $ip) { throw "no IPv4 address on interface $($route.ifIndex)" }
Say "this PC is $ip, gateway $($route.NextHop)"

# --- 2b. Windows Firewall.  Two things are needed (found with test-upnp.sh):
#         - an Allow rule for the port range (TCP + UDP), and
#         - an Allow rule for BiglyBT.exe itself (all ports, Private + Public networks), with any *Block* rules for
#           BiglyBT removed: Windows leaves a Block rule behind when its "allow BiglyBT?" pop-up is cancelled, and a
#           Block rule beats every Allow rule.
#         Changing rules needs administrator: if this window isn't elevated only that step is run elevated (one UAC
#         prompt), and only when a rule is missing or -FixFirewall is given (Block rules can't be seen unelevated).
if (-not $NoFirewall) {
    $rule  = "BiglyBT listen port $Port-$Last"
    $prule = 'BiglyBT program (biglybt-launch)'
    $have  = Get-NetFirewallRule -DisplayName $rule  -ErrorAction SilentlyContinue
    $haveP = Get-NetFirewallRule -DisplayName $prule -ErrorAction SilentlyContinue
    $stale = Get-NetFirewallRule -DisplayName 'BiglyBT listen port *' -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -ne $rule }          # left over from an earlier port number
    if ($have -and $haveP -and -not $stale -and -not $FixFirewall) {
        Say "firewall: '$rule' and '$prule' already present (use -FixFirewall to clear Block rules and recreate them)"
    } else {
        $log = Join-Path $env:TEMP 'biglybt-launch-firewall.log'
        Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
        $cmd = @'
$ErrorActionPreference = 'Stop'
$log = '@LOG@'
function L($m) { Add-Content -LiteralPath $log -Value $m }
$dir = Split-Path -Parent '@EXE@'
# 1. old port-range rules and our own program rule (recreated below)
Get-NetFirewallRule -DisplayName 'BiglyBT listen port *' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -ne '@RULE@' } | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName '@PRULE@' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
# 2. Block rules for BiglyBT (its folder, or a BiglyBT*.exe anywhere)
Get-NetFirewallApplicationFilter | Where-Object { $_.Program -like "$dir\*" -or $_.Program -like '*\BiglyBT.exe' -or $_.Program -like '*\BiglyBTTor.exe' } |
  Get-NetFirewallRule | Where-Object { $_.Action -eq 'Block' } |
  ForEach-Object { L ("removed Block rule: {0} ({1})" -f $_.DisplayName, $_.Direction); $_ | Remove-NetFirewallRule }
# 3. the port range
if (-not (Get-NetFirewallRule -DisplayName '@RULE@' -ErrorAction SilentlyContinue)) {
  foreach ($p in 'TCP','UDP') { New-NetFirewallRule -DisplayName '@RULE@' -Direction Inbound -Action Allow -Protocol $p -LocalPort '@PORTS@' -Profile Any | Out-Null }
  L 'port-range rule created'
}
# 4. the program, all ports, Private + Public
New-NetFirewallRule -DisplayName '@PRULE@' -Direction Inbound -Action Allow -Program '@EXE@' -Protocol Any -Profile Private,Public | Out-Null
L 'program rule created'
'@
        $cmd = $cmd.Replace('@LOG@', $log).Replace('@EXE@', $Exe).Replace('@RULE@', $rule).Replace('@PRULE@', $prule).Replace('@PORTS@', "$Port-$Last")
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                 ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        try {
            if ($admin) { & ([scriptblock]::Create($cmd)) }
            else {
                $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
                $pr = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
                      -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
                if ($pr.ExitCode -ne 0) { throw "elevated step exited $($pr.ExitCode)" }
            }
            if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { Say "firewall: $_" } }
            if ((Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue) -and
                (Get-NetFirewallRule -DisplayName $prule -ErrorAction SilentlyContinue)) {
                Say "firewall: $Port-$Last TCP+UDP and $Exe (all ports, Private+Public) allowed inbound"
            } else { Say 'WARNING: firewall rules were not created' }
        } catch { Say "WARNING: could not open the Windows firewall: $($_.Exception.Message)" }
    }
}

# --- 3. ask the router to forward it ----------------------------------------------------------------------
$upnpc = Get-Command upnpc.exe -ErrorAction SilentlyContinue
$added = @()

function Upnpc([string[]]$a) {
    # native stderr must not trip $ErrorActionPreference = 'Stop'
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { (& $upnpc.Source @a 2>&1 | ForEach-Object { "$_" }) -join "`n" } finally { $ErrorActionPreference = $old }
}

if ($upnpc) {
    # Multicast discovery picks the wrong adapter on a PC with many virtual ones: bind it to our LAN address (-m),
    # and if the router still isn't found, go straight to its description URL (miniupnpd: gateway:5000/rootDesc.xml).
    $base = @('-m', $ip)
    if ($DescUrl) { $base = @('-u', $DescUrl) }
    elseif ((Upnpc ($base + '-l')) -notmatch 'Found valid IGD') {
        $base = @('-u', "http://$($route.NextHop):5000/rootDesc.xml")
        Say "SSDP found nothing, trying $($base[1])"
    }
    if ((Upnpc ($base + '-l')) -notmatch 'Found valid IGD') {
        Say 'WARNING: no UPnP router answered.  Starting BiglyBT anyway.'
    } else {
        foreach ($n in $Port..$Last) { foreach ($p in $Protos) {
            [void](Upnpc ($base + @('-e', $Desc, '-a', $ip, "$n", "$n", $p)))
            # some routers answer the post-add check with an error although the mapping exists; judge by the list
            $listed = (Upnpc ($base + '-l')) -split "`n" | Where-Object { $_ -match "\b$p\s+$n->$([regex]::Escape($ip)):" }
            if ($listed) { Say "$n/$p forwarded to $ip (upnpc)"; $added += ,@($n, $p) } else { Say "WARNING: $n/$p not in the router's list" }
        } }
    }
} else {
    try {
        $nat = New-Object -ComObject HNetCfg.NATUPnP
        $map = $nat.StaticPortMappingCollection
    } catch { $map = $null }
    if (-not $map) {
        Say 'WARNING: no UPnP router answered (UPnP discovery blocked, or off on the router).  Starting BiglyBT anyway.'
    } else {
        foreach ($n in $Port..$Last) { foreach ($p in $Protos) {
            try {
                foreach ($m in @($map)) {                       # drop a stale mapping for the same port (e.g. another PC)
                    if ($m.ExternalPort -eq $n -and $m.Protocol -eq $p) { $map.Remove($n, $p); break }
                }
                [void]$map.Add($n, $p, $n, $ip, $true, $Desc)
                Say "$n/$p forwarded to $ip (Windows UPnP)"; $added += ,@($n, $p)
            } catch { Say "WARNING: router refused $n/${p}: $($_.Exception.Message)" }
        } }
    }
}

# --- 4. start BiglyBT -------------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Exe)) { throw "$Exe not found" }
if ($CleanupOnExit) {
    Say 'starting BiglyBT, will remove the mappings when it exits'
    Start-Process -FilePath $Exe -Wait
    foreach ($a in $added) {
        $n = $a[0]; $p = $a[1]
        try {
            if ($upnpc) { [void](Upnpc ($base + @('-d', "$n", $p))) } else { $map.Remove($n, $p) }
            Say "removed $n/$p"
        } catch { Say "could not remove $n/${p}: $($_.Exception.Message)" }
    }
} else {
    Start-Process -FilePath $Exe
}
