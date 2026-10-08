<#
.SYNOPSIS
    Compacts idle user profile disks (VHDX) on a file server to return empty space. Dry run by default.

.DESCRIPTION
    Dynamic VHDX files grow but never shrink on their own: deleted data inside the profile still
    occupies space on the file server. This script finds profile disks that are

      - larger than -MinSizeGB,
      - not modified for -MinIdleDays (the user is not working),
      - not open over SMB and not attached,

    and compacts the largest -MaxFiles of them with diskpart ("attach vdisk readonly" + "compact vdisk"),
    which works without the Hyper-V role. With -WithRetrim the volume is first mounted and re-trimmed,
    so blocks freed inside NTFS are returned as well (slower, much more effective).

    Data inside the disks is never deleted. Without -Execute the script only lists candidates.

.PARAMETER ComputerName
    File server that stores the disks. Default: local computer.

.PARAMETER Path
    Folder with profile disks, local to -ComputerName (searched recursively). Example: D:\UPD.

.PARAMETER ConfigPath
    Farm configuration (.psd1); use with -Farm instead of -ComputerName / -Path.

.PARAMETER Farm
    Farm name from the configuration.

.PARAMETER MinSizeGB
    Only disks larger than this. Default: 1.

.PARAMETER MinIdleDays
    Only disks not modified for this many days. Default: 7.

.PARAMETER MaxFiles
    Maximum number of disks to compact in one run, largest first. Default: 5.

.PARAMETER WithRetrim
    Mount each disk and run Optimize-Volume -ReTrim before compacting.

.PARAMETER Execute
    Actually compact. Without it the script is a dry run.

.PARAMETER LogPath
    Folder for the text report.

.EXAMPLE
    .\Compact-ProfileDisk.ps1 -ComputerName fs-01 -Path D:\UPD

    Dry run: shows candidates and what would be done.

.EXAMPLE
    .\Compact-ProfileDisk.ps1 -ConfigPath ..\config\farms.psd1 -Farm Office -MaxFiles 20 -WithRetrim -Execute

.NOTES
    Run in a maintenance window: compaction reads and rewrites the whole file.
#>
#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'ByPath')]
param(
    [Parameter(ParameterSetName = 'ByPath')]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByPath')]
    [string]$Path,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByFarm')]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByFarm')]
    [string]$Farm,

    [ValidateRange(0, 1000)]
    [int]$MinSizeGB = 1,

    [ValidateRange(0, 3650)]
    [int]$MinIdleDays = 7,

    [ValidateRange(1, 10000)]
    [int]$MaxFiles = 5,

    [switch]$WithRetrim,

    [switch]$Execute,

    [string]$LogPath = (Join-Path $env:ProgramData 'rds-toolkit\logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')

$dnsSuffix = ''
if ($PSCmdlet.ParameterSetName -eq 'ByFarm') {
    $config = Import-RdsConfig -Path $ConfigPath
    $farmConfig = Get-RdsFarm -Config $config -Name $Farm
    $dnsSuffix = $config.DnsSuffix
    $ComputerName = $farmConfig.StorageHost
    $Path = ConvertTo-LocalSharePath $farmConfig.ProfileShare
    if (-not $Path) { throw "ProfileShare '$($farmConfig.ProfileShare)' is not an admin share (\\server\X$\...). Use -ComputerName and -Path." }
}

$started = Get-Date
Write-ReportHeader 'COMPACT IDLE PROFILE DISKS'
Write-ReportLine ('Server   : ' + $ComputerName)
Write-ReportLine ('Folder   : ' + $Path)
Write-ReportLine ('Mode     : ' + $(if ($Execute) { 'EXECUTE' } else { 'DRY RUN' })) $(if ($Execute) { 'Yellow' } else { 'Green' })
Write-ReportLine ('Filter   : > {0} GB, idle >= {1} days, max {2} disk(s)' -f $MinSizeGB, $MinIdleDays, $MaxFiles)
Write-ReportLine ('Retrim   : ' + $(if ($WithRetrim) { 'yes (slower, more effective)' } else { 'no' }))

$compact = {
    param($Definitions, $Root, $MinGB, $IdleDays, $MaxFiles, $DoExecute, $DoRetrim)
    . ([scriptblock]::Create($Definitions))
    $ErrorActionPreference = 'Stop'

    function Get-FreeBytes { param($Root) (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Root.Substring(0, 2))'").FreeSpace }

    $freeBefore = Get-FreeBytes $Root
    $cutoff = (Get-Date).AddDays(-$IdleDays)

    $open = @{}
    foreach ($o in (Get-SmbOpenFile -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*.vhd*' })) {
        $open[(Split-Path $o.Path -Leaf).ToLower()] = $o.ClientComputerName
    }

    $candidates = foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.vhdx', '*.vhd' -ErrorAction SilentlyContinue)) {
        if ($f.Name -like '*template*') { continue }
        if ($f.Length -lt ($MinGB * 1GB) -or $f.LastWriteTime -gt $cutoff) { continue }

        $skip = $null
        if ($open.ContainsKey($f.Name.ToLower())) { $skip = 'open from ' + $open[$f.Name.ToLower()] }
        $image = Get-DiskImage -ImagePath $f.FullName -ErrorAction SilentlyContinue
        if ($image -and $image.Attached) { $skip = 'already attached' }

        $user = '?'
        if ($f.FullName -match '(S-1-5-21-[\d-]+)') {
            try { $user = (New-Object System.Security.Principal.SecurityIdentifier($Matches[1])).Translate([System.Security.Principal.NTAccount]).Value } catch { }
        }
        [PSCustomObject]@{
            Path     = $f.FullName
            Name     = $f.Name
            User     = $user
            GB       = [Math]::Round($f.Length / 1GB, 2)
            Modified = $f.LastWriteTime
            IdleDays = [Math]::Round(((Get-Date) - $f.LastWriteTime).TotalDays)
            Skip     = $skip
        }
    }
    $candidates = @($candidates | Sort-Object GB -Descending)
    $work = @($candidates | Where-Object { -not $_.Skip } | Select-Object -First $MaxFiles)

    $done = @()
    if ($DoExecute) {
        foreach ($c in $work) {
            $before = (Get-Item -LiteralPath $c.Path).Length
            # Re-check right before touching the file: the user may have logged on meanwhile.
            if (@(Get-SmbOpenFile -ErrorAction SilentlyContinue | Where-Object { (Split-Path $_.Path -Leaf) -eq $c.Name }).Count) {
                $done += [PSCustomObject]@{ User = $c.User; Name = $c.Name; BeforeGB = $c.GB; AfterGB = $c.GB; SavedGB = 0; Status = 'skipped: opened' }
                continue
            }

            $note = ''
            if ($DoRetrim) {
                try {
                    $mount = Mount-ProfileDisk -Path $c.Path
                    Optimize-Volume -DriveLetter $mount.Root.Substring(0, 1) -ReTrim -ErrorAction SilentlyContinue
                    $note = ' +retrim'
                }
                catch { $note = ' (retrim failed: ' + $_.Exception.Message + ')' }
                finally { [void](Dismount-ProfileDisk -Path $c.Path) }
            }

            $scriptFile = Join-Path $env:TEMP ('compact_' + [guid]::NewGuid().ToString('N') + '.txt')
            Set-Content -LiteralPath $scriptFile -Encoding ASCII -Value @(
                "select vdisk file=""$($c.Path)""", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk', 'exit')
            $output = & diskpart.exe /s $scriptFile 2>&1
            $exitCode = $LASTEXITCODE
            Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
            [void](Dismount-ProfileDisk -Path $c.Path)   # make sure diskpart did not leave it attached

            $after = (Get-Item -LiteralPath $c.Path).Length
            $status = if ($exitCode -ne 0) { "diskpart exit code $exitCode" } elseif ($after -lt $before) { 'compacted' + $note } else { 'no change' + $note }
            $done += [PSCustomObject]@{
                User = $c.User; Name = $c.Name
                BeforeGB = [Math]::Round($before / 1GB, 2); AfterGB = [Math]::Round($after / 1GB, 2)
                SavedGB = [Math]::Round(($before - $after) / 1GB, 2); Status = $status
                Detail = if ($exitCode -ne 0) { ($output | Select-Object -Last 3) -join ' ' } else { '' }
            }
        }
    }

    [PSCustomObject]@{
        Candidates   = $candidates
        Work         = $work
        Done         = $done
        FreeBeforeGB = [Math]::Round($freeBefore / 1GB, 2)
        FreeAfterGB  = [Math]::Round((Get-FreeBytes $Root) / 1GB, 2)
    }
}

$definitions = Get-FunctionDefinition 'Mount-ProfileDisk', 'Dismount-ProfileDisk'
$timeout = if ($Execute) { 6 * 3600 } else { 900 }
$result = Invoke-OnHost -ComputerName $ComputerName -DnsSuffix $dnsSuffix -TimeoutSec $timeout -ScriptBlock $compact `
    -ArgumentList $definitions, $Path, $MinSizeGB, $MinIdleDays, $MaxFiles, $Execute.IsPresent, $WithRetrim.IsPresent
if (-not $result) { throw "Failed to run on $ComputerName." }

Write-ReportHeader 'CANDIDATES'
Write-ReportLine ('  {0,-28} {1,7} {2,-10} {3,6}  {4}' -f 'User', 'GB', 'Modified', 'Idle', 'State')
foreach ($c in $result.Candidates) {
    $state = if ($c.Skip) { $c.Skip } else { 'can be compacted' }
    Write-ReportLine ('  {0,-28} {1,7:N2} {2:yyyy-MM-dd} {3,5}d  {4}' -f $c.User, $c.GB, $c.Modified, $c.IdleDays, $state) $(if ($c.Skip) { 'DarkGray' } else { 'Green' })
}
Write-ReportLine ''
Write-ReportLine ('  Matching filter : ' + @($result.Candidates).Count)
Write-ReportLine ('  Selected        : ' + @($result.Work).Count + ', total ' + [Math]::Round((@($result.Work) | Measure-Object GB -Sum).Sum, 2) + ' GB')

if (-not $Execute) {
    Write-ReportHeader 'DRY RUN - nothing changed'
    Write-ReportLine '  With -Execute, for each selected disk:'
    Write-ReportLine '    1. check again that the file is not open'
    if ($WithRetrim) { Write-ReportLine '    2. mount, Optimize-Volume -ReTrim, dismount' }
    Write-ReportLine '    3. diskpart: attach readonly -> compact -> detach'
    Write-ReportLine '    4. verify the disk is detached'
    Write-ReportLine ('  Free space on {0} now: {1} GB' -f $Path.Substring(0, 2), $result.FreeBeforeGB)
    Write-ReportLine '  Add -Execute to run. Best result: -Execute -WithRetrim' Yellow
}
else {
    Write-ReportHeader 'RESULT'
    Write-ReportLine ('  {0,-28} {1,8} {2,8} {3,8}  {4}' -f 'User', 'Before', 'After', 'Saved', 'Status')
    foreach ($d in $result.Done) {
        $color = if ($d.Status -like 'compacted*') { 'Green' } elseif ($d.Status -like 'skipped*') { 'Yellow' } else { 'DarkGray' }
        Write-ReportLine ('  {0,-28} {1,8:N2} {2,8:N2} {3,8:N2}  {4}' -f $d.User, $d.BeforeGB, $d.AfterGB, $d.SavedGB, $d.Status) $color
        if ($d.PSObject.Properties['Detail'] -and $d.Detail) { Write-ReportLine ('    ' + $d.Detail) DarkGray }
    }
    Write-ReportLine ''
    Write-ReportLine ('  Saved total : {0:N2} GB' -f (@($result.Done) | Measure-Object SavedGB -Sum).Sum) Cyan
    Write-ReportLine ('  Free space  : {0} GB -> {1} GB' -f $result.FreeBeforeGB, $result.FreeAfterGB) Green
}

$report = Save-Report -LogPath $LogPath -Prefix ('CompactProfileDisk_' + $(if ($Execute) { 'EXEC' } else { 'DRY' }))
Write-ReportLine ('  Report: ' + $report + '   Duration: ' + [Math]::Round(((Get-Date) - $started).TotalMinutes, 1) + ' min') DarkGray

if ($Execute) { $result.Done } else { $result.Work }
