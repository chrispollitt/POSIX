<#
.SYNOPSIS
  Open BiglyBT's listen port with UPnP, then start BiglyBT.

.DESCRIPTION
  1. Reads the port from %APPDATA%\BiglyBT\java.vmoptions (first line that looks like "...port...=NNNN",
     or override with -Port).
  2. Asks the router (cpbee's miniupnpd, which passes it on to cmrouter) to forward that port, TCP and UDP,
     to this PC.  Uses upnpc.exe (miniupnpc) if it is on PATH, otherwise Windows' built-in UPnP COM object
     (HNetCfg.NATUPnP), so nothing needs installing.
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
    [switch] $CleanupOnExit
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

# --- 2. this PC's LAN address: the interface that holds the default route (many virtual adapters here) ----
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
if (-not $route) { throw 'no default route: not on a network' }
$ip = (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
if (-not $ip) { throw "no IPv4 address on interface $($route.ifIndex)" }
Say "this PC is $ip, gateway $($route.NextHop)"

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
        foreach ($p in $Protos) {
            [void](Upnpc ($base + @('-e', $Desc, '-a', $ip, "$Port", "$Port", $p)))
            # some routers answer the post-add check with an error although the mapping exists; judge by the list
            $listed = (Upnpc ($base + '-l')) -split "`n" | Where-Object { $_ -match "\b$p\s+$Port->$([regex]::Escape($ip)):" }
            if ($listed) { Say "$Port/$p forwarded to $ip (upnpc)"; $added += $p } else { Say "WARNING: $Port/$p not in the router's list" }
        }
    }
} else {
    try {
        $nat = New-Object -ComObject HNetCfg.NATUPnP
        $map = $nat.StaticPortMappingCollection
    } catch { $map = $null }
    if (-not $map) {
        Say 'WARNING: no UPnP router answered (UPnP discovery blocked, or off on the router).  Starting BiglyBT anyway.'
    } else {
        foreach ($p in $Protos) {
            try {
                foreach ($m in @($map)) {                       # drop a stale mapping for the same port (e.g. another PC)
                    if ($m.ExternalPort -eq $Port -and $m.Protocol -eq $p) { $map.Remove($Port, $p); break }
                }
                [void]$map.Add($Port, $p, $Port, $ip, $true, $Desc)
                Say "$Port/$p forwarded to $ip (Windows UPnP)"; $added += $p
            } catch { Say "WARNING: router refused $Port/${p}: $($_.Exception.Message)" }
        }
    }
}

# --- 4. start BiglyBT -------------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Exe)) { throw "$Exe not found" }
if ($CleanupOnExit) {
    Say 'starting BiglyBT, will remove the mappings when it exits'
    Start-Process -FilePath $Exe -Wait
    foreach ($p in $added) {
        try {
            if ($upnpc) { [void](Upnpc ($base + @('-d', "$Port", $p))) } else { $map.Remove($Port, $p) }
            Say "removed $Port/$p"
        } catch { Say "could not remove $Port/${p}: $($_.Exception.Message)" }
    }
} else {
    Start-Process -FilePath $Exe
}
