<#
.SYNOPSIS
    Finds broken and leftover user profiles on an RDS session host and fixes them safely. Dry run by default.

.DESCRIPTION
    On hosts with User Profile Disks or FSLogix, C:\Users should contain little more than mount points.
    After failed logons it accumulates TEMP.* profiles, user.DOMAIN.000 copies, orphan folders and
    broken ProfileList entries (the classic "SID" + "SID.bak" pair that makes Windows load a temporary profile).

    The script classifies every folder in C:\Users:
      DISK      profile disk attached (normal)
      PROBLEM   session exists but no profile disk is attached, or the disk is unhealthy
      LEFTOVER  TEMP.*, user.DOMAIN(.000), *.bak copies
      ORPHAN    no ProfileList entry
      LOCAL     local folder without an attached disk

    and checks ProfileList for dangling entries, SID/SID.bak pairs and TEMP state flags.

    With -Execute, LEFTOVER and ORPHAN folders without a loaded hive or session are MOVED to a
    quarantine folder (not deleted; Clear-SessionHostDisk.ps1 removes old quarantine later).
    With -Execute -FixRegistry, ProfileList is exported to a .reg file first, then:
      - dangling entries are removed;
      - SID.bak pairs are restored: the .bak entry is copied over the primary one, the profile path is
        verified, and the whole ProfileList is rolled back from the export if verification fails.
    Users with a session or a loaded registry hive are always skipped.

.PARAMETER Execute
    Move folders to quarantine. Without it the script only reports.

.PARAMETER FixRegistry
    With -Execute: also repair ProfileList entries.

.PARAMETER Domain
    NetBIOS domain name used to recognize user.DOMAIN profile copies. Default: current user's domain.

.PARAMETER QuarantinePath
    Where leftover folders are moved. Default: C:\ProfileQuarantine.

.PARAMETER LogPath
    Folder for reports and ProfileList backups.

.EXAMPLE
    .\Repair-UserProfile.ps1

.EXAMPLE
    .\Repair-UserProfile.ps1 -Execute -FixRegistry
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$FixRegistry,
    [string]$Domain = $env:USERDOMAIN,
    [string]$QuarantinePath = 'C:\ProfileQuarantine',
    [string]$LogPath = (Join-Path $env:ProgramData 'rds-toolkit\logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')

$profileListPs = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$profileListReg = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$systemFolders = @('Public', 'Default', 'Default User', 'All Users', 'defaultuser0', 'UvhdCleanupBin')
$usersRoot = Join-Path $env:SystemDrive 'Users'
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'

function Format-MB { param([double]$Bytes) if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) } else { '{0:N0} MB' -f ($Bytes / 1MB) } }

function Invoke-Reg {
    # Runs reg.exe and returns $true on exit code 0.
    param([string[]]$Arguments)
    & reg.exe @Arguments 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

if (-not (Test-Path -LiteralPath $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }

$started = Get-Date
Write-ReportHeader 'USER PROFILE CHECK AND REPAIR'
Write-ReportLine ('Server : ' + $env:COMPUTERNAME)
Write-ReportLine ('Mode   : ' + $(if ($Execute) { 'EXECUTE' } else { 'DRY RUN' })) $(if ($Execute) { 'Yellow' } else { 'Green' })
if ($Execute -and $FixRegistry) { Write-ReportLine 'ProfileList repair: ENABLED' Yellow }

# Attached profile disks by mount point
$mounted = @{}
foreach ($disk in (Get-Disk | Where-Object { $_.BusType -eq 'File Backed Virtual' })) {
    foreach ($partition in (Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)) {
        foreach ($ap in @($partition.AccessPaths)) {
            if ($ap -and $ap -notmatch '^\\\\\?\\Volume') {
                $mounted[$ap.TrimEnd('\').ToLower()] = [PSCustomObject]@{ Disk = $disk.Number; Health = $disk.HealthStatus }
            }
        }
    }
}
$sessions = @{}
foreach ($s in (Get-RdsUserSession)) { $sessions[$s.UserName.ToLower()] = $s }
$loaded = @{}
foreach ($up in (Get-CimInstance Win32_UserProfile)) {
    if ($up.LocalPath) { $loaded[$up.LocalPath.TrimEnd('\').ToLower()] = [bool]$up.Loaded }
}
$registry = @(foreach ($key in (Get-ChildItem $profileListPs)) {
        $p = Get-ItemProperty $key.PSPath
        $path = if ($p.PSObject.Properties['ProfileImagePath']) { $p.ProfileImagePath } else { $null }
        [PSCustomObject]@{
            Key     = $key.PSChildName
            IsBak   = $key.PSChildName -like '*.bak'
            BaseSid = $key.PSChildName -replace '\.bak$', ''
            Path    = $path
            State   = if ($p.PSObject.Properties['State']) { [int]$p.State } else { 0 }
            Exists  = [bool]($path -and (Test-Path -LiteralPath $path))
        }
    })
Write-ReportLine ('Attached profile disks: {0}   sessions: {1}   ProfileList entries: {2}' -f $mounted.Count, $sessions.Count, $registry.Count)

Write-ReportHeader "FOLDERS IN $usersRoot"
$domainPattern = '\.' + [regex]::Escape($Domain) + '(\.\d+)?$'
$rows = foreach ($dir in (Get-ChildItem -LiteralPath $usersRoot -Directory -Force)) {
    if ($systemFolders -contains $dir.Name) { continue }
    $key = $dir.FullName.TrimEnd('\').ToLower()
    $session = $sessions[$dir.Name.ToLower()]
    $isLoaded = [bool]$loaded[$key]
    $regCount = @($registry | Where-Object { $_.Path -and $_.Path.TrimEnd('\').ToLower() -eq $key }).Count

    $size = -1
    if (-not $mounted.ContainsKey($key) -and -not ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $size = (Get-FolderSize $dir.FullName).Bytes
    }

    if ($mounted.ContainsKey($key)) {
        $class = 'DISK'; $note = 'profile disk attached'
        if ($mounted[$key].Health -ne 'Healthy') { $class = 'PROBLEM'; $note = 'profile disk attached but unhealthy' }
    }
    elseif ($dir.Name -match '^TEMP\.') { $class = 'LEFTOVER'; $note = 'temporary profile after a failed load' }
    elseif ($dir.Name -match "$domainPattern|\.BACKUP-\d+$|\.bak$") { $class = 'LEFTOVER'; $note = 'copy of a broken profile' }
    elseif ($session) { $class = 'PROBLEM'; $note = 'session exists but the profile disk is NOT attached' }
    elseif ($regCount -eq 0) { $class = 'ORPHAN'; $note = 'no ProfileList entry' }
    else { $class = 'LOCAL'; $note = 'local folder, no disk attached' }
    if ($isLoaded) { $note += '; registry hive loaded' }

    [PSCustomObject]@{
        Name = $dir.Name; Path = $dir.FullName; Class = $class; Bytes = $size
        Session = if ($session) { $session.State } else { '' }; Loaded = $isLoaded; Note = $note
    }
}
$rows = @($rows)

Write-ReportLine ('  {0,-28} {1,-9} {2,10} {3,-8} {4,-6} {5}' -f 'Folder', 'Class', 'Size', 'Session', 'Hive', 'Note')
$colors = @{ DISK = 'Gray'; LEFTOVER = 'Yellow'; ORPHAN = 'Yellow'; PROBLEM = 'Red'; LOCAL = 'DarkYellow' }
foreach ($r in ($rows | Sort-Object Class, @{ Expression = { -$_.Bytes } })) {
    $sizeText = if ($r.Bytes -lt 0) { '(on disk)' } else { Format-MB $r.Bytes }
    Write-ReportLine ('  {0,-28} {1,-9} {2,10} {3,-8} {4,-6} {5}' -f $r.Name, $r.Class, $sizeText, $r.Session, $r.Loaded, $r.Note) $colors[$r.Class]
}

$leftovers = @($rows | Where-Object { $_.Class -in 'LEFTOVER', 'ORPHAN' -and -not $_.Loaded -and -not $_.Session })
$broken = @($rows | Where-Object { $_.Class -eq 'PROBLEM' })
$leftoverBytes = ($leftovers | Where-Object { $_.Bytes -gt 0 } | Measure-Object Bytes -Sum).Sum
Write-ReportLine ''
Write-ReportLine ('  Leftovers and orphans: {0}, {1} on {2}' -f $leftovers.Count, (Format-MB $leftoverBytes), $env:SystemDrive) $(if ($leftovers) { 'Yellow' } else { 'Green' })
Write-ReportLine ('  Broken right now     : {0}' -f $broken.Count) $(if ($broken) { 'Red' } else { 'Green' })
foreach ($b in $broken) {
    Write-ReportLine ('    {0}: {1}' -f $b.Name, $b.Note) Red
    Write-ReportLine ('      Likely a stale VHDX lock on the file server. Check there: Get-SmbOpenFile | Where-Object Path -like "*<SID>*"') DarkGray
}

Write-ReportHeader 'PROFILELIST REGISTRY'
$dangling = @($registry | Where-Object { -not $_.IsBak -and -not $_.Exists -and $_.Path -like "$usersRoot\*" })
$bakPairs = @(foreach ($b in ($registry | Where-Object IsBak)) {
        $primary = $registry | Where-Object { $_.Key -eq $b.BaseSid } | Select-Object -First 1
        if ($primary) { [PSCustomObject]@{ Sid = $b.BaseSid; PrimaryPath = $primary.Path; BakPath = $b.Path } }
    })
$tempState = @($registry | Where-Object { -not $_.IsBak -and ($_.State -band 0x800) })
Write-ReportLine ('  Dangling entries : ' + $dangling.Count) $(if ($dangling) { 'Yellow' } else { 'Green' })
Write-ReportLine ('  SID / SID.bak    : ' + $bakPairs.Count) $(if ($bakPairs) { 'Red' } else { 'Green' })
Write-ReportLine ('  TEMP state flag  : ' + $tempState.Count) $(if ($tempState) { 'Red' } else { 'Green' })
foreach ($d in $dangling) { Write-ReportLine ('    dangling: {0} -> {1}' -f $d.Key, $d.Path) Yellow }
foreach ($p in $bakPairs) {
    Write-ReportLine ('    BROKEN: {0} ({1})' -f (Split-Path $p.BakPath -Leaf), $p.Sid) Red
    Write-ReportLine ('      loads now  -> ' + $p.PrimaryPath) DarkGray
    Write-ReportLine ('      should load -> ' + $p.BakPath) DarkGray
}

Write-ReportHeader 'ACTIONS'
$actions = @()
if (-not $Execute) {
    Write-ReportLine '  Dry run, nothing changed. With -Execute:' Green
    Write-ReportLine ('    1. move {0} folder(s) ({1}) to {2} - moved, not deleted' -f $leftovers.Count, (Format-MB $leftoverBytes), $QuarantinePath)
    if ($FixRegistry) {
        Write-ReportLine ('    2. remove {0} dangling ProfileList entr(ies)' -f $dangling.Count)
        Write-ReportLine ('    3. restore {0} SID.bak pair(s), verified, with rollback from a .reg export' -f $bakPairs.Count)
    }
    else { Write-ReportLine '    Registry is not touched without -FixRegistry.' DarkGray }
}
else {
    if ($leftovers) {
        $target = Join-Path $QuarantinePath $stamp
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        foreach ($l in $leftovers) {
            if ($mounted.ContainsKey($l.Path.TrimEnd('\').ToLower())) { continue }
            $dest = Join-Path $target $l.Name
            try {
                Move-Item -LiteralPath $l.Path -Destination $dest -Force
                Write-ReportLine ('    moved: {0}' -f $l.Name) Green
                $actions += [PSCustomObject]@{ Action = 'Quarantine'; Target = $l.Name; Result = 'OK' }
            }
            catch {
                Write-ReportLine ('    NOT moved: {0} ({1})' -f $l.Name, $_.Exception.Message) Red
                $actions += [PSCustomObject]@{ Action = 'Quarantine'; Target = $l.Name; Result = 'Failed' }
            }
        }
    }

    if ($FixRegistry -and ($dangling -or $bakPairs)) {
        $backup = Join-Path $LogPath "ProfileList_$($env:COMPUTERNAME)_$stamp.reg"
        if (-not (Invoke-Reg 'export', $profileListReg, $backup, '/y')) { throw "Cannot export ProfileList to $backup - registry not changed." }
        Write-ReportLine ('  ProfileList exported: ' + $backup) Green

        foreach ($d in $dangling) {
            if ($sessions.Keys | Where-Object { $d.Path -like "*\$_" }) { Write-ReportLine ('    skipped (session): ' + $d.Key) Yellow; continue }
            Remove-Item -LiteralPath "$profileListPs\$($d.Key)" -Recurse -Force
            Write-ReportLine ('    removed dangling entry: ' + $d.Key) Green
            $actions += [PSCustomObject]@{ Action = 'RemoveDangling'; Target = $d.Key; Result = 'OK' }
        }

        foreach ($p in $bakPairs) {
            $user = Split-Path $p.BakPath -Leaf
            if ($sessions.ContainsKey($user.ToLower()) -or (Test-Path "Registry::HKEY_USERS\$($p.Sid)")) {
                Write-ReportLine ('    skipped (user logged on): ' + $user) Yellow; continue
            }
            if (-not $p.BakPath -or $p.BakPath -match '\\TEMP\.' -or -not (Test-Path -LiteralPath $p.BakPath)) {
                Write-ReportLine ('    skipped (.bak path is temporary or missing): ' + $user) Yellow; continue
            }
            $primary = "$profileListReg\$($p.Sid)"
            $ok = (Invoke-Reg 'delete', $primary, '/f') -and (Invoke-Reg 'copy', "$primary.bak", $primary, '/s', '/f')
            $check = Get-ItemProperty -Path "$profileListPs\$($p.Sid)" -ErrorAction SilentlyContinue
            if (-not $ok -or -not $check -or $check.ProfileImagePath -ne $p.BakPath) {
                [void](Invoke-Reg 'import', $backup)
                Write-ReportLine ('    FAILED, ProfileList rolled back: ' + $user) Red
                $actions += [PSCustomObject]@{ Action = 'RestoreBak'; Target = $user; Result = 'RolledBack' }
                continue
            }
            [void](Invoke-Reg 'delete', "$primary.bak", '/f')
            Set-ItemProperty -Path "$profileListPs\$($p.Sid)" -Name State -Value 0 -Type DWord
            Set-ItemProperty -Path "$profileListPs\$($p.Sid)" -Name RefCount -Value 0 -Type DWord
            Write-ReportLine ('    restored profile entry: {0} -> {1}' -f $user, $p.BakPath) Green
            $actions += [PSCustomObject]@{ Action = 'RestoreBak'; Target = $user; Result = 'OK' }
        }
    }
    Write-ReportLine '  Quarantined folders are not deleted: review them or let Clear-SessionHostDisk.ps1 remove old ones.' DarkGray
}

$report = Save-Report -LogPath $LogPath -Prefix 'ProfileRepair'
Write-ReportLine ('  Report: ' + $report + '   Duration: ' + [Math]::Round(((Get-Date) - $started).TotalMinutes, 1) + ' min') DarkGray

if ($Execute) { $actions } else { $rows }
