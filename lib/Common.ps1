# Shared helpers for rds-toolkit scripts. Dot-source: . "$PSScriptRoot\..\lib\Common.ps1"
# Windows PowerShell 5.1 compatible.

#region Configuration

function Import-RdsConfig {
    <#
    .SYNOPSIS
        Loads the farm configuration (.psd1) and fills in defaults.
    .DESCRIPTION
        See examples\farms.example.psd1 for the format. Each farm describes one RDS collection:
        connection broker, session hosts, profile share and profile type (UPD or FSLogix).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path. Copy examples\farms.example.psd1 and adjust it."
    }
    $config = Import-PowerShellDataFile -LiteralPath $Path

    if (-not $config.Farms -or @($config.Farms).Count -eq 0) { throw "No farms defined in $Path." }
    if (-not $config.ContainsKey('DnsSuffix')) { $config.DnsSuffix = '' }
    if (-not $config.ContainsKey('Domain')) { $config.Domain = $env:USERDOMAIN }
    if (-not $config.ContainsKey('Settings')) { $config.Settings = @{} }

    $defaults = @{
        LogPath         = (Join-Path $env:ProgramData 'rds-toolkit\logs')
        ResizeDefaultGB = 20
        ResizeMaxGB     = 50
    }
    foreach ($k in $defaults.Keys) {
        if (-not $config.Settings.ContainsKey($k)) { $config.Settings[$k] = $defaults[$k] }
    }

    foreach ($farm in $config.Farms) {
        foreach ($required in 'Name', 'ProfileShare') {
            if (-not $farm[$required]) { throw "Farm entry without '$required' in $Path." }
        }
        if (-not $farm.ContainsKey('ProfileType')) { $farm.ProfileType = 'UPD' }
        if ($farm.ProfileType -notin 'UPD', 'FSLogix') { throw "Farm '$($farm.Name)': ProfileType must be UPD or FSLogix." }
        if (-not $farm.ContainsKey('SessionHosts')) { $farm.SessionHosts = @() }
        if (-not $farm.ContainsKey('StorageHost')) { $farm.StorageHost = Get-ShareServer $farm.ProfileShare }
        if (-not $farm.ContainsKey('MaxProfileGB')) { $farm.MaxProfileGB = $null }
    }
    return $config
}

function Get-RdsFarm {
    param([hashtable]$Config, [string]$Name)
    $farm = $Config.Farms | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $farm) { throw "Farm '$Name' not found. Known: $(($Config.Farms | ForEach-Object { $_.Name }) -join ', ')" }
    return $farm
}

function Get-ShareServer {
    # \\server\share\path -> server
    param([string]$Share)
    if ($Share -match '^\\\\([^\\]+)\\') { return $Matches[1] }
    return $env:COMPUTERNAME
}

function ConvertTo-LocalSharePath {
    # \\server\D$\Profiles -> D:\Profiles (admin shares only)
    param([string]$Share)
    if ($Share -match '^\\\\[^\\]+\\([A-Za-z])\$\\?(.*)$') { return ($Matches[1] + ':\' + $Matches[2]) }
    return $null
}

function Get-ShortName {
    param([string]$Name)
    if (-not $Name) { return '' }
    return ($Name -split '\.')[0]
}

function Resolve-Fqdn {
    param([string]$Name, [string]$DnsSuffix)
    if (-not $Name -or $Name -like '*.*' -or -not $DnsSuffix) { return $Name }
    return "$Name.$DnsSuffix"
}

#endregion

#region Identity

function Get-UserSid {
    <#
    .SYNOPSIS
        Resolves a logon name to a SID without the ActiveDirectory module.
    #>
    param([string]$UserName, [string]$Domain = $env:USERDOMAIN)
    if (-not $UserName) { return $null }
    $short = $UserName -replace '^.*\\', ''
    try {
        return (New-Object System.Security.Principal.NTAccount($Domain, $short)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    }
    catch { }
    try {
        $searcher = [adsisearcher]"(&(objectCategory=user)(sAMAccountName=$short))"
        $result = $searcher.FindOne()
        if ($result) {
            return (New-Object System.Security.Principal.SecurityIdentifier($result.Properties['objectsid'][0], 0)).Value
        }
    }
    catch { }
    return $null
}

function Get-UserFromSid {
    param([string]$Sid)
    if (-not $Sid) { return $null }
    try {
        return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate(
            [System.Security.Principal.NTAccount]).Value
    }
    catch { return $null }
}

#endregion

#region Sessions

function ConvertFrom-QueryUser {
    <#
    .SYNOPSIS
        Parses "query user" output into objects. Works with any display language:
        the session ID is the first purely numeric column, the state follows it.
    #>
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        $tokens = ($line -replace '^\s*>', '').Trim() -split '\s+'
        if ($tokens.Count -lt 3) { continue }
        for ($i = 1; $i -lt $tokens.Count - 1; $i++) {
            if ($tokens[$i] -match '^\d+$') {
                [PSCustomObject]@{
                    UserName  = $tokens[0]
                    SessionId = [int]$tokens[$i]
                    State     = $tokens[$i + 1]
                }
                break
            }
        }
    }
}

function Get-RdsUserSession {
    <#
    .SYNOPSIS
        Lists user sessions on a session host using "query user" (no RemoteDesktop module needed).
    #>
    param([string]$ComputerName = $env:COMPUTERNAME)
    $queryArgs = @('user')
    if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME) { $queryArgs += "/server:$ComputerName" }
    $raw = & query.exe @queryArgs 2>&1 | ForEach-Object { "$_" }
    foreach ($s in (ConvertFrom-QueryUser -Lines $raw)) {
        $s | Add-Member -NotePropertyName ComputerName -NotePropertyValue (Get-ShortName $ComputerName) -PassThru
    }
}

function Test-SessionActive {
    # "Active" in English; localized names start differently, so treat anything that is not Disc* as active.
    param([string]$State)
    return ($State -and $State -notmatch '^Disc')
}

#endregion

#region Profile disks

function Get-ProfileDiskCandidatePath {
    <#
    .SYNOPSIS
        Returns the expected profile disk path(s) for a user in a farm.
    .DESCRIPTION
        UPD:     <share>\UVHD-<SID>.vhdx
        FSLogix: <share>\<SID>_<user>\Profile_<user>.vhdx   (default folder naming)
                 <share>\<user>_<SID>\Profile_<user>.vhdx   (FlipFlopProfileDirectoryName = 1)
    #>
    param([hashtable]$Farm, [string]$Sid, [string]$UserName)
    $short = $UserName -replace '^.*\\', ''
    if ($Farm.ProfileType -eq 'FSLogix') {
        foreach ($ext in 'vhdx', 'vhd') {
            Join-Path $Farm.ProfileShare ("{0}_{1}\Profile_{1}.{2}" -f $Sid, $short, $ext)
            Join-Path $Farm.ProfileShare ("{1}_{0}\Profile_{1}.{2}" -f $Sid, $short, $ext)
        }
    }
    else {
        Join-Path $Farm.ProfileShare "UVHD-$Sid.vhdx"
        Join-Path $Farm.ProfileShare "UVHD-$Sid.vhd"
    }
}

function Find-ProfileDisk {
    <#
    .SYNOPSIS
        Finds a user's profile disk in a farm. Returns a FileInfo or $null.
    #>
    param([hashtable]$Farm, [string]$Sid, [string]$UserName)
    foreach ($path in (Get-ProfileDiskCandidatePath -Farm $Farm -Sid $Sid -UserName $UserName)) {
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($item) { return $item }
    }
    if ($Farm.ProfileType -eq 'FSLogix') {
        # Custom SIDDirNamePattern: look one level deep for any folder containing the SID.
        $dir = Get-ChildItem -LiteralPath $Farm.ProfileShare -Directory -Filter "*$Sid*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dir) {
            return Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.vhdx', '.vhd' } | Select-Object -First 1
        }
    }
    return $null
}

function Get-SidFromProfileDiskPath {
    param([string]$Path)
    if ($Path -match '(S-1-5-21-\d+-\d+-\d+-\d+)') { return $Matches[1] }
    return $null
}

function Get-ProfileRoot {
    <#
    .SYNOPSIS
        Returns the folder inside a mounted profile disk that contains AppData.
        UPD keeps the profile at the volume root, FSLogix under \Profile.
    #>
    param([string]$VolumeRoot)
    foreach ($candidate in @($VolumeRoot, (Join-Path $VolumeRoot 'Profile'))) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'AppData')) { return $candidate }
    }
    $users = Join-Path $VolumeRoot 'Users'
    if (Test-Path -LiteralPath $users) {
        $dir = Get-ChildItem -LiteralPath $users -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin 'Public', 'Default', 'Default User', 'All Users' } | Select-Object -First 1
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir.FullName 'AppData'))) { return $dir.FullName }
    }
    return $null
}

function Mount-ProfileDisk {
    <#
    .SYNOPSIS
        Attaches a VHD(X) with Mount-DiskImage (no Hyper-V role needed) and returns its volume root.
    .DESCRIPTION
        Assigns a drive letter if the partition has none. Always pair with Dismount-ProfileDisk in a finally block.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$ReadOnly
    )
    $access = if ($ReadOnly) { 'ReadOnly' } else { 'ReadWrite' }
    $image = Mount-DiskImage -ImagePath $Path -Access $access -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 2
    $disk = $image | Get-DiskImage | Get-Disk
    $partition = $disk | Get-Partition | Where-Object { $_.Type -ne 'Reserved' } |
        Sort-Object Size -Descending | Select-Object -First 1
    if (-not $partition) { throw "No data partition found in $Path." }

    if (-not $partition.DriveLetter -or $partition.DriveLetter -eq [char]0) {
        $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
        Start-Sleep -Seconds 1
        $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
    }
    $volume = $partition | Get-Volume
    return [PSCustomObject]@{
        Path       = $Path
        DiskNumber = $disk.Number
        Root       = ([string]$partition.DriveLetter + ':\')
        SizeGB     = [Math]::Round($volume.Size / 1GB, 2)
        UsedGB     = [Math]::Round(($volume.Size - $volume.SizeRemaining) / 1GB, 2)
        FreeGB     = [Math]::Round($volume.SizeRemaining / 1GB, 2)
    }
}

function Dismount-ProfileDisk {
    <#
    .SYNOPSIS
        Detaches a disk image with up to three attempts. Returns $true when it is no longer attached.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    for ($i = 1; $i -le 3; $i++) {
        Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 2
        $state = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
        if (-not $state -or -not $state.Attached) { return $true }
    }
    return $false
}

function Get-FolderSize {
    # Returns @{ Bytes; Files } for everything under a folder (hidden and system files included).
    param([string]$Path)
    $bytes = [double]0
    $files = 0
    foreach ($f in (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $bytes += $f.Length
        $files++
    }
    return [PSCustomObject]@{ Bytes = $bytes; Files = $files }
}

# Well-known caches inside a user profile, relative to the profile root.
# Junk = $true means the content is rebuilt automatically and can be deleted when the user is logged off.
$script:ProfileFolderCatalog = @(
    [PSCustomObject]@{ Name = '1C:Enterprise cache';  Set = '1C';      Junk = $true;  Path = 'AppData\Local\1C\1cv8' }
    [PSCustomObject]@{ Name = 'Temp';                 Set = 'Temp';    Junk = $true;  Path = 'AppData\Local\Temp' }
    [PSCustomObject]@{ Name = 'Crash dumps';          Set = 'Temp';    Junk = $true;  Path = 'AppData\Local\CrashDumps' }
    [PSCustomObject]@{ Name = 'WER reports';          Set = 'Temp';    Junk = $true;  Path = 'AppData\Local\Microsoft\Windows\WER' }
    [PSCustomObject]@{ Name = 'INetCache';            Set = 'Browser'; Junk = $true;  Path = 'AppData\Local\Microsoft\Windows\INetCache' }
    [PSCustomObject]@{ Name = 'Chrome cache';         Set = 'Browser'; Junk = $true;  Path = 'AppData\Local\Google\Chrome\User Data\Default\Cache' }
    [PSCustomObject]@{ Name = 'Edge cache';           Set = 'Browser'; Junk = $true;  Path = 'AppData\Local\Microsoft\Edge\User Data\Default\Cache' }
    [PSCustomObject]@{ Name = 'Explorer thumbnails';  Set = 'Temp';    Junk = $true;  Path = 'AppData\Local\Microsoft\Windows\Explorer' }
    [PSCustomObject]@{ Name = 'Acrobat AcroCef cache'; Set = 'Adobe';  Junk = $true;  Path = 'AppData\LocalLow\Adobe\AcroCef\DC\Acrobat\Cache' }
    [PSCustomObject]@{ Name = 'Acrobat cache';        Set = 'Adobe';   Junk = $true;  Path = 'AppData\Local\Adobe\Acrobat\DC\Cache' }
    [PSCustomObject]@{ Name = 'Teams (classic) cache'; Set = 'Office'; Junk = $true;  Path = 'AppData\Roaming\Microsoft\Teams\Cache' }
    [PSCustomObject]@{ Name = 'Office file cache';    Set = 'Office';  Junk = $false; Path = 'AppData\Local\Microsoft\Office\16.0\OfficeFileCache' }
    [PSCustomObject]@{ Name = 'Desktop';              Set = 'Data';    Junk = $false; Path = 'Desktop' }
    [PSCustomObject]@{ Name = 'Documents';            Set = 'Data';    Junk = $false; Path = 'Documents' }
    [PSCustomObject]@{ Name = 'Downloads';            Set = 'Data';    Junk = $false; Path = 'Downloads' }
    [PSCustomObject]@{ Name = 'Pictures';             Set = 'Data';    Junk = $false; Path = 'Pictures' }
)

function Get-ProfileFolderCatalog {
    param([string[]]$Set)
    if ($Set) { return $script:ProfileFolderCatalog | Where-Object { $Set -contains $_.Set } }
    return $script:ProfileFolderCatalog
}

#endregion

#region Remoting

function Get-FunctionDefinition {
    <#
    .SYNOPSIS
        Returns the source of local functions so they can be re-created inside Invoke-Command:
        Invoke-Command { param($defs) . ([scriptblock]::Create($defs)); ... } -ArgumentList (Get-FunctionDefinition A, B)
    #>
    param([string[]]$Name)
    ($Name | ForEach-Object { "function $_ {`n$((Get-Item "function:$_").Definition)`n}" }) -join "`n"
}

function Invoke-OnHost {
    <#
    .SYNOPSIS
        Runs a script block locally or over WinRM, with connection timeouts. Returns $null on failure.
    #>
    param(
        [string]$ComputerName,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSec = 300,
        [string]$DnsSuffix
    )
    if (-not $ComputerName -or (Get-ShortName $ComputerName) -eq $env:COMPUTERNAME) {
        return & $ScriptBlock @ArgumentList
    }
    $option = New-PSSessionOption -OpenTimeout 8000 -OperationTimeout ($TimeoutSec * 1000)
    try {
        return Invoke-Command -ComputerName (Resolve-Fqdn $ComputerName $DnsSuffix) -ScriptBlock $ScriptBlock `
            -ArgumentList $ArgumentList -SessionOption $option -ErrorAction Stop
    }
    catch {
        Write-Warning "$ComputerName : $($_.Exception.Message)"
        return $null
    }
}

#endregion

#region Report output

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

$script:ReportLines = New-Object System.Collections.Generic.List[string]

function Write-ReportLine {
    # Prints a colored line and keeps it for Save-Report.
    param([string]$Text = '', [System.ConsoleColor]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $script:ReportLines.Add($Text)
}

function Write-ReportHeader {
    param([string]$Text)
    Write-ReportLine ''
    Write-ReportLine ('=' * 90) DarkCyan
    Write-ReportLine ('  ' + $Text) Cyan
    Write-ReportLine ('=' * 90) DarkCyan
}

function Write-ReportSection {
    param([string]$Text)
    Write-ReportLine ''
    Write-ReportLine ('--- ' + $Text + ' ' + ('-' * [Math]::Max(1, 84 - $Text.Length))) DarkGray
}

function Save-Report {
    <#
    .SYNOPSIS
        Writes collected report lines to <LogPath>\<Prefix>_<COMPUTER>_<timestamp>.txt and keeps the newest -Keep files.
    #>
    param([string]$LogPath, [string]$Prefix, [int]$Keep = 60)
    if (-not $LogPath) { return $null }
    if (-not (Test-Path -LiteralPath $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
    $file = Join-Path $LogPath ('{0}_{1}_{2:yyyyMMdd_HHmm}.txt' -f $Prefix, $env:COMPUTERNAME, (Get-Date))
    $script:ReportLines | Out-File -FilePath $file -Encoding UTF8
    Get-ChildItem -LiteralPath $LogPath -Filter "$Prefix`_*.txt" | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $Keep | Remove-Item -Force -ErrorAction SilentlyContinue
    return $file
}

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#endregion
