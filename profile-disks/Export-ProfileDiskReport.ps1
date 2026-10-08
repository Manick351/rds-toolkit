<#
.SYNOPSIS
    Exports an inventory of all profile disks in a farm, joined with Active Directory data, to XLSX or CSV.

.DESCRIPTION
    For every profile disk on the farm's share the report shows who owns it (resolved by SID through
    LDAP, no ActiveDirectory module needed), whether the account is enabled, last logon, file size,
    maximum (virtual) size, idle days and whether the disk is open right now and from which host.

    Rows where the account is disabled or missing in AD are highlighted: these disks are candidates
    for archiving. A summary sheet contains totals.

    The XLSX file is written directly (Office Open XML), Excel is not required.

.PARAMETER ConfigPath
    Farm configuration (.psd1).

.PARAMETER Farm
    Farm name from the configuration.

.PARAMETER OutDir
    Output folder. Default: current user's Desktop.

.PARAMETER IdleDays
    Threshold for the "idle" counter in the summary. Default: 90.

.PARAMETER Format
    Xlsx (default) or Csv.

.EXAMPLE
    .\Export-ProfileDiskReport.ps1 -ConfigPath ..\config\farms.psd1 -Farm Office

.EXAMPLE
    .\Export-ProfileDiskReport.ps1 -ConfigPath ..\config\farms.psd1 -Farm Office -Format Csv -OutDir C:\Reports
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$Farm,

    [string]$OutDir = [Environment]::GetFolderPath('Desktop'),

    [ValidateRange(1, 3650)]
    [int]$IdleDays = 90,

    [ValidateSet('Xlsx', 'Csv')]
    [string]$Format = 'Xlsx'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Common.ps1')
. (Join-Path $PSScriptRoot '..\lib\Xlsx.ps1')

$config = Import-RdsConfig -Path $ConfigPath
$farmConfig = Get-RdsFarm -Config $config -Name $Farm
$share = $farmConfig.ProfileShare
$started = Get-Date

function ConvertFrom-FileTimeSafe {
    param($Value)
    if ($null -eq $Value) { return $null }
    $n = [int64]$Value
    if ($n -le 0 -or $n -eq [int64]::MaxValue) { return $null }
    try { return [datetime]::FromFileTime($n) } catch { return $null }
}

$script:Searcher = $null
function Get-AdUserBySid {
    param([string]$Sid)
    if (-not $script:Searcher) {
        $script:Searcher = New-Object System.DirectoryServices.DirectorySearcher
        foreach ($p in 'samaccountname', 'displayname', 'useraccountcontrol', 'lastlogontimestamp', 'pwdlastset',
            'whencreated', 'department', 'title', 'mail', 'description', 'distinguishedname') {
            [void]$script:Searcher.PropertiesToLoad.Add($p)
        }
    }
    $info = [ordered]@{ Login = $null; Name = $null; Status = 'Not in AD'; LastLogon = $null; PwdSet = $null
        Created = $null; Department = $null; Title = $null; Mail = $null; Description = $null; OU = $null }
    try {
        $script:Searcher.Filter = "(objectSid=$Sid)"
        $r = $script:Searcher.FindOne()
    }
    catch { $r = $null }
    if (-not $r) {
        $account = Get-UserFromSid $Sid
        if ($account) { $info.Login = $account -replace '^.*\\', ''; $info.Status = 'Found, attributes not read' }
        return [PSCustomObject]$info
    }
    $get = { param($n) if ($r.Properties[$n].Count) { $r.Properties[$n][0] } else { $null } }
    $info.Login = & $get 'samaccountname'
    $info.Name = & $get 'displayname'
    $info.Status = if ([int](& $get 'useraccountcontrol') -band 2) { 'Disabled' } else { 'Enabled' }
    $info.LastLogon = ConvertFrom-FileTimeSafe (& $get 'lastlogontimestamp')
    $info.PwdSet = ConvertFrom-FileTimeSafe (& $get 'pwdlastset')
    $info.Created = & $get 'whencreated'
    $info.Department = & $get 'department'
    $info.Title = & $get 'title'
    $info.Mail = & $get 'mail'
    $info.Description = & $get 'description'
    $dn = [string](& $get 'distinguishedname')
    if ($dn) { $info.OU = $dn -replace '^CN=(?:\\,|[^,])+,', '' }
    return [PSCustomObject]$info
}

$dnsCache = @{}
function Resolve-ClientName {
    param([string]$Address)
    $a = $Address.Trim('[', ']')
    if (-not $dnsCache.ContainsKey($a)) {
        $name = $a
        try { $name = ([System.Net.Dns]::GetHostEntry($a).HostName -split '\.')[0] } catch { }
        $dnsCache[$a] = $name
    }
    return $dnsCache[$a]
}

# Disks on the share
Write-Host "Farm $($farmConfig.Name): scanning $share" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $share)) { throw "Share not reachable: $share" }
$depth = if ($farmConfig.ProfileType -eq 'FSLogix') { 1 } else { 0 }
$disks = @(Get-ChildItem -LiteralPath $share -Recurse -Depth $depth -File -Include '*.vhdx', '*.vhd' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '*template*' } |
    ForEach-Object { $sid = Get-SidFromProfileDiskPath $_.FullName; if ($sid) { [PSCustomObject]@{ File = $_; Sid = $sid } } })
Write-Host "Profile disks: $($disks.Count)"

# Open handles and virtual size, collected on the file server in one call.
$openMap = @{}
$sizeMap = @{}
$stateNote = ''
$localRoot = ConvertTo-LocalSharePath $share
if ($localRoot) {
    $state = Invoke-OnHost -ComputerName $farmConfig.StorageHost -DnsSuffix $config.DnsSuffix -ArgumentList $localRoot -ScriptBlock {
        param($Root)
        $open = @(Get-SmbOpenFile -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Root*" -and $_.Path -like '*.vhd*' } |
            ForEach-Object { [PSCustomObject]@{ Name = (Split-Path $_.Path -Leaf); Client = $_.ClientComputerName } })
        $openNames = $open | ForEach-Object { $_.Name }
        $size = foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.vhdx', '*.vhd' -ErrorAction SilentlyContinue)) {
            if ($openNames -contains $f.Name) { continue }
            try { [PSCustomObject]@{ Name = $f.Name; Size = [int64](Get-DiskImage -ImagePath $f.FullName).Size } } catch { }
        }
        [PSCustomObject]@{ Open = $open; Size = @($size) }
    }
    if ($state) {
        foreach ($o in @($state.Open)) {
            $key = $o.Name.ToLower()
            if (-not $openMap.ContainsKey($key)) { $openMap[$key] = @() }
            $openMap[$key] += Resolve-ClientName $o.Client
        }
        foreach ($s in @($state.Size)) { $sizeMap[$s.Name.ToLower()] = $s.Size }
    }
    else { $stateNote = "Open-file state from $($farmConfig.StorageHost) is not available." }
}
else { $stateNote = 'Share is not an admin share: open-file state and virtual size are not collected.' }

Write-Host 'Reading Active Directory...'
$rows = foreach ($d in $disks) {
    $ad = Get-AdUserBySid $d.Sid
    $f = $d.File
    $key = $f.Name.ToLower()
    $openState = if ($stateNote) { 'n/a' } elseif ($openMap.ContainsKey($key)) { 'Yes' } else { 'No' }
    [PSCustomObject][ordered]@{
        'Login'              = $ad.Login
        'Name'               = $ad.Name
        'Account'            = $ad.Status
        'Last logon'         = $ad.LastLogon
        'Password set'       = $ad.PwdSet
        'Created'            = $ad.Created
        'Department'         = $ad.Department
        'Title'              = $ad.Title
        'Mail'               = $ad.Mail
        'Description'        = $ad.Description
        'OU'                 = $ad.OU
        'File, GB'           = [Math]::Round($f.Length / 1GB, 2)
        'Max size, GB'       = if ($sizeMap.ContainsKey($key)) { [Math]::Round($sizeMap[$key] / 1GB, 2) } else { $null }
        'Disk modified'      = $f.LastWriteTime
        'Idle days'          = [int][Math]::Floor(($started - $f.LastWriteTime).TotalDays)
        'Open now'           = $openState
        'Open from'          = if ($openMap.ContainsKey($key)) { ($openMap[$key] | Sort-Object -Unique) -join ', ' } else { '' }
        'SID'                = $d.Sid
        'Path'               = $f.FullName
        '__Highlight'        = ($ad.Status -ne 'Enabled')
    }
}
$rows = @($rows | Sort-Object @{ Expression = { [string]::IsNullOrEmpty($_.Login) } }, Login)

$columns = @(
    @{ Key = 'Login'; Width = 16; Type = 'text' }, @{ Key = 'Name'; Width = 28; Type = 'text' }
    @{ Key = 'Account'; Width = 12; Type = 'text' }, @{ Key = 'Last logon'; Width = 16; Type = 'datetime' }
    @{ Key = 'Password set'; Width = 16; Type = 'datetime' }, @{ Key = 'Created'; Width = 12; Type = 'date' }
    @{ Key = 'Department'; Width = 24; Type = 'text' }, @{ Key = 'Title'; Width = 24; Type = 'text' }
    @{ Key = 'Mail'; Width = 26; Type = 'text' }, @{ Key = 'Description'; Width = 26; Type = 'text' }
    @{ Key = 'OU'; Width = 40; Type = 'text' }, @{ Key = 'File, GB'; Width = 9; Type = 'num' }
    @{ Key = 'Max size, GB'; Width = 10; Type = 'num' }, @{ Key = 'Disk modified'; Width = 16; Type = 'datetime' }
    @{ Key = 'Idle days'; Width = 9; Type = 'int' }, @{ Key = 'Open now'; Width = 9; Type = 'text' }
    @{ Key = 'Open from'; Width = 16; Type = 'text' }, @{ Key = 'SID'; Width = 46; Type = 'text' }
    @{ Key = 'Path'; Width = 70; Type = 'text' }
)

$count = { param($filter) @($rows | Where-Object $filter).Count }
$summary = @(
    [PSCustomObject]@{ Item = 'Farm'; Value = $farmConfig.Name }
    [PSCustomObject]@{ Item = 'Profile type'; Value = $farmConfig.ProfileType }
    [PSCustomObject]@{ Item = 'Profile share'; Value = $share }
    [PSCustomObject]@{ Item = 'Exported'; Value = $started }
    [PSCustomObject]@{ Item = 'Profile disks'; Value = $rows.Count }
    [PSCustomObject]@{ Item = 'Account enabled'; Value = (& $count { $_.Account -eq 'Enabled' }) }
    [PSCustomObject]@{ Item = 'Account disabled'; Value = (& $count { $_.Account -eq 'Disabled' }) }
    [PSCustomObject]@{ Item = 'Not in AD'; Value = (& $count { $_.Account -eq 'Not in AD' }) }
    [PSCustomObject]@{ Item = 'Open now'; Value = $(if ($stateNote) { 'n/a' } else { & $count { $_.'Open now' -eq 'Yes' } }) }
    [PSCustomObject]@{ Item = "Idle more than $IdleDays days"; Value = (& $count { $_.'Idle days' -gt $IdleDays }) }
    [PSCustomObject]@{ Item = 'Total size, GB'; Value = [Math]::Round(($rows | Measure-Object 'File, GB' -Sum).Sum, 2) }
    [PSCustomObject]@{ Item = 'Note'; Value = 'Highlighted rows: account disabled or not found in AD.' }
    [PSCustomObject]@{ Item = 'Note'; Value = 'Last logon is lastLogonTimestamp: replicated with up to 14 days delay.' }
    [PSCustomObject]@{ Item = 'Note'; Value = 'Disk modified is roughly the last time the user logged off.' }
)
if ($stateNote) { $summary += [PSCustomObject]@{ Item = 'Warning'; Value = $stateNote } }

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$baseName = '{0}_ProfileDisks_{1:yyyyMMdd_HHmm}' -f $farmConfig.Name, $started
if ($Format -eq 'Csv') {
    $outFile = Join-Path $OutDir "$baseName.csv"
    $rows | Select-Object -Property ($columns | ForEach-Object { $_.Key }) | Export-Csv -LiteralPath $outFile -NoTypeInformation -Encoding UTF8
}
else {
    $outFile = Join-Path $OutDir "$baseName.xlsx"
    Export-Xlsx -Path $outFile -Sheets @(
        @{ Name = 'Profile disks'; Columns = $columns; Rows = $rows; Freeze = $true; Filter = $true }
        @{ Name = 'Summary'; Columns = @(@{ Key = 'Item'; Width = 32; Type = 'text' }, @{ Key = 'Value'; Width = 80; Type = 'auto' }); Rows = $summary }
    )
}

Write-Host ('Disks: {0}   enabled: {1}   disabled: {2}   not in AD: {3}' -f $rows.Count,
    (& $count { $_.Account -eq 'Enabled' }), (& $count { $_.Account -eq 'Disabled' }), (& $count { $_.Account -eq 'Not in AD' })) -ForegroundColor Green
Write-Host "File: $outFile" -ForegroundColor Green
Get-Item -LiteralPath $outFile
