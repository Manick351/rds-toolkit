<#
.SYNOPSIS
    Read-only analysis of what fills the system drive of a Windows / RDS server, with cleanup candidates by risk.

.DESCRIPTION
    Scans the drive once (metadata only) and aggregates sizes for every folder in the same pass, then reports:

      - server role: RDS services, UPD / FSLogix configuration, sessions, loaded profiles;
      - drives, VSS shadow storage, large files in the drive root (pagefile, dumps);
      - top folders of the drive, Windows and ProgramData;
      - temp folders, logs, OS upgrade leftovers, event logs;
      - orphaned packages in Windows\Installer (not referenced by any installed product or patch);
      - WinSxS (optionally DISM /AnalyzeComponentStore);
      - 1C:Enterprise platform versions in use and installed, cluster service data (if present);
      - user profiles (inactive > N days), caches inside profiles;
      - log files older than 90 days, largest files, non-standard root folders.

    Every finding is classified: SAFE (clean now), CAUTION (needs review or approval),
    WINDOW (maintenance window only). Nothing is changed. Results are saved as a text report and CSV files.

.PARAMETER Drive
    Drive to analyze. Default: system drive.

.PARAMETER OutputPath
    Folder for the report and CSV files. Default: C:\ProgramData\rds-toolkit\reports.

.PARAMETER BigFileThresholdMB
    Threshold for the largest files list. Default: 200.

.PARAMETER StaleProfileDays
    Profiles not used for this many days are reported as inactive. Default: 60.

.PARAMETER SkipDismAnalyze
    Do not run DISM /AnalyzeComponentStore (it takes 3-10 minutes).

.EXAMPLE
    .\Get-DiskUsageReport.ps1 -SkipDismAnalyze
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$Drive = $env:SystemDrive,
    [string]$OutputPath = (Join-Path $env:ProgramData 'rds-toolkit\reports'),
    [ValidateRange(1, 100000)][int]$BigFileThresholdMB = 200,
    [ValidateRange(1, 3650)][int]$StaleProfileDays = 60,
    [switch]$SkipDismAnalyze
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')

$root = "$Drive\"
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$script:Candidates = New-Object System.Collections.Generic.List[object]
$script:DirBytes = @{}
$script:DirFiles = @{}
$script:AllFiles = New-Object System.Collections.Generic.List[object]

function Add-Candidate {
    param([string]$Name, [string]$Path, [double]$Bytes, [ValidateSet('SAFE', 'CAUTION', 'WINDOW')][string]$Risk, [string]$Note)
    if ($Bytes -le 1MB) { return }
    $script:Candidates.Add([PSCustomObject]@{ Risk = $Risk; Name = $Name; Path = $Path; Bytes = [double]$Bytes; Note = $Note })
}

function Get-SizeUnder {
    param([string]$Path)
    $key = $Path.TrimEnd('\').ToLowerInvariant()
    if ($script:DirBytes.ContainsKey($key)) { return $script:DirBytes[$key] }
    return [double]0
}

function Get-CountUnder {
    param([string]$Path)
    $key = $Path.TrimEnd('\').ToLowerInvariant()
    if ($script:DirFiles.ContainsKey($key)) { return $script:DirFiles[$key] }
    return 0
}

function Show-Folder {
    param([string]$Label, [string]$Path, [string]$Risk, [string]$Note)
    if (-not (Test-Path -LiteralPath $Path)) { Write-ReportLine ('  {0,-50} {1}' -f $Label, '-- absent --') DarkGray; return }
    $bytes = Get-SizeUnder $Path
    $color = if ($bytes -ge 3GB) { 'Red' } elseif ($bytes -ge 1GB) { 'Yellow' } else { 'Gray' }
    Write-ReportLine ('  {0,-50} {1,12}  ({2} files)' -f $Label, (Format-Size $bytes), (Get-CountUnder $Path)) $color
    if ($Risk) { Add-Candidate $Label $Path $bytes $Risk $Note }
}

function Show-TopFolders {
    param([string]$Path, [int]$Top = 20, [double]$Yellow = 1GB, [double]$Red = 5GB)
    Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Bytes = Get-SizeUnder $_.FullName } } |
        Sort-Object Bytes -Descending | Select-Object -First $Top | ForEach-Object {
            $color = if ($_.Bytes -ge $Red) { 'Red' } elseif ($_.Bytes -ge $Yellow) { 'Yellow' } else { 'Gray' }
            Write-ReportLine ('  {0,-50} {1,12}' -f $_.Name, (Format-Size $_.Bytes)) $color
        }
}

if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$started = Get-Date
$os = Get-CimInstance Win32_OperatingSystem

Write-ReportHeader "DISK USAGE ANALYSIS $Drive (read-only, nothing is deleted)"
Write-ReportLine ('Server  : ' + $env:COMPUTERNAME)
Write-ReportLine ('Run as  : ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name + $(if (Test-IsAdministrator) { '' } else { '  (NOT elevated: some folders will be unreadable)' }))
Write-ReportLine ('OS      : {0} build {1}, uptime {2:N1} days, RAM {3:N1} GB' -f $os.Caption, $os.BuildNumber, ((Get-Date) - $os.LastBootUpTime).TotalDays, ($os.TotalVisibleMemorySize / 1MB))

Write-ReportHeader 'SERVER ROLE AND SESSIONS'
$services = foreach ($name in 'TermService', 'SessionEnv', 'UmRdpService', 'RDMS', 'TScPubRPC', 'Tssdis') {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) { '{0}={1}' -f $svc.Name, $svc.Status }
}
Write-ReportLine ('RDS services: ' + ($services -join '  '))
$fslogix = Get-ItemProperty 'HKLM:\SOFTWARE\FSLogix\Profiles' -ErrorAction SilentlyContinue
if ($fslogix -and $fslogix.PSObject.Properties['Enabled'] -and $fslogix.Enabled -eq 1) {
    $locations = if ($fslogix.PSObject.Properties['VHDLocations']) { $fslogix.VHDLocations -join ';' } else { '(not set)' }
    Write-ReportLine ('FSLogix     : enabled, VHDLocations = ' + $locations) Yellow
}
else { Write-ReportLine 'FSLogix     : not configured' }
$upd = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters' -ErrorAction SilentlyContinue
if ($upd -and $upd.PSObject.Properties['UvhdRootPath'] -and $upd.UvhdRootPath) { Write-ReportLine ('UPD         : enabled, path = ' + $upd.UvhdRootPath) Yellow }
else { Write-ReportLine 'UPD         : not detected' }
$sessions = @(Get-RdsUserSession)
Write-ReportLine ('Sessions    : {0} ({1} active)' -f $sessions.Count, @($sessions | Where-Object { Test-SessionActive $_.State }).Count)
Get-CimInstance Win32_UserProfile | Where-Object { $_.Loaded -and -not $_.Special } |
    ForEach-Object { Write-ReportLine ('  loaded profile (do not touch): ' + $_.LocalPath) Yellow }

Write-ReportHeader 'DRIVES AND SHADOW COPIES'
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $pct = if ($_.Size) { [Math]::Round($_.FreeSpace / $_.Size * 100, 1) } else { 0 }
    $color = if ($pct -lt 10) { 'Red' } elseif ($pct -lt 20) { 'Yellow' } else { 'Green' }
    Write-ReportLine ('  {0}  size {1,10}  free {2,10} ({3}%)  {4}' -f $_.DeviceID, (Format-Size $_.Size), (Format-Size $_.FreeSpace), $pct, $_.VolumeName) $color
}
Write-ReportSection 'VSS shadow storage (a frequent hidden consumer)'
& vssadmin.exe list shadowstorage 2>&1 | ForEach-Object { if ("$_".Trim()) { Write-ReportLine ('  ' + $_) } }

Write-ReportHeader "FULL SCAN OF $root (metadata only, one pass)"
Write-ReportLine 'Enumerating files, this can take a few minutes...' DarkYellow
$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue)) {
    $script:AllFiles.Add([PSCustomObject]@{ P = $f.FullName; L = [double]$f.Length; T = $f.LastWriteTime })
    # Add the size to every parent folder, so folder totals are dictionary lookups later.
    $dir = $f.DirectoryName
    while ($dir -and $dir.Length -gt 3) {
        $key = $dir.ToLowerInvariant()
        $script:DirBytes[$key] = $script:DirBytes[$key] + [double]$f.Length
        $script:DirFiles[$key] = $script:DirFiles[$key] + 1
        $dir = [IO.Path]::GetDirectoryName($dir)
    }
}
$sw.Stop()
$totalBytes = ($script:AllFiles | Measure-Object L -Sum).Sum
Write-ReportLine ('Files: {0:N0}   logical size: {1}   scan time: {2:N0} s' -f $script:AllFiles.Count, (Format-Size $totalBytes), $sw.Elapsed.TotalSeconds) Green

Write-ReportHeader "LARGE FILES IN $root"
foreach ($f in (Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue | Sort-Object Length -Descending)) {
    $mark = ''; $risk = $null
    switch -Wildcard ($f.Name) {
        'pagefile.sys' { $mark = '<- page file, do not touch' }
        'swapfile.sys' { $mark = '<- system, do not touch' }
        'hiberfil.sys' { $mark = '<- hibernation, not needed on a server (powercfg /h off)'; $risk = 'SAFE' }
        '*.dmp'        { $mark = '<- memory dump, safe to delete'; $risk = 'SAFE' }
    }
    Write-ReportLine ('  {0,-30} {1,12}  {2:yyyy-MM-dd}  {3}' -f $f.Name, (Format-Size $f.Length), $f.LastWriteTime, $mark) $(if ($risk) { 'Green' } elseif ($mark) { 'Red' } else { 'Gray' })
    if ($risk) { Add-Candidate $f.Name $f.FullName $f.Length $risk 'file in the drive root' }
}

Write-ReportHeader "TOP FOLDERS: $root"
Show-TopFolders $root
Write-ReportHeader 'TOP FOLDERS: Windows'
Show-TopFolders $env:SystemRoot -Red 4GB

$win = $env:SystemRoot
$pd = $env:ProgramData
Write-ReportHeader 'TEMP FILES AND LOGS'
Show-Folder 'Windows\Temp' "$win\Temp" SAFE 'system temp'
Show-Folder 'SoftwareDistribution\Download' "$win\SoftwareDistribution\Download" SAFE 'Windows Update cache, re-created'
Show-Folder 'Windows\Logs\CBS' "$win\Logs\CBS" SAFE 'servicing logs'
Show-Folder 'Windows\Logs\DISM' "$win\Logs\DISM" SAFE 'DISM logs'
Show-Folder 'Windows\Panther' "$win\Panther" SAFE 'setup logs'
Show-Folder 'Windows\Minidump' "$win\Minidump" SAFE 'small dumps'
Show-Folder 'Windows\LiveKernelReports' "$win\LiveKernelReports" SAFE 'kernel reports'
Show-Folder 'WER ReportQueue' "$pd\Microsoft\Windows\WER\ReportQueue" SAFE 'error reports'
Show-Folder 'WER ReportArchive' "$pd\Microsoft\Windows\WER\ReportArchive" SAFE 'error report archive'
Show-Folder '$Recycle.Bin' "$root`$Recycle.Bin" SAFE 'users recycle bins'
Show-Folder 'inetpub\logs' "$root`inetpub\logs\LogFiles" CAUTION 'IIS logs: check retention requirements'
foreach ($leftover in 'Windows.old', '$Windows.~BT', '$Windows.~WS', 'ESD', '$SysReset') {
    $p = Join-Path $root $leftover
    if (Test-Path -LiteralPath $p) { Show-Folder "OS upgrade leftover: $leftover" $p SAFE 'previous OS installation files' }
}
$eventLogs = "$win\System32\winevt\Logs"
Write-ReportSection ('Event logs: ' + (Format-Size (Get-SizeUnder $eventLogs)))
Get-ChildItem -LiteralPath $eventLogs -File -Force -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 8 |
    ForEach-Object { Write-ReportLine ('    {0,-56} {1,12}' -f $_.Name, (Format-Size $_.Length)) }
Add-Candidate 'Event logs' $eventLogs (Get-SizeUnder $eventLogs) CAUTION 'audit data: agree with security before clearing'

Write-ReportHeader 'WINDOWS\INSTALLER: ORPHANED PACKAGES'
$used = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Products\*\InstallProperties',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\*\Patches\*') {
    Get-ItemProperty $k -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSObject.Properties['LocalPackage'] -and $_.LocalPackage) { [void]$used.Add($_.LocalPackage) }
    }
}
$packages = @(Get-ChildItem -LiteralPath "$win\Installer" -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msi', '.msp' })
$orphans = @($packages | Where-Object { -not $used.Contains($_.FullName) })
$orphanBytes = ($orphans | Measure-Object Length -Sum).Sum
Write-ReportLine ('  MSI/MSP packages: {0} ({1}), registered: {2}, orphaned: {3} ({4})' -f $packages.Count, (Format-Size ($packages | Measure-Object Length -Sum).Sum), $used.Count, $orphans.Count, (Format-Size $orphanBytes)) Yellow
if ($orphans) {
    $csv = Join-Path $OutputPath "installer_orphans_$($env:COMPUTERNAME)_$stamp.csv"
    $orphans | Select-Object FullName, Length, LastWriteTime | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    Write-ReportLine ('  List: ' + $csv) Green
    Write-ReportLine '  Remove only AFTER uninstalling old software versions, or their uninstall may break.' Yellow
    Add-Candidate 'Windows\Installer orphans' "$win\Installer" $orphanBytes WINDOW 'delete by CSV after uninstalling old versions'
}

Write-ReportHeader 'WINSXS'
Write-ReportLine ('  Logical size: {0} (real usage is lower: most files are hard links)' -f (Format-Size (Get-SizeUnder "$win\WinSxS")))
if (-not $SkipDismAnalyze) {
    Write-ReportLine '  DISM /AnalyzeComponentStore (read-only, 3-10 minutes)...' DarkYellow
    & Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1 | ForEach-Object { if ("$_".Trim()) { Write-ReportLine ('  ' + $_) } }
}

$oneCServices = @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'ragent|rmngr|rphost|1cv8' })
$platformRoots = @("$root`Program Files\1cv8", "$root`Program Files (x86)\1cv8", "$root`Program Files (x86)\1cv82") | Where-Object { Test-Path -LiteralPath $_ }
if ($oneCServices -or $platformRoots) {
    Write-ReportHeader '1C:ENTERPRISE PLATFORM'
    $activeVersions = @()
    $srvinfo = @()
    foreach ($s in $oneCServices) {
        Write-ReportLine ('  Service {0} [{1}/{2}]: {3}' -f $s.Name, $s.State, $s.StartMode, $s.PathName) Yellow
        if ($s.PathName -match '1cv8\\(\d+\.\d+\.\d+\.\d+)') { $activeVersions += $Matches[1] }
        if ($s.PathName -match '-d\s+"([^"]+)"' -or $s.PathName -match '-d\s+(\S+)') { $srvinfo += $Matches[1] }
    }
    if ($activeVersions) { Write-ReportLine ('  VERSION IN USE (keep): ' + (($activeVersions | Sort-Object -Unique) -join ', ')) Red }
    foreach ($pr in $platformRoots) {
        Write-ReportLine ('  ' + $pr) White
        Get-ChildItem -LiteralPath $pr -Directory -Force | ForEach-Object {
            $bytes = Get-SizeUnder $_.FullName
            $isVersion = $_.Name -match '^\d+\.\d+\.\d+\.\d+$'
            $inUse = $activeVersions -contains $_.Name
            $tag = if ($inUse) { '<- used by a service' } elseif ($isVersion) { '<- uninstall candidate' } else { '' }
            Write-ReportLine ('    {0,-24} {1,12}  {2:yyyy-MM-dd}  {3}' -f $_.Name, (Format-Size $bytes), $_.LastWriteTime, $tag) $(if ($inUse) { 'Red' } elseif ($isVersion) { 'Green' } else { 'Gray' })
            if ($isVersion -and -not $inUse) { Add-Candidate "1C platform $($_.Name)" $_.FullName $bytes WINDOW 'uninstall via Programs and Features; keep current and one previous' }
        }
    }
    foreach ($sp in ($srvinfo | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $sp)) { continue }
        Write-ReportSection ('Cluster data ' + $sp + ': ' + (Format-Size (Get-SizeUnder $sp)))
        Get-ChildItem -LiteralPath $sp -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(1Cv8Log|snccntx|1Cv8FTxt)' } | ForEach-Object {
                $bytes = Get-SizeUnder $_.FullName
                if ($bytes -lt 10MB) { return }
                $note = switch -Regex ($_.Name) {
                    '1Cv8Log'  { 'event log: clean only from the cluster console, it is audit data' }
                    'snccntx'  { 'session contexts: only with the cluster stopped' }
                    default    { 'full-text index: rebuilt by the platform' }
                }
                Write-ReportLine ('    {0,-60} {1,12}  {2}' -f $_.FullName, (Format-Size $bytes), $note) Yellow
                Add-Candidate "1C $($_.Name)" $_.FullName $bytes WINDOW $note
            }
    }
}

Write-ReportHeader 'USER PROFILES'
$staleCut = (Get-Date).AddDays(-$StaleProfileDays)
$staleBytes = [double]0
foreach ($p in (Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | Sort-Object LastUseTime)) {
    if (-not (Test-Path -LiteralPath $p.LocalPath)) { continue }
    $bytes = Get-SizeUnder $p.LocalPath
    $stale = $p.LastUseTime -and $p.LastUseTime -lt $staleCut -and -not $p.Loaded
    if ($stale) { $staleBytes += $bytes }
    $status = if ($p.Loaded) { 'LOADED - do not touch' } elseif ($stale) { "inactive > $StaleProfileDays days" } else { '' }
    Write-ReportLine ('  {0,-26} {1,10}  last use {2}  {3}' -f (Split-Path $p.LocalPath -Leaf), (Format-Size $bytes), $(if ($p.LastUseTime) { $p.LastUseTime.ToString('yyyy-MM-dd') } else { 'n/a' }), $status) $(if ($p.Loaded) { 'Red' } elseif ($stale) { 'Green' } else { 'Gray' })
}
Write-ReportLine ('  Inactive profiles total: ' + (Format-Size $staleBytes)) Yellow
Write-ReportLine '  Remove profiles only via System Properties > User Profiles (or Remove-CimInstance), never by deleting folders.' Yellow
Add-Candidate 'Inactive profiles' "$root`Users" $staleBytes CAUTION 'confirm with owners, remove via profile management'

Write-ReportSection 'Caches inside local profiles'
$usersPrefix = "$root`Users\*\"
foreach ($c in @(
        @{ Name = '1C cache (Local)'; Pattern = 'AppData\Local\1C\*'; Risk = 'SAFE'; Note = 're-created by the client' }
        @{ Name = '1C (Roaming)'; Pattern = 'AppData\Roaming\1C\*'; Risk = 'CAUTION'; Note = 'contains user settings' }
        @{ Name = 'Profile Temp'; Pattern = 'AppData\Local\Temp\*'; Risk = 'SAFE'; Note = 'temporary files' }
        @{ Name = 'Chrome cache'; Pattern = 'AppData\Local\Google\Chrome\User Data\*\Cache\*'; Risk = 'SAFE'; Note = 're-created' }
        @{ Name = 'Edge cache'; Pattern = 'AppData\Local\Microsoft\Edge\User Data\*\Cache\*'; Risk = 'SAFE'; Note = 're-created' }
        @{ Name = 'INetCache'; Pattern = 'AppData\Local\Microsoft\Windows\INetCache\*'; Risk = 'SAFE'; Note = 're-created' }
        @{ Name = 'Crash dumps'; Pattern = 'AppData\Local\CrashDumps\*'; Risk = 'SAFE'; Note = 'application dumps' }
        @{ Name = 'Downloads'; Pattern = 'Downloads\*'; Risk = 'CAUTION'; Note = 'user data: only with consent' }
    )) {
    $pattern = $usersPrefix + $c.Pattern
    $matched = @($script:AllFiles | Where-Object { $_.P -like $pattern })
    if (-not $matched) { continue }
    $bytes = ($matched | Measure-Object L -Sum).Sum
    Write-ReportLine ('  {0,-28} {1,12}  ({2} files)' -f $c.Name, (Format-Size $bytes), $matched.Count) $(if ($bytes -ge 500MB) { 'Yellow' } else { 'Gray' })
    Add-Candidate $c.Name $pattern $bytes $c.Risk $c.Note
}

Write-ReportHeader 'TOP FOLDERS: ProgramData'
Show-TopFolders $pd -Yellow 500MB -Red 2GB
Write-ReportSection 'Known agent log stores'
foreach ($agent in "$pd\Kaspersky Lab", "$pd\Microsoft\Windows Defender\Scans", "$pd\GLPI-Agent", "$pd\Zabbix", "$root`Zabbix", "$pd\Package Cache", "$pd\VMware") {
    if (-not (Test-Path -LiteralPath $agent)) { continue }
    $bytes = Get-SizeUnder $agent
    Write-ReportLine ('  {0,-60} {1,12}' -f $agent, (Format-Size $bytes)) $(if ($bytes -ge 300MB) { 'Yellow' } else { 'Gray' })
    if ($bytes -ge 100MB) { Add-Candidate (Split-Path $agent -Leaf) $agent $bytes CAUTION 'agent logs/cache: clean per vendor documentation' }
}

Write-ReportHeader 'LOG FILES OLDER THAN 90 DAYS (> 10 MB)'
$logCut = (Get-Date).AddDays(-90)
$oldLogs = @($script:AllFiles | Where-Object { $_.L -ge 10MB -and $_.T -lt $logCut -and $_.P -match '\.(log|txt|etl|blg|trc|dmp|old|bak)$' } | Sort-Object L -Descending)
if ($oldLogs) {
    $bytes = ($oldLogs | Measure-Object L -Sum).Sum
    Write-ReportLine ('  {0} files, {1}' -f $oldLogs.Count, (Format-Size $bytes)) Yellow
    $oldLogs | Select-Object -First 20 | ForEach-Object { Write-ReportLine ('    {0,10}  {1:yyyy-MM-dd}  {2}' -f (Format-Size $_.L), $_.T, $_.P) }
    $csv = Join-Path $OutputPath "old_logs_$($env:COMPUTERNAME)_$stamp.csv"
    $oldLogs | Select-Object @{ n = 'Path'; e = { $_.P } }, @{ n = 'Bytes'; e = { $_.L } }, @{ n = 'Modified'; e = { $_.T } } | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    Write-ReportLine ('  Full list: ' + $csv) Green
    Add-Candidate 'Old log files (> 90 days)' $csv $bytes CAUTION 'check they are not written to; exclude 1C event logs'
}
else { Write-ReportLine '  none' }

Write-ReportHeader "LARGEST FILES (> $BigFileThresholdMB MB)"
$big = @($script:AllFiles | Where-Object { $_.L -ge ($BigFileThresholdMB * 1MB) } | Sort-Object L -Descending)
$big | Select-Object -First 30 | ForEach-Object { Write-ReportLine ('    {0,10}  {1:yyyy-MM-dd}  {2}' -f (Format-Size $_.L), $_.T, $_.P) }
if ($big) {
    $csv = Join-Path $OutputPath "big_files_$($env:COMPUTERNAME)_$stamp.csv"
    $big | Select-Object @{ n = 'Path'; e = { $_.P } }, @{ n = 'Bytes'; e = { $_.L } }, @{ n = 'Modified'; e = { $_.T } } | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    Write-ReportLine ('  Full list: ' + $csv) Green
}

Write-ReportHeader 'NON-STANDARD ROOT FOLDERS'
$known = 'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', 'Users', 'PerfLogs', '$Recycle.Bin',
    'System Volume Information', 'Recovery', '$WinREAgent', 'inetpub', 'Temp', 'tmp'
Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $known -notcontains $_.Name } | ForEach-Object {
    $bytes = Get-SizeUnder $_.FullName
    if ($bytes -lt 1MB) { return }
    Write-ReportLine ('  {0,-50} {1,12}  modified {2:yyyy-MM-dd}' -f $_.Name, (Format-Size $bytes), $_.LastWriteTime) Yellow
    Add-Candidate "Root folder $($_.Name)" $_.FullName $bytes CAUTION 'data in the drive root: find the owner, move to a file share'
}

Write-ReportHeader 'CLEANUP CANDIDATES'
$labels = @{ SAFE = 'SAFE - can be cleaned now'; CAUTION = 'CAUTION - needs review or approval'; WINDOW = 'MAINTENANCE WINDOW ONLY' }
$colors = @{ SAFE = 'Green'; CAUTION = 'Yellow'; WINDOW = 'Magenta' }
$totals = @{}
foreach ($risk in 'SAFE', 'CAUTION', 'WINDOW') {
    $set = @($script:Candidates | Where-Object Risk -eq $risk | Sort-Object Bytes -Descending)
    $totals[$risk] = [double]($set | Measure-Object Bytes -Sum).Sum
    if (-not $set) { continue }
    Write-ReportSection ('{0}   TOTAL: {1}' -f $labels[$risk], (Format-Size $totals[$risk]))
    foreach ($c in $set) {
        Write-ReportLine ('  {0,10}  {1}' -f (Format-Size $c.Bytes), $c.Name) $colors[$risk]
        Write-ReportLine ('              {0} - {1}' -f $c.Path, $c.Note) DarkGray
    }
}
Write-ReportLine ''
Write-ReportLine ('  Safe now: {0}   after approval: {1}   maintenance window: {2}' -f (Format-Size $totals.SAFE), (Format-Size $totals.CAUTION), (Format-Size $totals.WINDOW)) Cyan

$candidatesCsv = Join-Path $OutputPath "cleanup_candidates_$($env:COMPUTERNAME)_$stamp.csv"
$script:Candidates | Sort-Object Risk, @{ Expression = 'Bytes'; Descending = $true } |
    Select-Object Risk, Name, Path, @{ n = 'SizeGB'; e = { [Math]::Round($_.Bytes / 1GB, 3) } }, Note |
    Export-Csv -LiteralPath $candidatesCsv -NoTypeInformation -Encoding UTF8
$report = Save-Report -LogPath $OutputPath -Prefix 'DiskUsage'
Write-ReportLine ''
Write-ReportLine ('Report: {0}   Candidates: {1}   Duration: {2:N1} min' -f $report, $candidatesCsv, ((Get-Date) - $started).TotalMinutes) Green
Write-ReportLine 'Nothing was changed on this server.' Green

$script:Candidates
