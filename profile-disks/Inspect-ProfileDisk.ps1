<#
.SYNOPSIS
    Shows what takes space inside a user profile disk (UPD or FSLogix VHDX) without changing it.

.DESCRIPTION
    Mounts the disk READ-ONLY on the file server, measures top-level folders, well-known caches
    and user data folders, lists the largest files, and always dismounts the disk again
    (three attempts, result is reported).

    The report answers two questions:
      - how much would "compact" return (file size minus data actually used inside the volume);
      - how much is cache that can be deleted without data loss.

    The disk is not mounted if it is open over SMB (the user is logged on).

.PARAMETER Path
    Path to the VHD(X) as seen from -ComputerName (local path such as D:\UPD\UVHD-S-1-5-21-....vhdx).

.PARAMETER ComputerName
    File server that hosts the disk. Default: local computer.

.PARAMETER ConfigPath
    Farm configuration (.psd1). Used with -Farm and -UserName to locate the disk automatically.

.PARAMETER Farm
    Farm name from the configuration.

.PARAMETER UserName
    User whose profile disk should be inspected.

.PARAMETER MinFileMB
    Size threshold for the "largest files" list. Default: 50.

.PARAMETER LogPath
    Folder for the text report. Default: C:\ProgramData\rds-toolkit\logs.

.EXAMPLE
    .\Inspect-ProfileDisk.ps1 -ConfigPath ..\config\farms.psd1 -Farm Office -UserName jdoe

.EXAMPLE
    .\Inspect-ProfileDisk.ps1 -ComputerName fs-01 -Path 'D:\UPD\Office\UVHD-S-1-5-21-1111111111-2222222222-3333333333-1105.vhdx'

.NOTES
    Requires admin rights on the file server and WinRM access to it.
#>
#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'ByPath')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByPath')]
    [string]$Path,

    [Parameter(ParameterSetName = 'ByPath')]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByUser')]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByUser')]
    [string]$Farm,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByUser')]
    [string]$UserName,

    [ValidateRange(1, 100000)]
    [int]$MinFileMB = 50,

    [string]$LogPath = (Join-Path $env:ProgramData 'rds-toolkit\logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')

$dnsSuffix = ''
if ($PSCmdlet.ParameterSetName -eq 'ByUser') {
    $config = Import-RdsConfig -Path $ConfigPath
    $farmConfig = Get-RdsFarm -Config $config -Name $Farm
    $dnsSuffix = $config.DnsSuffix
    $sid = Get-UserSid -UserName $UserName -Domain $config.Domain
    if (-not $sid) { throw "Cannot resolve SID for '$UserName'." }
    $disk = Find-ProfileDisk -Farm $farmConfig -Sid $sid -UserName $UserName
    if (-not $disk) { throw "No profile disk found for '$UserName' ($sid) in $($farmConfig.ProfileShare)." }

    # Mount on the file server with a local path when the share is an admin share; otherwise mount the UNC path here.
    $localRoot = ConvertTo-LocalSharePath $farmConfig.ProfileShare
    if ($localRoot) {
        $ComputerName = $farmConfig.StorageHost
        $Path = Join-Path $localRoot $disk.FullName.Substring($farmConfig.ProfileShare.TrimEnd('\').Length).TrimStart('\')
    }
    else {
        $ComputerName = $env:COMPUTERNAME
        $Path = $disk.FullName
    }
}

$started = Get-Date
Write-ReportHeader 'PROFILE DISK INSPECTION (read-only mount)'
Write-ReportLine ('Disk     : ' + $Path)
Write-ReportLine ('Server   : ' + $ComputerName)
Write-ReportLine ('Started  : ' + $started.ToString('yyyy-MM-dd HH:mm:ss'))
Write-ReportLine 'The disk is mounted read-only and always dismounted at the end.' Green

$inspect = {
    param($Definitions, $Path, $MinMB, $Catalog)
    . ([scriptblock]::Create($Definitions))
    $ErrorActionPreference = 'Stop'

    $out = [ordered]@{
        FileGB = $null; Modified = $null; OpenBy = @(); Mounted = $false; Dismounted = $false; Errors = @()
        Volume = $null; TopFolders = @(); Folders = @(); BigFiles = @(); FileCount = 0
    }
    if (-not (Test-Path -LiteralPath $Path)) { $out.Errors += 'File not found.'; return [PSCustomObject]$out }

    $file = Get-Item -LiteralPath $Path
    $out.FileGB = [Math]::Round($file.Length / 1GB, 2)
    $out.Modified = $file.LastWriteTime

    if ($Path -notlike '\\*' -and (Get-Command Get-SmbOpenFile -ErrorAction SilentlyContinue)) {
        $out.OpenBy = @(Get-SmbOpenFile -ErrorAction SilentlyContinue |
            Where-Object { (Split-Path $_.Path -Leaf) -eq $file.Name } |
            ForEach-Object { "$($_.ClientComputerName)/$($_.ClientUserName)" } | Sort-Object -Unique)
        if ($out.OpenBy.Count) { $out.Errors += 'Disk is open over SMB (user logged on) - not mounted.'; return [PSCustomObject]$out }
    }

    try {
        $mount = Mount-ProfileDisk -Path $Path -ReadOnly
        $out.Mounted = $true
        $out.Volume = $mount

        $all = @(Get-ChildItem -LiteralPath $mount.Root -Recurse -File -Force -ErrorAction SilentlyContinue)
        $out.FileCount = $all.Count

        $out.TopFolders = @(Get-ChildItem -LiteralPath $mount.Root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $size = Get-FolderSize $_.FullName
                if ($size.Bytes -ge 10MB) { [PSCustomObject]@{ Name = $_.Name; MB = [Math]::Round($size.Bytes / 1MB) } }
            } | Sort-Object MB -Descending)

        $profileRoot = Get-ProfileRoot $mount.Root
        if ($profileRoot) {
            $out.Folders = @($(foreach ($entry in $Catalog) {
                    $full = Join-Path $profileRoot $entry.Path
                    if (-not (Test-Path -LiteralPath $full)) { continue }
                    $size = Get-FolderSize $full
                    if ($size.Bytes -lt 1MB) { continue }
                    [PSCustomObject]@{ Name = $entry.Name; Junk = $entry.Junk; MB = [Math]::Round($size.Bytes / 1MB); Files = $size.Files; Path = $entry.Path }
                }) | Sort-Object MB -Descending)
        }
        else {
            $out.Errors += 'Profile folder (AppData) not found inside the disk.'
        }

        $out.BigFiles = @($all | Where-Object { $_.Length -ge ($MinMB * 1MB) } | Sort-Object Length -Descending |
            Select-Object -First 25 | ForEach-Object {
                [PSCustomObject]@{ MB = [Math]::Round($_.Length / 1MB); Modified = $_.LastWriteTime; Path = $_.FullName.Substring($mount.Root.Length) }
            })
    }
    catch {
        $out.Errors += $_.Exception.Message
    }
    finally {
        if ($out.Mounted) {
            $out.Dismounted = Dismount-ProfileDisk -Path $Path
            if (-not $out.Dismounted) { $out.Errors += 'WARNING: disk is still attached after 3 dismount attempts.' }
        }
    }
    return [PSCustomObject]$out
}

$definitions = Get-FunctionDefinition 'Mount-ProfileDisk', 'Dismount-ProfileDisk', 'Get-FolderSize', 'Get-ProfileRoot'
$catalog = @(Get-ProfileFolderCatalog)
$result = Invoke-OnHost -ComputerName $ComputerName -DnsSuffix $dnsSuffix -TimeoutSec 900 -ScriptBlock $inspect `
    -ArgumentList $definitions, $Path, $MinFileMB, $catalog
if (-not $result) { throw "Inspection failed on $ComputerName." }

Write-ReportHeader 'DISK STATE'
Write-ReportLine ('  File size   : ' + $result.FileGB + ' GB')
Write-ReportLine ('  Modified    : ' + $result.Modified)
if ($result.OpenBy) { Write-ReportLine ('  Open by     : ' + ($result.OpenBy -join ', ')) Red }
foreach ($e in $result.Errors) { Write-ReportLine ('  ' + $e) Red }
$dismountText = if ($result.Dismounted) { 'yes' } elseif ($result.Mounted) { 'NO - detach manually: Dismount-DiskImage -ImagePath "' + $Path + '"' } else { 'not mounted' }
Write-ReportLine ('  Dismounted  : ' + $dismountText) $(if ($result.Mounted -and -not $result.Dismounted) { 'Red' } else { 'Green' })

if (-not $result.Mounted -or -not $result.Volume) { Save-Report -LogPath $LogPath -Prefix 'InspectProfileDisk' | Out-Null; return }

$volume = $result.Volume
$slack = [Math]::Round($result.FileGB - $volume.UsedGB, 2)
Write-ReportHeader 'VOLUME INSIDE'
Write-ReportLine ('  Volume size : ' + $volume.SizeGB + ' GB')
Write-ReportLine ('  Used        : ' + $volume.UsedGB + ' GB')
Write-ReportLine ('  Free        : ' + $volume.FreeGB + ' GB')
Write-ReportLine ('  Files       : ' + $result.FileCount)
Write-ReportLine ('  Empty space inside the file: ' + $slack + ' GB (returned by compact, no data touched)') Cyan

Write-ReportHeader 'TOP-LEVEL FOLDERS'
foreach ($f in $result.TopFolders) { Write-ReportLine ('  {0,-40} {1,8:N0} MB' -f $f.Name, $f.MB) }

Write-ReportHeader 'CACHES AND USER DATA'
Write-ReportLine ('  {0,-26} {1,9} {2,9}  {3}' -f 'Folder', 'MB', 'Files', 'Type')
$junkMB = 0
foreach ($f in $result.Folders) {
    if ($f.Junk) { $junkMB += $f.MB }
    $type = if ($f.Junk) { 'cache - safe to delete' } else { 'USER DATA' }
    Write-ReportLine ('  {0,-26} {1,9:N0} {2,9:N0}  {3}' -f $f.Name, $f.MB, $f.Files, $type) $(if ($f.Junk) { 'Green' } else { 'Yellow' })
}

Write-ReportHeader ('LARGEST FILES (> ' + $MinFileMB + ' MB)')
if (-not $result.BigFiles) { Write-ReportLine '  none' }
foreach ($f in $result.BigFiles) { Write-ReportLine ('  {0,7:N0} MB  {1:yyyy-MM-dd}  {2}' -f $f.MB, $f.Modified, $f.Path) }

Write-ReportHeader 'SUMMARY'
Write-ReportLine ('  Empty space (compact)  : {0} GB' -f $slack) Green
Write-ReportLine ('  Caches inside          : {0:N2} GB' -f ($junkMB / 1024)) Green
Write-ReportLine ('  Potential total        : {0:N2} GB' -f ($slack + $junkMB / 1024)) Cyan
if ($slack -gt 1) { Write-ReportLine '  Start with Compact-ProfileDisk.ps1: it returns space without touching data.' Green }

$report = Save-Report -LogPath $LogPath -Prefix 'InspectProfileDisk'
Write-ReportLine ''
Write-ReportLine ('  Report: ' + $report) DarkGray

[PSCustomObject]@{
    Path        = $Path
    FileGB      = $result.FileGB
    UsedGB      = $volume.UsedGB
    SlackGB     = $slack
    CacheGB     = [Math]::Round($junkMB / 1024, 2)
    Dismounted  = $result.Dismounted
}
