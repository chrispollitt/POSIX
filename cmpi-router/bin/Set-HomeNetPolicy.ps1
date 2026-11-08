<#
.SYNOPSIS
  Prepare a Windows PC for a metered home internet link (the cpbee router on a mobile-data plan).

.DESCRIPTION
  a) METERED: marks wired (Ethernet) connections as metered, so Windows defers big automatic downloads (Windows Update,
     Store apps) and apps that respect the flag (OneDrive, Office, ...) go easy on the link.
     This sets the Windows DEFAULT cost for the media type: HKLM\...\NetworkList\DefaultMediaCost, Ethernet = 2.
     It applies to every wired connection on this PC, not only the home network. That registry key is owned by
     TrustedInstaller, so the script takes ownership just long enough to write the value, then restores the original
     owner and permissions.
  b) LAN UPDATES: turns on Delivery Optimization peer sharing limited to the local network (DODownloadMode = 1) and to
     the local subnet (DORestrictPeerSelectionBy = 1), so a Windows update downloaded once over the metered link can be
     fetched by the other PCs from that PC instead of from the internet again.

  Originals are saved in %ProgramData%\HomeNetPolicy\backup.json the first time, and -Undo restores them.

.PARAMETER Status         Read-only report of the current state. Needs no administrator rights.
.PARAMETER Undo           Restore the settings that were in place before the first run.
.PARAMETER MeteredOnly    Only part (a).
.PARAMETER UpdatesOnly    Only part (b).
.PARAMETER Wifi           Also mark Wi-Fi connections as metered (default: Ethernet only).
.PARAMETER Reconnect      Restart the physical network adapters afterwards so the new cost applies immediately
                          (drops the connection for a few seconds; otherwise it applies at the next reconnect or reboot).
.PARAMETER WhatIf         Show what would change without changing anything.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Set-HomeNetPolicy.ps1 -Status
  powershell -ExecutionPolicy Bypass -File .\Set-HomeNetPolicy.ps1            # apply both (asks for elevation)
  powershell -ExecutionPolicy Bypass -File .\Set-HomeNetPolicy.ps1 -Undo
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Status,
    [switch]$Undo,
    [switch]$MeteredOnly,
    [switch]$UpdatesOnly,
    [switch]$Wifi,
    [switch]$Reconnect,
    [switch]$Pause          # internal: keep the elevated window open at the end
)
$ErrorActionPreference = 'Stop'

if ($MeteredOnly -and $UpdatesOnly) { throw '-MeteredOnly and -UpdatesOnly cannot be combined.' }
if ($Status -and $Undo) { throw '-Status and -Undo cannot be combined.' }

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---- relaunch: needs Windows PowerShell 5.1 (WinRT cost API), and administrator rights unless -Status
$needAdmin = -not $Status
if ($PSVersionTable.PSEdition -eq 'Core' -or ($needAdmin -and -not (Test-Admin))) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($k in $PSBoundParameters.Keys) {
        if ($PSBoundParameters[$k] -is [switch] -and $PSBoundParameters[$k].IsPresent) { $argList += "-$k" }
    }
    $elevate = $needAdmin -and -not (Test-Admin)
    if ($elevate) {
        Write-Host 'Administrator rights are needed; a UAC prompt will appear.'
        $argList += '-Pause'
        Start-Process -FilePath powershell.exe -ArgumentList $argList -Verb RunAs -Wait
    } else {
        & powershell.exe @argList
    }
    return
}

$Dir = Join-Path $env:ProgramData 'HomeNetPolicy'
$BackupFile = Join-Path $Dir 'backup.json'
$CostKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\DefaultMediaCost'
$DoPolKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
$Admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$script:CostHive = [Microsoft.Win32.Registry]::LocalMachine     # overridable only so the ACL round trip can be tested on a scratch key

if ($needAdmin) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    try { Start-Transcript -Path (Join-Path $Dir 'last-run.log') -Force | Out-Null } catch { }
}

# ---- privilege helper (SeTakeOwnership / SeRestore are needed to touch the TrustedInstaller-owned key)
if (-not ('HomeNetTokenPriv' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HomeNetTokenPriv {
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TOKPRIV { public int Count; public long Luid; public int Attr; }
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr h, int acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string host, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr tok, bool disableAll, ref TOKPRIV newState, int len, IntPtr prev, IntPtr retLen);
    public static bool Enable(string priv) {
        IntPtr tok;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out tok)) return false;
        TOKPRIV tp = new TOKPRIV(); tp.Count = 1; tp.Attr = 2;
        if (!LookupPrivilegeValue(null, priv, out tp.Luid)) return false;
        if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
        return Marshal.GetLastWin32Error() == 0;          // 1300 = not all assigned
    }
}
'@
}

# ---- reading helpers
function Get-MediaCost {
    $o = [ordered]@{}
    try {
        $k = Get-ItemProperty ('HKLM:\' + $CostKey)
        foreach ($n in 'Ethernet', 'WiFi', '3G', '4G', 'Default') { $o[$n] = $k.$n }
    } catch { }
    $o
}

function Get-CurrentCostType {
    try {
        [void][Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
        $p = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if (-not $p) { return 'no internet connection profile' }
        '{0}: {1}' -f $p.ProfileName, $p.GetConnectionCost().NetworkCostType
    } catch { 'unknown (' + $_.Exception.Message + ')' }
}

function Get-DoPolicyValue([string]$Name) {
    try { (Get-ItemProperty $DoPolKey -ErrorAction Stop).$Name } catch { $null }
}

function Show-State([string]$Title) {
    Write-Host ''
    Write-Host "== $Title" -ForegroundColor Cyan
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host ('Windows        : {0} (build {1})' -f $os.Caption, $os.BuildNumber)
    Write-Host ('Connection cost: {0}   (Unrestricted = not metered, Fixed = metered)' -f (Get-CurrentCostType))
    $m = Get-MediaCost
    Write-Host ('Default cost   : ' + (($m.Keys | ForEach-Object { '{0}={1}' -f $_, $m[$_] }) -join '  ') + '   (1 = not metered, 2 = metered)')
    try {
        $c = Get-DOConfig
        Write-Host ('Update sharing : DownloadMode={0} (set by: {1}), policy DODownloadMode={2}, DORestrictPeerSelectionBy={3}' -f `
            $c.DownloadMode, $c.DownloadModeProvider, (Get-DoPolicyValue 'DODownloadMode'), (Get-DoPolicyValue 'DORestrictPeerSelectionBy'))
    } catch { Write-Host 'Update sharing : Delivery Optimization status unavailable' }
    try {
        $p = Get-DeliveryOptimizationPerfSnapThisMonth
        Write-Host ('DO this month  : from internet/HTTP {0}, from LAN peers {1}, uploaded to LAN peers {2}, to internet peers {3}' -f `
            (Format-Bytes $p.DownloadHttpBytes), (Format-Bytes $p.DownloadLanBytes), (Format-Bytes $p.UploadLanBytes), (Format-Bytes $p.UploadInternetBytes))
    } catch { }
}

function Format-Bytes($b) {
    if ($null -eq $b) { return '-' }
    $u = 'B', 'kB', 'MB', 'GB', 'TB'; $i = 0; $v = [double]$b
    while ($v -ge 1000 -and $i -lt 4) { $v /= 1000; $i++ }
    if ($i -eq 0) { '{0:N0} {1}' -f $v, $u[$i] } else { '{0:N1} {1}' -f $v, $u[$i] }
}

# ---- backup of the first-seen state (never overwritten, so -Undo always returns to the true original)
function Save-BackupOnce {
    if (Test-Path $BackupFile) { return }
    $m = Get-MediaCost
    $b = [ordered]@{
        created   = (Get-Date).ToString('s')
        mediaCost = [ordered]@{ Ethernet = $m['Ethernet']; WiFi = $m['WiFi'] }
        doPolicy  = [ordered]@{ DODownloadMode = (Get-DoPolicyValue 'DODownloadMode'); DORestrictPeerSelectionBy = (Get-DoPolicyValue 'DORestrictPeerSelectionBy') }
    }
    if ($PSCmdlet.ShouldProcess($BackupFile, 'save original settings')) {
        $b | ConvertTo-Json -Depth 4 | Set-Content -Path $BackupFile -Encoding UTF8
        Write-Host "Saved original settings to $BackupFile"
    }
}
function Read-Backup { if (Test-Path $BackupFile) { Get-Content $BackupFile -Raw | ConvertFrom-Json } else { $null } }

# ---- (a) metered: write DefaultMediaCost values; take ownership, then put owner and permissions back
function Set-MediaCostValues([hashtable]$Wanted) {
    $cur = Get-MediaCost
    $todo = @{}
    foreach ($n in $Wanted.Keys) { if ([int]$cur[$n] -ne [int]$Wanted[$n]) { $todo[$n] = $Wanted[$n] } }
    if ($todo.Count -eq 0) { Write-Host 'Default connection cost already as wanted; nothing to change.'; return }
    $desc = ($todo.Keys | ForEach-Object { '{0} -> {1}' -f $_, $todo[$_] }) -join ', '
    if (-not $PSCmdlet.ShouldProcess('HKLM\' + $CostKey, "set $desc")) { return }

    foreach ($p in 'SeTakeOwnershipPrivilege', 'SeRestorePrivilege', 'SeBackupPrivilege') {
        if (-not [HomeNetTokenPriv]::Enable($p)) { Write-Warning "Could not enable $p (are you elevated?)" }
    }
    $hklm = $script:CostHive
    $opt = [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
    $rr = [System.Security.AccessControl.RegistryRights]
    $sec = [System.Security.AccessControl.AccessControlSections]

    $k = $hklm.OpenSubKey($CostKey, $opt, $rr::ReadPermissions)
    $origSddl = $k.GetAccessControl($sec::Owner -bor $sec::Access).GetSecurityDescriptorSddlForm($sec::Owner -bor $sec::Access)
    $k.Close()
    try {
        # 1. take ownership
        $k = $hklm.OpenSubKey($CostKey, $opt, $rr::TakeOwnership)
        $acl = New-Object System.Security.AccessControl.RegistrySecurity
        $acl.SetOwner($Admins)
        $k.SetAccessControl($acl); $k.Close()
        # 2. allow Administrators to write
        $k = $hklm.OpenSubKey($CostKey, $opt, $rr::ChangePermissions)
        $acl = $k.GetAccessControl($sec::Access)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
            $Admins, 'FullControl', 'ContainerInherit', 'None', 'Allow')))
        $k.SetAccessControl($acl); $k.Close()
        # 3. write the values
        $k = $hklm.OpenSubKey($CostKey, $true)
        foreach ($n in $todo.Keys) { $k.SetValue($n, [int]$todo[$n], [Microsoft.Win32.RegistryValueKind]::DWord) }
        $k.Close()
        Write-Host "Set default connection cost: $desc"
    } finally {
        # 4. restore the original permissions, then the original owner (TrustedInstaller)
        try {
            $orig = New-Object System.Security.AccessControl.RegistrySecurity
            $orig.SetSecurityDescriptorSddlForm($origSddl, $sec::Owner -bor $sec::Access)
            $origOwner = $orig.GetOwner([System.Security.Principal.SecurityIdentifier])
            $dacl = New-Object System.Security.AccessControl.RegistrySecurity
            $dacl.SetSecurityDescriptorSddlForm($origSddl, $sec::Access)
            $k = $hklm.OpenSubKey($CostKey, $opt, $rr::ChangePermissions)
            $k.SetAccessControl($dacl); $k.Close()
            $k = $hklm.OpenSubKey($CostKey, $opt, $rr::TakeOwnership)
            $own = New-Object System.Security.AccessControl.RegistrySecurity
            $own.SetOwner($origOwner)
            $k.SetAccessControl($own); $k.Close()
        } catch {
            Write-Warning ("Could not fully restore the key's original owner/permissions: " + $_.Exception.Message)
            Write-Warning "Original security descriptor (SDDL) for manual repair: $origSddl"
        }
    }
}

# ---- (b) LAN-based updates via Delivery Optimization policy
function Set-LanUpdates {
    if (-not $PSCmdlet.ShouldProcess('Delivery Optimization', 'DODownloadMode=1 (LAN), DORestrictPeerSelectionBy=1 (subnet)')) { return }
    if (-not (Test-Path $DoPolKey)) { New-Item -Path $DoPolKey -Force | Out-Null }
    Set-ItemProperty -Path $DoPolKey -Name DODownloadMode -Type DWord -Value 1
    Set-ItemProperty -Path $DoPolKey -Name DORestrictPeerSelectionBy -Type DWord -Value 1
    Restart-Service -Name DoSvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $c = Get-DOConfig
    if ($c.DownloadMode -ne 'Lan') {
        Write-Warning "Policy was written but Windows reports DownloadMode=$($c.DownloadMode); falling back to Set-DODownloadMode."
        Set-DODownloadMode -DownloadMode Lan
    }
    Write-Host 'Update sharing set to: PCs on the local network only (subnet-restricted).'
}

function Undo-LanUpdates($b) {
    if (-not $PSCmdlet.ShouldProcess('Delivery Optimization', 'restore original policy values')) { return }
    foreach ($n in 'DODownloadMode', 'DORestrictPeerSelectionBy') {
        $orig = if ($b) { $b.doPolicy.$n } else { $null }
        if ($null -eq $orig) { Remove-ItemProperty -Path $DoPolKey -Name $n -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -Path $DoPolKey -Name $n -Type DWord -Value ([int]$orig) }
    }
    Restart-Service -Name DoSvc -Force -ErrorAction SilentlyContinue
    Write-Host 'Delivery Optimization policy restored to the original values.'
}

function Restart-WiredAdapters {
    if (-not $PSCmdlet.ShouldProcess('physical network adapters', 'restart')) { return }
    Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        Write-Host ('Restarting adapter {0} ...' -f $_.Name)
        Restart-NetAdapter -Name $_.Name -Confirm:$false
    }
}

# ================================================================ main
try {
    if ($Status) { Show-State 'Current state (read-only)'; return }

    Show-State 'Before'
    $b = Read-Backup
    if ($Undo) {
        if (-not $b) { Write-Warning "No backup found at $BackupFile; nothing to undo."; return }
        if (-not $UpdatesOnly) {
            $want = @{ Ethernet = $(if ($null -ne $b.mediaCost.Ethernet) { $b.mediaCost.Ethernet } else { 1 }) }
            if ($Wifi -or $b.mediaCost.WiFi -ne (Get-MediaCost)['WiFi']) { $want['WiFi'] = $(if ($null -ne $b.mediaCost.WiFi) { $b.mediaCost.WiFi } else { 1 }) }
            Set-MediaCostValues $want
        }
        if (-not $MeteredOnly) { Undo-LanUpdates $b }
    } else {
        Save-BackupOnce
        if (-not $UpdatesOnly) {
            $want = @{ Ethernet = 2 }
            if ($Wifi) { $want['WiFi'] = 2 }
            Set-MediaCostValues $want
        }
        if (-not $MeteredOnly) { Set-LanUpdates }
    }
    if ($Reconnect) { Restart-WiredAdapters; Start-Sleep -Seconds 8 }
    Show-State 'After'

    Write-Host ''
    if (-not $Undo -and -not $UpdatesOnly) {
        Write-Host 'Notes' -ForegroundColor Cyan
        Write-Host ' - The metered flag applies when the connection is next established: unplug/replug the cable, rerun with -Reconnect, or reboot.'
        Write-Host '   Then run with -Status: "Connection cost" should read Fixed.'
        Write-Host ' - While metered, Windows waits for you to press Download in Settings > Windows Update, and OneDrive pauses syncing by default'
        Write-Host '   (OneDrive: settings > Sync and backup > Advanced > "Pause syncing when this device is on a metered network").'
        Write-Host ' - Update sharing needs the Delivery Optimization service to reach the internet to find peers; downloads then go PC to PC (TCP 7680).'
        Write-Host '   Uploads are skipped on battery and while a VPN adapter is active; check "DO this month" in -Status after an update to see LAN peer traffic.'
    }
} finally {
    if ($needAdmin) { try { Stop-Transcript | Out-Null } catch { } }
    if ($Pause) { Read-Host 'Press Enter to close' | Out-Null }
}
