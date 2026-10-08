<#
.SYNOPSIS
    Diagnoses memory pressure on an RDS session host: who holds the memory, why it is not released,
    and what in the event logs points to resource exhaustion. Read-only.

.DESCRIPTION
    Snapshot mode (default) reports:
      - physical memory, commit charge, pools, paging, handles and threads;
      - page file configuration (system-managed page file on a full disk turns pressure into a hang);
      - memory per session, with the total held by disconnected sessions;
      - top processes by working set, totals by process name, handle leaders (leak indicator);
      - RDS session time limit policies (no disconnect limit = disconnected sessions live forever);
      - resource-related events for the last 7 days (unexpected shutdowns, resource exhaustion,
        User Profile Service, application crashes);
      - Security log mode and CrashOnAuditFail (a full audit log can block all non-admin logons);
      - registry hive sizes.

    Watch mode (-Watch) samples counters every -IntervalSeconds into a CSV and, when RAM usage
    crosses -AlertThresholdPercent, appends the top 25 processes with session and user to a second CSV.

.PARAMETER Watch
    Sample continuously instead of a one-time report.

.PARAMETER IntervalSeconds
    Watch mode sampling interval. Default: 60.

.PARAMETER DurationHours
    Watch mode duration. Default: 8.

.PARAMETER AlertThresholdPercent
    Watch mode: RAM usage that triggers a top-process dump. Default: 90.

.PARAMETER OutputPath
    Folder for reports and CSV files.

.EXAMPLE
    .\Get-MemoryPressureReport.ps1

.EXAMPLE
    .\Get-MemoryPressureReport.ps1 -Watch -IntervalSeconds 30 -DurationHours 10
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Watch,
    [ValidateRange(5, 3600)][int]$IntervalSeconds = 60,
    [ValidateRange(1, 168)][int]$DurationHours = 8,
    [ValidateRange(50, 100)][int]$AlertThresholdPercent = 90,
    [string]$OutputPath = (Join-Path $env:ProgramData 'rds-toolkit\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')

function Get-SessionMap {
    $map = @{}
    foreach ($s in (Get-RdsUserSession)) { $map[$s.SessionId] = $s }
    return $map
}

function Get-MemorySnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $counters = @{}
    $samples = (Get-Counter -ErrorAction SilentlyContinue -Counter @(
            '\Memory\Available MBytes', '\Memory\Committed Bytes', '\Memory\Commit Limit',
            '\Memory\Pool Paged Bytes', '\Memory\Pool Nonpaged Bytes', '\Memory\Pages/sec',
            '\Paging File(_Total)\% Usage', '\System\Processor Queue Length')).CounterSamples
    foreach ($s in $samples) { $counters[($s.Path -split '\\')[-1]] = $s.CookedValue }
    $get = { param($name) if ($counters.ContainsKey($name)) { [double]$counters[$name] } else { [double]0 } }

    $totalMB = $os.TotalVisibleMemorySize / 1KB
    $availableMB = & $get 'available mbytes'
    $processes = Get-Process
    [PSCustomObject]@{
        Time            = Get-Date
        TotalMB         = [Math]::Round($totalMB)
        AvailableMB     = [Math]::Round($availableMB)
        # "Used" excludes standby cache: Available = free + standby, which the OS hands out on demand.
        UsedPercent     = if ($totalMB) { [Math]::Round((1 - $availableMB / $totalMB) * 100, 1) } else { 0 }
        CommittedMB     = [Math]::Round((& $get 'committed bytes') / 1MB)
        CommitLimitMB   = [Math]::Round((& $get 'commit limit') / 1MB)
        CommitPercent   = if (& $get 'commit limit') { [Math]::Round((& $get 'committed bytes') / (& $get 'commit limit') * 100, 1) } else { 0 }
        PoolPagedMB     = [Math]::Round((& $get 'pool paged bytes') / 1MB)
        PoolNonpagedMB  = [Math]::Round((& $get 'pool nonpaged bytes') / 1MB)
        PagesPerSec     = [Math]::Round((& $get 'pages/sec'))
        PageFilePercent = [Math]::Round((& $get '% usage'), 1)
        CpuQueue        = [Math]::Round((& $get 'processor queue length'))
        Processes       = @($processes).Count
        Sessions        = (Get-SessionMap).Count
        Handles         = ($processes | Measure-Object HandleCount -Sum).Sum
        Threads         = ($processes | ForEach-Object { $_.Threads.Count } | Measure-Object -Sum).Sum
    }
}

function Get-Level {
    param([double]$Value, [double]$Warn, [double]$Crit)
    if ($Value -ge $Crit) { 'Red' } elseif ($Value -ge $Warn) { 'Yellow' } else { 'Green' }
}

if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'

if ($Watch) {
    $csv = Join-Path $OutputPath "MemWatch_$($env:COMPUTERNAME)_$stamp.csv"
    $topCsv = Join-Path $OutputPath "MemWatch_Top_$($env:COMPUTERNAME)_$stamp.csv"
    Write-Host "Memory watch: every $IntervalSeconds s for $DurationHours h, alert at $AlertThresholdPercent%" -ForegroundColor Cyan
    Write-Host "Samples: $csv`nTop processes on alert: $topCsv`nStop with Ctrl+C" -ForegroundColor DarkGray

    $end = (Get-Date).AddHours($DurationHours)
    while ((Get-Date) -lt $end) {
        $snap = Get-MemorySnapshot
        $snap | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -Append
        Write-Host ('{0:HH:mm:ss}  RAM {1,5:N1}%  avail {2,6} MB  commit {3,5:N1}%  pagefile {4,5:N1}%  pages/s {5,6}  sessions {6,3}' -f
            $snap.Time, $snap.UsedPercent, $snap.AvailableMB, $snap.CommitPercent, $snap.PageFilePercent, $snap.PagesPerSec, $snap.Sessions) -ForegroundColor (Get-Level $snap.UsedPercent 80 $AlertThresholdPercent)

        if ($snap.UsedPercent -ge $AlertThresholdPercent) {
            $map = Get-SessionMap
            Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 25 | ForEach-Object {
                $s = $map[$_.SessionId]
                [PSCustomObject]@{
                    Time = $snap.Time; RamPercent = $snap.UsedPercent; Name = $_.ProcessName; PID = $_.Id; SessionId = $_.SessionId
                    User = if ($s) { $s.UserName } else { '' }; State = if ($s) { $s.State } else { '' }
                    WorkingSetMB = [Math]::Round($_.WorkingSet64 / 1MB); PrivateMB = [Math]::Round($_.PrivateMemorySize64 / 1MB); Handles = $_.HandleCount
                }
            } | Export-Csv -LiteralPath $topCsv -NoTypeInformation -Encoding UTF8 -Append
            Write-Host '          ^ threshold exceeded, top processes saved' -ForegroundColor Red
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return
}

$os = Get-CimInstance Win32_OperatingSystem
Write-ReportHeader 'MEMORY PRESSURE REPORT'
Write-ReportLine ('Server : ' + $env:COMPUTERNAME)
Write-ReportLine ('Uptime : {0:N1} h (boot {1:yyyy-MM-dd HH:mm})' -f ((Get-Date) - $os.LastBootUpTime).TotalHours, $os.LastBootUpTime)

$snap = Get-MemorySnapshot
Write-ReportHeader 'CURRENT STATE'
Write-ReportLine ('  Physical memory        : {0,10:N0} MB' -f $snap.TotalMB)
Write-ReportLine ('  Available (incl. standby): {0,8:N0} MB' -f $snap.AvailableMB)
Write-ReportLine ('  Used                   : {0,10:N1} %' -f $snap.UsedPercent) (Get-Level $snap.UsedPercent 80 90)
Write-ReportLine ('  Commit charge / limit  : {0:N0} / {1:N0} MB ({2:N1} %)' -f $snap.CommittedMB, $snap.CommitLimitMB, $snap.CommitPercent) (Get-Level $snap.CommitPercent 80 90)
Write-ReportLine ('  Paged / nonpaged pool  : {0:N0} / {1:N0} MB' -f $snap.PoolPagedMB, $snap.PoolNonpagedMB)
Write-ReportLine ('  Pages/sec              : {0,10:N0}' -f $snap.PagesPerSec) (Get-Level $snap.PagesPerSec 500 1000)
Write-ReportLine ('  Page file usage        : {0,10:N1} %' -f $snap.PageFilePercent)
Write-ReportLine ('  CPU queue length       : {0,10:N0}' -f $snap.CpuQueue)
Write-ReportLine ('  Processes / threads    : {0} / {1}' -f $snap.Processes, $snap.Threads)
Write-ReportLine ('  Handles                : {0,10:N0}' -f $snap.Handles) (Get-Level $snap.Handles 300000 500000)

Write-ReportHeader 'PAGE FILE'
$cs = Get-CimInstance Win32_ComputerSystem
Write-ReportLine ('  System managed : ' + $cs.AutomaticManagedPagefile) $(if ($cs.AutomaticManagedPagefile) { 'Yellow' } else { 'Gray' })
Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | ForEach-Object { Write-ReportLine ('  Setting : {0}  initial {1} MB  maximum {2} MB' -f $_.Name, $_.InitialSize, $_.MaximumSize) }
Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object { Write-ReportLine ('  Usage   : {0}  allocated {1} MB  current {2} MB  peak {3} MB' -f $_.Name, $_.AllocatedBaseSize, $_.CurrentUsage, $_.PeakUsage) }
if ($cs.AutomaticManagedPagefile) {
    Write-ReportLine '  A system-managed page file cannot grow when the disk is full: memory pressure then becomes a hard hang.' Yellow
}

Write-ReportHeader 'RDS SESSIONS'
$map = Get-SessionMap
$disconnected = @($map.Values | Where-Object { -not (Test-SessionActive $_.State) })
Write-ReportLine ('  Sessions: {0}   active: {1}   disconnected: {2}' -f $map.Count, ($map.Count - $disconnected.Count), $disconnected.Count) $(if ($disconnected.Count -gt 10) { 'Red' } else { 'Gray' })

$processes = Get-Process
$bySession = $processes | Group-Object SessionId | ForEach-Object {
    $id = [int]$_.Name
    $s = $map[$id]
    [PSCustomObject]@{
        SessionId = $id
        User      = if ($s) { $s.UserName } else { '(system)' }
        State     = if ($s) { $s.State } else { '-' }
        Processes = $_.Count
        WsMB      = [Math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
        PrivateMB = [Math]::Round(($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB)
    }
} | Sort-Object WsMB -Descending

Write-ReportSection 'Memory by session'
Write-ReportLine ('  {0,-5} {1,-18} {2,-8} {3,6} {4,12} {5,12}' -f 'ID', 'User', 'State', 'Procs', 'WorkingSet', 'Private')
foreach ($b in $bySession) {
    $color = if ($b.WsMB -ge 1500) { 'Red' } elseif ($b.State -match '^Disc') { 'Yellow' } else { 'Gray' }
    Write-ReportLine ('  {0,-5} {1,-18} {2,-8} {3,6} {4,9} MB {5,9} MB' -f $b.SessionId, $b.User, $b.State, $b.Processes, $b.WsMB, $b.PrivateMB) $color
}
$disconnectedMB = (@($bySession | Where-Object { $_.State -match '^Disc' }) | Measure-Object WsMB -Sum).Sum
Write-ReportLine ''
Write-ReportLine ('  HELD BY DISCONNECTED SESSIONS: {0:N0} MB - released only when the session is ended (by policy or manually)' -f $disconnectedMB) $(if ($disconnectedMB -ge 4000) { 'Red' } else { 'Yellow' })

Write-ReportHeader 'TOP 25 PROCESSES BY WORKING SET'
Write-ReportLine ('  {0,-22} {1,7} {2,4} {3,-16} {4,10} {5,10} {6,8}' -f 'Process', 'PID', 'SID', 'User', 'WS', 'Private', 'Handles')
$processes | Sort-Object WorkingSet64 -Descending | Select-Object -First 25 | ForEach-Object {
    $s = $map[$_.SessionId]
    $color = if ($_.WorkingSet64 -ge 1GB) { 'Red' } elseif ($s -and $s.State -match '^Disc') { 'Yellow' } else { 'Gray' }
    Write-ReportLine ('  {0,-22} {1,7} {2,4} {3,-16} {4,7:N0} MB {5,7:N0} MB {6,8:N0}' -f $_.ProcessName, $_.Id, $_.SessionId,
        $(if ($s) { $s.UserName } else { '-' }), ($_.WorkingSet64 / 1MB), ($_.PrivateMemorySize64 / 1MB), $_.HandleCount) $color
}

Write-ReportHeader 'TOTALS BY PROCESS NAME'
$processes | Group-Object ProcessName | ForEach-Object {
    $m = $_.Group | Measure-Object WorkingSet64 -Sum -Average -Maximum
    [PSCustomObject]@{ Name = $_.Name; Count = $_.Count; TotalMB = [Math]::Round($m.Sum / 1MB); AvgMB = [Math]::Round($m.Average / 1MB); MaxMB = [Math]::Round($m.Maximum / 1MB) }
} | Sort-Object TotalMB -Descending | Select-Object -First 20 | ForEach-Object {
    Write-ReportLine ('  {0,-26} x{1,-4} total {2,7:N0} MB   avg {3,6:N0} MB   max {4,6:N0} MB' -f $_.Name, $_.Count, $_.TotalMB, $_.AvgMB, $_.MaxMB) (Get-Level $_.TotalMB 2000 5000)
}

Write-ReportHeader 'HANDLE LEADERS (leak indicator)'
$processes | Sort-Object HandleCount -Descending | Select-Object -First 12 | ForEach-Object {
    $s = $map[$_.SessionId]
    Write-ReportLine ('  {0,-24} PID {1,7}  handles {2,8:N0}  threads {3,5}  {4}' -f $_.ProcessName, $_.Id, $_.HandleCount, $_.Threads.Count, $(if ($s) { $s.UserName } else { '' })) (Get-Level $_.HandleCount 5000 10000)
}

Write-ReportHeader 'RDS SESSION TIME LIMITS'
foreach ($path in 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services', 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp') {
    Write-ReportSection $path
    $p = Get-ItemProperty $path -ErrorAction SilentlyContinue
    if (-not $p) { Write-ReportLine '  key not present'; continue }
    foreach ($n in 'MaxDisconnectionTime', 'MaxIdleTime', 'MaxConnectionTime', 'fResetBroken') {
        if (-not $p.PSObject.Properties[$n]) { Write-ReportLine ('  {0,-24} not set' -f $n) Yellow; continue }
        $v = $p.$n
        $human = if ($n -like 'Max*' -and $v -gt 0) { ' ({0:N0} min)' -f ($v / 60000) } else { '' }
        Write-ReportLine ('  {0,-24} {1}{2}' -f $n, $v, $human) $(if ($n -like 'Max*' -and $v -eq 0) { 'Yellow' } else { 'Gray' })
    }
}
Write-ReportLine '  MaxDisconnectionTime 0 or not set: disconnected sessions never end and keep their memory.' Yellow

Write-ReportHeader 'RESOURCE-RELATED EVENTS (7 days)'
$from = (Get-Date).AddDays(-7)
Write-ReportSection 'System: unexpected shutdowns, resource exhaustion, disk and paging errors'
Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{ LogName = 'System'; StartTime = $from; ID = 41, 1001, 6008, 2004, 2019, 2020, 26, 129, 153, 157, 55, 98, 50, 333 } |
    Sort-Object TimeCreated | ForEach-Object {
        $color = if ($_.Id -in 41, 6008, 1001, 2004, 2019, 2020) { 'Red' } else { 'Yellow' }
        Write-ReportLine ('  {0:MM-dd HH:mm:ss}  {1,-5} {2,-40} {3}' -f $_.TimeCreated, $_.Id, $_.ProviderName, ("$($_.Message)" -split "`r?`n")[0]) $color
    }
Write-ReportSection 'User Profile Service warnings and errors'
Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{ LogName = 'Microsoft-Windows-User Profile Service/Operational'; StartTime = $from; ID = 1500, 1502, 1511, 1515, 1521, 1530, 1533, 1542 } |
    Group-Object Id | Sort-Object Count -Descending | ForEach-Object { Write-ReportLine ('  event {0,-6} x {1}' -f $_.Name, $_.Count) Yellow }
Write-ReportSection 'Application crashes (events 1000, 1002)'
Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{ LogName = 'Application'; StartTime = $from; ID = 1000, 1002 } |
    ForEach-Object { ("$($_.Message)" -split "`r?`n")[0] } | Group-Object | Sort-Object Count -Descending | Select-Object -First 10 |
    ForEach-Object { Write-ReportLine ('  {0,5}  {1}' -f $_.Count, $_.Name) }

Write-ReportHeader 'SECURITY LOG AND LOGON BLOCKING RISK'
$security = Get-WinEvent -ListLog Security -ErrorAction SilentlyContinue
if ($security) {
    Write-ReportLine ('  Mode: {0}   max: {1:N0} MB   size: {2:N0} MB   full: {3}' -f $security.LogMode, ($security.MaximumSizeInBytes / 1MB), ($security.FileSize / 1MB), $security.IsLogFull) $(if ($security.LogMode -ne 'Circular' -or $security.IsLogFull) { 'Red' } else { 'Green' })
}
$lsa = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue
if ($lsa -and $lsa.PSObject.Properties['CrashOnAuditFail'] -and $lsa.CrashOnAuditFail) {
    Write-ReportLine ('  CrashOnAuditFail = {0}: when the audit log is full, only administrators can log on. Looks exactly like a hung server.' -f $lsa.CrashOnAuditFail) Red
}
else { Write-ReportLine '  CrashOnAuditFail: not set (normal)' Green }

Write-ReportHeader 'REGISTRY HIVE SIZES'
Get-ChildItem "$env:SystemRoot\System32\config" -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in 'SYSTEM', 'SOFTWARE', 'SECURITY', 'SAM', 'DEFAULT' } | Sort-Object Length -Descending |
    ForEach-Object { Write-ReportLine ('  {0,-10} {1,8:N0} MB   modified {2:yyyy-MM-dd HH:mm}' -f $_.Name, ($_.Length / 1MB), $_.LastWriteTime) (Get-Level ($_.Length / 1MB) 200 500) }

$report = Save-Report -LogPath $OutputPath -Prefix 'MemoryPressure'
Write-ReportLine ''
Write-ReportLine ('Report: ' + $report) Green
Write-ReportLine 'Nothing was changed on this server.' Green
$snap
