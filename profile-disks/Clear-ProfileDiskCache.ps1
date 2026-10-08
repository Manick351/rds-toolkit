<#
.SYNOPSIS
    Clears application caches inside one user's profile disk (UPD or FSLogix). Dry run by default.

.DESCRIPTION
    Typical use: a 1C:Enterprise client or a browser misbehaves because of a corrupted cache, or the
    profile disk is full. The cache lives inside the user's VHDX, so it can only be cleared while the
    user is logged off and the disk is mounted somewhere else.

    Steps:
      1. resolve the user's SID and find sessions on the farm's session hosts;
      2. with -LogoffUser, log those sessions off and wait until the disk is released;
      3. find the profile disk (UPD: UVHD-<SID>.vhdx, FSLogix: <SID>_<user>\Profile_<user>.vhdx);
      4. mount it (read-only in dry run, read-write with -Execute) using Mount-DiskImage,
         so the Hyper-V module is not required;
      5. measure the selected cache folders and, with -Execute, delete their contents;
      6. always dismount the disk.

    Without -Execute nothing is changed and no session is logged off.

.PARAMETER ConfigPath
    Farm configuration (.psd1).

.PARAMETER Farm
    Farm name from the configuration.

.PARAMETER UserName
    Logon name (with or without DOMAIN\).

.PARAMETER CacheSet
    Which caches to clear: 1C, Temp, Browser, Adobe, Office. Default: 1C.

.PARAMETER LogoffUser
    Log off the user's sessions on the farm first. Without it the script stops if a session exists.

.PARAMETER Execute
    Actually log off and delete. Without it the script is a dry run.

.EXAMPLE
    .\Clear-ProfileDiskCache.ps1 -ConfigPath ..\config\farms.psd1 -Farm Accounting -UserName jdoe

    Dry run: shows sessions, the disk and cache sizes.

.EXAMPLE
    .\Clear-ProfileDiskCache.ps1 -ConfigPath ..\config\farms.psd1 -Farm Accounting -UserName jdoe -CacheSet 1C, Temp -LogoffUser -Execute

.NOTES
    Run elevated on a server that can reach the profile share (the disk is mounted locally over SMB).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$Farm,

    [Parameter(Mandatory = $true)]
    [string]$UserName,

    [ValidateSet('1C', 'Temp', 'Browser', 'Adobe', 'Office')]
    [string[]]$CacheSet = @('1C'),

    [switch]$LogoffUser,

    [switch]$Execute,

    [string]$LogPath = (Join-Path $env:ProgramData 'rds-toolkit\logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')

if (-not (Test-IsAdministrator)) { throw 'Run this script elevated: mounting disk images requires admin rights.' }

$config = Import-RdsConfig -Path $ConfigPath
$farmConfig = Get-RdsFarm -Config $config -Name $Farm
$shortName = $UserName -replace '^.*\\', ''

Write-ReportHeader "CLEAR PROFILE CACHE: $shortName ($($farmConfig.Name), $($farmConfig.ProfileType))"
Write-ReportLine ('Caches : ' + ($CacheSet -join ', '))
Write-ReportLine ('Mode   : ' + $(if ($Execute) { 'EXECUTE' } else { 'DRY RUN' })) $(if ($Execute) { 'Yellow' } else { 'Green' })

# 1. SID
$sid = Get-UserSid -UserName $shortName -Domain $config.Domain
if (-not $sid) { throw "Cannot resolve SID for '$UserName'." }
Write-ReportLine ('SID    : ' + $sid)

# 2. Sessions
Write-ReportSection 'Sessions'
$sessions = @(foreach ($h in $farmConfig.SessionHosts) {
        Get-RdsUserSession -ComputerName $h | Where-Object { $_.UserName -eq $shortName }
    })
if (-not $sessions) { Write-ReportLine '  no sessions' }
foreach ($s in $sessions) { Write-ReportLine ('  {0}  id {1}  {2}' -f $s.ComputerName, $s.SessionId, $s.State) Yellow }

if ($sessions -and -not $LogoffUser) {
    Write-ReportLine '  The user is logged on, the disk is in use. Ask the user to log off or add -LogoffUser.' Red
    return
}

# 3. Disk
Write-ReportSection 'Profile disk'
$disk = Find-ProfileDisk -Farm $farmConfig -Sid $sid -UserName $shortName
if (-not $disk) { throw "No profile disk found for $shortName in $($farmConfig.ProfileShare)." }
Write-ReportLine ('  {0}  ({1:N2} GB, modified {2:yyyy-MM-dd HH:mm})' -f $disk.FullName, ($disk.Length / 1GB), $disk.LastWriteTime)

if ($sessions) {
    if (-not $Execute) {
        Write-ReportLine ('  Dry run: would log off {0} session(s) and wait for the disk to be released.' -f $sessions.Count) Yellow
        Write-ReportLine '  Cache sizes cannot be measured while the disk is in use.' DarkGray
        return
    }
    foreach ($s in $sessions) {
        Write-ReportLine ('  Logging off {0} on {1}' -f $s.SessionId, $s.ComputerName) Yellow
        & logoff.exe $s.SessionId "/server:$($s.ComputerName)" 2>&1 | Out-Null
    }
}

# 4-6. Mount, measure, clear, dismount. Retry mounting while the session host releases the file.
$mount = $null
$deadline = (Get-Date).AddSeconds(90)
do {
    try { $mount = Mount-ProfileDisk -Path $disk.FullName -ReadOnly:(-not $Execute) }
    catch {
        if ((Get-Date) -gt $deadline) { throw "Cannot mount the disk (still in use?): $($_.Exception.Message)" }
        Start-Sleep -Seconds 5
    }
} until ($mount)

$results = @()
try {
    Write-ReportLine ('  Mounted at {0} ({1})' -f $mount.Root, $(if ($Execute) { 'read-write' } else { 'read-only' })) Green
    $profileRoot = Get-ProfileRoot $mount.Root
    if (-not $profileRoot) { throw 'Profile folder (AppData) not found inside the disk.' }

    Write-ReportSection 'Caches'
    foreach ($entry in (Get-ProfileFolderCatalog -Set $CacheSet | Where-Object Junk)) {
        $full = Join-Path $profileRoot $entry.Path
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $size = Get-FolderSize $full
        $freed = 0
        if ($Execute -and $size.Bytes -gt 0) {
            Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            $freed = $size.Bytes - (Get-FolderSize $full).Bytes
        }
        $shown = if ($Execute) { $freed } else { $size.Bytes }
        Write-ReportLine ('  {0,-26} {1,10}  {2,7} files  {3}' -f $entry.Name, (Format-Size $shown), $size.Files, $(if ($Execute) { 'cleared' } else { 'would clear' })) Green
        $results += [PSCustomObject]@{ Cache = $entry.Name; Path = $entry.Path; Bytes = $size.Bytes; FreedBytes = $freed }
    }
    if (-not $results) { Write-ReportLine '  selected caches are empty or absent' }
}
finally {
    if (Dismount-ProfileDisk -Path $disk.FullName) { Write-ReportLine '  Disk dismounted.' Green }
    else { Write-ReportLine ('  DISK STILL ATTACHED: Dismount-DiskImage -ImagePath "{0}"' -f $disk.FullName) Red }
}

$total = if ($Execute) { ($results | Measure-Object FreedBytes -Sum).Sum } else { ($results | Measure-Object Bytes -Sum).Sum }
Write-ReportLine ''
Write-ReportLine ('  {0}: {1}' -f $(if ($Execute) { 'Freed inside the disk' } else { 'Would free' }), (Format-Size $total)) Cyan
if ($Execute -and $total -gt 1GB) { Write-ReportLine '  The VHDX file does not shrink by itself: run Compact-ProfileDisk.ps1 to return space to the file server.' DarkGray }
if (-not $Execute) { Write-ReportLine '  Dry run. Add -Execute to clear.' Yellow }

Save-Report -LogPath $LogPath -Prefix 'ClearProfileDiskCache' | Out-Null
$results
