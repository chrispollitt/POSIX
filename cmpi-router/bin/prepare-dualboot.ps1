#Requires -RunAsAdministrator
<#
  Prepares this Windows PC (Beelink Mini S) to dual boot with Debian:
    1. Turns off Fast Startup (so Windows shuts down cleanly and the disk is not left "hibernated")
    2. Shrinks C: by -LinuxGB to leave unallocated space for Debian
    3. Writes the Debian installer ISO to a USB stick (erases the stick)

  Each step asks first. Nothing is touched until you confirm.
  Run from an elevated PowerShell:  .\prepare-dualboot.ps1
#>
[CmdletBinding()]
param(
    [int]$LinuxGB = 64,
    [string]$IsoPath,
    [string]$IsoSha256 = 'a7ef94ac2fb9a7fec454552abd629b7cc9d5155c886165a45649f5ce6167e355'
)
$ErrorActionPreference = 'Stop'
if (-not $IsoPath) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $iso = 'debian-13.7.0-amd64-netinst.iso'
    # look next to the script, then in ..\Misc and .. (the repo keeps the ISO in Misc\)
    $IsoPath = @((Join-Path $here $iso), (Join-Path $here "..\Misc\$iso"), (Join-Path $here "..\$iso")) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $IsoPath) { $IsoPath = Join-Path $here $iso }     # not found: the later check reports the missing file
}

function Confirm-Step($msg) { (Read-Host "$msg [y/N]") -match '^(y|yes)$' }

# ---------------------------------------------------------------- 0. checks
Write-Host "`n== Pre-flight ==" -ForegroundColor Cyan
$sys = Get-CimInstance Win32_ComputerSystem
"{0} {1}  host={2}" -f $sys.Manufacturer, $sys.Model, $sys.Name

$bl = Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue
if ($bl -and $bl.ProtectionStatus -eq 'On') {
    Write-Warning "BitLocker is ON for C:. Installing GRUB can trigger a recovery-key prompt at next Windows boot."
    Write-Warning "Back up your recovery key (https://account.microsoft.com/devices/recoverykey) before continuing."
    if (-not (Confirm-Step 'Recovery key saved and you want to continue?')) { return }
} else { 'BitLocker: not protecting C:' }

# ---------------------------------------------------------------- 1. Fast Startup
Write-Host "`n== Step 1: disable Fast Startup ==" -ForegroundColor Cyan
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
if ((Get-ItemProperty $key).HiberbootEnabled -eq 0) { 'Already off.' }
elseif (Confirm-Step 'Turn Fast Startup off (registry HiberbootEnabled=0)?') {
    Set-ItemProperty $key -Name HiberbootEnabled -Value 0
    'Done.'
}

# ---------------------------------------------------------------- 2. Shrink C:
Write-Host "`n== Step 2: shrink C: by $LinuxGB GB ==" -ForegroundColor Cyan
$disk = (Get-Partition -DriveLetter C).DiskNumber
$sup  = Get-PartitionSupportedSize -DriveLetter C
$cur  = (Get-Partition -DriveLetter C).Size
$new  = $cur - ([int64]$LinuxGB * 1GB)
"C: now {0:N1} GB, would become {1:N1} GB (minimum Windows allows: {2:N1} GB)" -f ($cur/1GB), ($new/1GB), ($sup.SizeMin/1GB)
if ($new -lt $sup.SizeMin) {
    Write-Warning "Windows cannot shrink C: that far (unmovable files). Reduce -LinuxGB or defrag/disable hibernation + pagefile and retry."
} elseif (Confirm-Step "Shrink C: by $LinuxGB GB now? (online, non-destructive, but make sure you have a backup of anything irreplaceable)") {
    Resize-Partition -DriveLetter C -Size $new
    'Done. Layout now:'
    Get-Partition -DiskNumber $disk | Format-Table PartitionNumber,DriveLetter,@{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}},Type -AutoSize
}

# ---------------------------------------------------------------- 3. USB installer
Write-Host "`n== Step 3: write Debian installer to USB ==" -ForegroundColor Cyan
if (-not (Test-Path $IsoPath)) { Write-Warning "ISO not found at $IsoPath - skipping."; return }
Write-Host 'Verifying ISO checksum...'
if ((Get-FileHash $IsoPath -Algorithm SHA256).Hash.ToLower() -ne $IsoSha256) { throw 'ISO SHA-256 mismatch - refusing to write.' }
'ISO OK.'

$usb = @(Get-Disk | Where-Object BusType -eq 'USB')
if ($usb.Count -eq 0) { Write-Warning 'No USB disk found - plug in the stick and re-run.'; return }
$usb | Format-Table Number,FriendlyName,@{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},PartitionStyle -AutoSize
$n = Read-Host 'Disk NUMBER of the USB stick to ERASE (blank to skip)'
if (-not $n) { return }
$target = $usb | Where-Object Number -eq ([int]$n)
if (-not $target) { throw "Disk $n is not a USB disk. Refusing." }
if ($target.Number -eq $disk) { throw 'That is the system disk. Refusing.' }

Get-Partition -DiskNumber $target.Number -ErrorAction SilentlyContinue | ForEach-Object {
    $v = Get-Volume -Partition $_ -ErrorAction SilentlyContinue
    "  existing: partition {0}  {1}  label='{2}'" -f $_.PartitionNumber, $_.DriveLetter, $v.FileSystemLabel
}
if ((Read-Host "Type ERASE to wipe '$($target.FriendlyName)' ($([math]::Round($target.Size/1GB,1)) GB) and write the ISO") -cne 'ERASE') { 'Cancelled.'; return }

Clear-Disk -Number $target.Number -RemoveData -RemoveOEM -Confirm:$false
Update-Disk -Number $target.Number

$bufSize = 1MB
$buf = New-Object byte[] $bufSize
$src = [IO.File]::OpenRead($IsoPath)
$dst = New-Object IO.FileStream("\\.\PhysicalDrive$($target.Number)", 'Open', 'ReadWrite', 'ReadWrite', 1)
try {
    $total = $src.Length; $done = 0
    while (($r = $src.Read($buf, 0, $bufSize)) -gt 0) {
        $w = [int]([math]::Ceiling($r / 512.0) * 512)           # raw devices need 512-byte multiples
        if ($w -gt $r) { [Array]::Clear($buf, $r, $w - $r) }
        $dst.Write($buf, 0, $w); $done += $r
        Write-Progress -Activity 'Writing ISO' -PercentComplete ([int](100 * $done / $total))
    }
    $dst.Flush()
} finally { $dst.Dispose(); $src.Dispose() }
Write-Progress -Activity 'Writing ISO' -Completed

Write-Host 'Verifying what was written...'
$dst = [IO.File]::Open("\\.\PhysicalDrive$($target.Number)", 'Open', 'Read', 'ReadWrite')
try {
    $sha = [Security.Cryptography.SHA256]::Create(); $left = (Get-Item $IsoPath).Length
    while ($left -gt 0) {
        $c = [int][math]::Min($bufSize, $left); $read = 0
        while ($read -lt [math]::Ceiling($c/512.0)*512) { $got = $dst.Read($buf, $read, [int]([math]::Ceiling($c/512.0)*512) - $read); if ($got -le 0) { break }; $read += $got }
        [void]$sha.TransformBlock($buf, 0, $c, $null, 0); $left -= $c
    }
    [void]$sha.TransformFinalBlock($buf, 0, 0)
    $hash = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLower()
} finally { $dst.Dispose() }
if ($hash -eq $IsoSha256) { Write-Host 'USB stick verified. Safe to remove.' -ForegroundColor Green }
else { Write-Warning "Verification FAILED ($hash). Re-run, or write the ISO with Rufus in 'DD Image' mode." }
