<#
.SYNOPSIS
    Frees space on the system drive of an RDS session host. Dry run by default; safe for a scheduled task.

.DESCRIPTION
    Removes files that Windows and common agents leave behind and never clean up themselves, each
    target with its own age threshold:

      - installer caches (old Adobe ARM updates, Windows Update downloads, Delivery Optimization);
      - error reports and dumps (WER, minidumps, LiveKernelReports, AV agent dumps);
      - temporary folders and the recycle bin;
      - service logs (CBS, DISM, Panther, Defender, AV agents, IIS);
      - the profile quarantine folder used by Repair-UserProfile.ps1.

    With -IncludeProfiles it also clears caches inside mounted profile disks (UPD/FSLogix) of users
    whose session is disconnected; this protects VHDX files from filling up but does not free the
    system drive. Acrobat caches are skipped for users who have Acrobat running.

    With -Deep it runs DISM /StartComponentCleanup (20-60 minutes, manual runs only).

    Protected paths (pagefile, WinSxS, Installer, registry, 1C:Enterprise program folders) are never touched.
    A one-line status file is written for monitoring (for example a Zabbix vfs.file.contents item).

.PARAMETER Execute
    Actually delete. Without it the script only reports sizes.

.PARAMETER MinFreeGB
    Target free space; below it the status is LOW and hints are printed. Default: 15.

.PARAMETER KeepAdobeUpdates
    Number of newest Adobe ARM update packages to keep. Default: 1.

.PARAMETER TempAgeDays
    Minimum age for files in Windows\Temp. Default: 3.

.PARAMETER LogAgeDays
    Minimum age for service logs. Default: 14.

.PARAMETER QuarantinePath
    Profile quarantine folder (see Repair-UserProfile.ps1). Default: C:\ProfileQuarantine.

.PARAMETER QuarantineAgeDays
    Minimum age for quarantined profile folders. Default: 14.

.PARAMETER IncludeProfiles
    Also clear caches inside mounted profile disks of disconnected users.

.PARAMETER Deep
    Run DISM component store cleanup (only with -Execute).

.PARAMETER LogPath
    Folder for text reports (last 60 kept).

.PARAMETER StatusFile
    Status line for monitoring: time=... status=OK|LOW free_gb=... freed_mb=... targets=...

.EXAMPLE
    .\Clear-SessionHostDisk.ps1

    Dry run: shows what can be freed.

.EXAMPLE
    .\Clear-SessionHostDisk.ps1 -Execute -IncludeProfiles

    Typical nightly scheduled task.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$Execute,
    [ValidateRange(1, 10000)][int]$MinFreeGB = 15,
    [ValidateRange(0, 100)][int]$KeepAdobeUpdates = 1,
    [ValidateRange(0, 3650)][int]$TempAgeDays = 3,
    [ValidateRange(0, 3650)][int]$LogAgeDays = 14,
    [string]$QuarantinePath = 'C:\ProfileQuarantine',
    [ValidateRange(0, 3650)][int]$QuarantineAgeDays = 14,
    [switch]$IncludeProfiles,
    [switch]$Deep,
    [string]$LogPath = (Join-Path $env:ProgramData 'rds-toolkit\logs'),
    [string]$StatusFile = (Join-Path $env:ProgramData 'rds-toolkit\cleanup_status.txt')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')

$drive = $env:SystemDrive
$protected = @(
    "$drive\pagefile.sys", "$drive\swapfile.sys", "$drive\hiberfil.sys"
    "$env:SystemRoot\Installer", "$env:SystemRoot\WinSxS", "$env:SystemRoot\System32\config"
    "$drive\Program Files\1cv8", "$drive\Program Files (x86)\1cv8", "$drive\Program Files (x86)\1cv82"
)
$script:Total = [double]0
$script:Rows = New-Object System.Collections.Generic.List[object]

function Test-Protected {
    param([string]$Path)
    foreach ($p in $protected) { if ($Path.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

function Get-FreeBytes { (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'").FreeSpace }

function Invoke-CleanupTarget {
    <#
        Collects files matching -Paths (wildcards allowed), filters by age and protection,
        deletes them with -Execute and prints one report line.
    #>
    param(
        [string]$Label,
        [string[]]$Paths,
        [int]$AgeDays = 0,
        [string]$Scope = 'System',
        [int]$KeepNewest = 0
    )
    $cutoff = (Get-Date).AddDays(-$AgeDays)
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($pattern in $Paths) {
        $found = @(Get-ChildItem -Path $pattern -Recurse -Force -File -ErrorAction SilentlyContinue)
        if ($KeepNewest -gt 0) { $found = @($found | Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepNewest) }
        foreach ($f in $found) {
            if (Test-Protected $f.FullName) { continue }
            if ($AgeDays -gt 0 -and $f.LastWriteTime -gt $cutoff) { continue }
            $files.Add($f)
        }
    }
    if ($files.Count -eq 0) {
        Write-ReportLine ('  {0,-44} {1,12}' -f $Label, 'empty') DarkGray
        return
    }

    $bytes = ($files | Measure-Object Length -Sum).Sum
    $freed = [double]0
    $locked = 0
    if ($Execute) {
        foreach ($f in $files) {
            $len = $f.Length
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $f.FullName) { $locked++ } else { $freed += $len }
        }
    }
    $shown = if ($Execute) { $freed } else { $bytes }
    $color = if ($shown -ge 500MB) { 'Green' } elseif ($shown -ge 50MB) { 'Gray' } else { 'DarkGray' }
    $suffix = if ($locked) { "  (in use: $locked)" } else { '' }
    Write-ReportLine ('  {0,-44} {1,12}  {2,6} files{3}' -f $Label, (Format-Size $shown), $files.Count, $suffix) $color

    $script:Total += $shown
    $script:Rows.Add([PSCustomObject]@{ Target = $Label; Scope = $Scope; Bytes = $shown; Files = $files.Count; Locked = $locked })
}

foreach ($p in @($LogPath, (Split-Path $StatusFile -Parent))) {
    if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$started = Get-Date
$freeBefore = Get-FreeBytes

# Mount points of attached profile disks (UPD and FSLogix attach to C:\Users\<user>).
$profileMounts = @(foreach ($disk in (Get-Disk | Where-Object { $_.BusType -eq 'File Backed Virtual' })) {
        foreach ($partition in (Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)) {
            foreach ($ap in @($partition.AccessPaths)) {
                if ($ap -and $ap -notmatch '^\\\\\?\\Volume') { $ap.TrimEnd('\') }
            }
        }
    })

Write-ReportHeader 'SESSION HOST DISK CLEANUP'
Write-ReportLine ('Server   : ' + $env:COMPUTERNAME)
Write-ReportLine ('Started  : ' + $started.ToString('yyyy-MM-dd HH:mm:ss'))
Write-ReportLine ('Mode     : ' + $(if ($Execute) { 'EXECUTE' } else { 'DRY RUN' })) $(if ($Execute) { 'Yellow' } else { 'Green' })
Write-ReportLine ('Free     : {0}   target: {1} GB' -f (Format-Size $freeBefore), $MinFreeGB)
Write-ReportLine ('Attached profile disks: ' + $profileMounts.Count)

Write-ReportHeader "SYSTEM DRIVE $drive"
$pd = $env:ProgramData
$win = $env:SystemRoot

Write-ReportSection 'Installer caches'
Invoke-CleanupTarget 'Adobe ARM: old updates' "$pd\Adobe\ARM\*\*.msp", "$pd\Adobe\ARM\*\*.msi" -KeepNewest $KeepAdobeUpdates
Invoke-CleanupTarget 'Adobe: temporary downloads' "$pd\Adobe\ARM\*\*.tmp", "$pd\Adobe\Setup\*" -AgeDays 7
Invoke-CleanupTarget 'Windows Update downloads' "$win\SoftwareDistribution\Download\*" -AgeDays 7
Invoke-CleanupTarget 'Delivery Optimization' "$win\SoftwareDistribution\DeliveryOptimization\*" -AgeDays 7

Write-ReportSection 'Error reports and dumps'
Invoke-CleanupTarget 'WER ReportQueue' "$pd\Microsoft\Windows\WER\ReportQueue\*" -AgeDays 7
Invoke-CleanupTarget 'WER ReportArchive' "$pd\Microsoft\Windows\WER\ReportArchive\*" -AgeDays 7
Invoke-CleanupTarget 'WER Temp' "$pd\Microsoft\Windows\WER\Temp\*" -AgeDays 1
Invoke-CleanupTarget 'Minidump' "$win\Minidump\*" -AgeDays 30
Invoke-CleanupTarget 'LiveKernelReports' "$win\LiveKernelReports\*" -AgeDays 30
Invoke-CleanupTarget 'Kaspersky agent dumps' "${env:ProgramFiles(x86)}\Kaspersky Lab\NetworkAgent\~dumps\*" -AgeDays 14

Write-ReportSection 'Temporary files'
Invoke-CleanupTarget 'Windows\Temp' "$win\Temp\*" -AgeDays $TempAgeDays
Invoke-CleanupTarget 'C:\Temp, C:\tmp' "$drive\Temp\*", "$drive\tmp\*" -AgeDays 30
Invoke-CleanupTarget 'Recycle Bin' "$drive\`$Recycle.Bin\*" -AgeDays 30

Write-ReportSection 'Service and agent logs'
Invoke-CleanupTarget 'Windows\Logs\CBS' "$win\Logs\CBS\*" -AgeDays $LogAgeDays
Invoke-CleanupTarget 'Windows\Logs\DISM' "$win\Logs\DISM\*" -AgeDays $LogAgeDays
Invoke-CleanupTarget 'Windows\Logs\MoSetup' "$win\Logs\MoSetup\*" -AgeDays $LogAgeDays
Invoke-CleanupTarget 'Windows\Panther' "$win\Panther\*" -AgeDays 30
Invoke-CleanupTarget 'Defender: old MPLog' "$pd\Microsoft\Windows Defender\Support\MPLog-*.log" -AgeDays 30
Invoke-CleanupTarget 'Defender: scan history' "$pd\Microsoft\Windows Defender\Scans\History\Results\*" -AgeDays 30
Invoke-CleanupTarget 'Dr.Web: old logs' "$pd\Doctor Web\Logs\*" -AgeDays 30
Invoke-CleanupTarget 'Kaspersky: old traces' "$pd\Kaspersky Lab\*\Trace\*", "$pd\Kaspersky Lab\*\Logs\*" -AgeDays 30
Invoke-CleanupTarget 'IIS logs' "$drive\inetpub\logs\LogFiles\*" -AgeDays 30

Write-ReportSection 'Profile quarantine'
Invoke-CleanupTarget "Quarantine older than $QuarantineAgeDays days" "$QuarantinePath\*" -AgeDays $QuarantineAgeDays

if ($IncludeProfiles) {
    Write-ReportHeader 'INSIDE PROFILE DISKS (protects VHDX from filling up, does not free the system drive)'

    $sessions = @(Get-RdsUserSession)
    $activeUsers = @($sessions | Where-Object { Test-SessionActive $_.State } | ForEach-Object { $_.UserName.ToLower() })
    $userBySession = @{}
    foreach ($s in $sessions) { $userBySession[$s.SessionId] = $s.UserName.ToLower() }
    $acrobatUsers = @(Get-Process -Name 'Acrobat', 'AcroCEF', 'AcroRd32' -ErrorAction SilentlyContinue |
        Where-Object { $userBySession.ContainsKey($_.SessionId) } | ForEach-Object { $userBySession[$_.SessionId] } | Sort-Object -Unique)
    if ($acrobatUsers) { Write-ReportLine ('  Users with Acrobat running (Acrobat cache skipped): ' + $acrobatUsers.Count) Yellow }

    $targets = @($profileMounts | Where-Object { $activeUsers -notcontains (Split-Path $_ -Leaf).ToLower() })
    $acroTargets = @($targets | Where-Object { $acrobatUsers -notcontains (Split-Path $_ -Leaf).ToLower() })
    Write-ReportLine ('  Profiles processed: {0} of {1} (active sessions skipped)' -f $targets.Count, $profileMounts.Count)

    foreach ($group in @(
            @{ Label = 'Crash dumps'; Sub = 'AppData\Local\CrashDumps\*'; Age = 1; Acrobat = $false }
            @{ Label = 'User WER'; Sub = 'AppData\Local\Microsoft\Windows\WER\*'; Age = 1; Acrobat = $false }
            @{ Label = 'INetCache'; Sub = 'AppData\Local\Microsoft\Windows\INetCache\*'; Age = 1; Acrobat = $false }
            @{ Label = 'Explorer thumbnails'; Sub = 'AppData\Local\Microsoft\Windows\Explorer\thumbcache*'; Age = 1; Acrobat = $false }
            @{ Label = 'Edge cache'; Sub = 'AppData\Local\Microsoft\Edge\User Data\*\Cache\*'; Age = 1; Acrobat = $false }
            @{ Label = 'Acrobat AcroCef cache'; Sub = 'AppData\LocalLow\Adobe\AcroCef\DC\Acrobat\Cache\*'; Age = 1; Acrobat = $true }
            @{ Label = 'User Adobe ARM'; Sub = 'AppData\Local\Adobe\ARM\*'; Age = 7; Acrobat = $true }
        )) {
        $source = if ($group.Acrobat) { $acroTargets } else { $targets }
        $paths = @($source | ForEach-Object { Join-Path $_ $group.Sub })
        if ($paths) { Invoke-CleanupTarget $group.Label $paths -AgeDays $group.Age -Scope 'ProfileDisk' }
    }
}

if ($Deep) {
    Write-ReportHeader 'DEEP CLEANUP (manual runs only)'
    Write-ReportLine '  DISM /StartComponentCleanup takes 20-60 minutes and loads the disk.' Yellow
    if ($Execute) {
        & Dism.exe /Online /Cleanup-Image /StartComponentCleanup 2>&1 | ForEach-Object { if ("$_".Trim()) { Write-ReportLine ('    ' + $_) } }
    }
    else { Write-ReportLine '  Dry run: DISM not started.' DarkGray }
}

$freeAfter = Get-FreeBytes
$freeGB = [Math]::Round($freeAfter / 1GB, 2)
$status = if ($freeGB -lt $MinFreeGB) { 'LOW' } else { 'OK' }

Write-ReportHeader 'SUMMARY'
Write-ReportLine ('  {0,-44} {1,12}' -f $(if ($Execute) { 'Freed' } else { 'Can be freed' }), (Format-Size $script:Total)) Cyan
foreach ($g in ($script:Rows | Group-Object Scope)) {
    Write-ReportLine ('    {0,-42} {1,12}' -f $g.Name, (Format-Size ($g.Group | Measure-Object Bytes -Sum).Sum))
}
Write-ReportLine ('  {0,-44} {1,12}' -f "Free on $drive before", (Format-Size $freeBefore))
Write-ReportLine ('  {0,-44} {1,12}' -f "Free on $drive after", (Format-Size $freeAfter)) $(if ($status -eq 'LOW') { 'Red' } else { 'Green' })
if ($status -eq 'LOW') {
    Write-ReportLine ''
    Write-ReportLine ("  Free space {0} GB is below the {1} GB target. Routine cleanup is not enough; consider:" -f $freeGB, $MinFreeGB) Red
    Write-ReportLine '    - uninstalling old 1C:Enterprise platform versions (Programs and Features)' Yellow
    Write-ReportLine '    - DISM /StartComponentCleanup in a maintenance window (-Deep -Execute)' Yellow
    Write-ReportLine '    - Get-DiskUsageReport.ps1 to find what else grows; extending the disk' Yellow
}

$inv = [Globalization.CultureInfo]::InvariantCulture
$statusLine = 'time={0:yyyy-MM-ddTHH:mm:ss} status={1} free_gb={2} freed_mb={3} targets={4}' -f (Get-Date), $status,
    $freeGB.ToString('0.00', $inv), [Math]::Round($script:Total / 1MB).ToString($inv), $script:Rows.Count
if ($Execute) { [IO.File]::WriteAllText($StatusFile, $statusLine, (New-Object Text.UTF8Encoding($false))) }
Write-ReportLine ''
Write-ReportLine ('  Monitoring status: ' + $statusLine + $(if ($Execute) { "  -> $StatusFile" } else { '  (not written in dry run)' })) DarkGray

$report = Save-Report -LogPath $LogPath -Prefix ('SessionHostCleanup_' + $(if ($Execute) { 'EXEC' } else { 'DRY' }))
Write-ReportLine ('  Report: ' + $report + '   Duration: ' + [Math]::Round(((Get-Date) - $started).TotalMinutes, 1) + ' min') DarkGray
if (-not $Execute) { Write-ReportLine '  Dry run. Add -Execute to delete.' Yellow }

$script:Rows
