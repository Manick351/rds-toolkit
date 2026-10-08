# GUI helpers and profile operations for RDS-Toolkit.ps1. Requires lib\Common.ps1 to be loaded first.

#region Log, mode, controls

$Global:ActionMode = $false
$Global:LogBox = $null
$Global:LogFile = $null

function Initialize-ToolkitLog {
    param([string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
    $Global:LogFile = Join-Path $LogPath ('Toolkit_{0}_{1:yyyyMMdd}.log' -f $env:COMPUTERNAME, (Get-Date))
}

function Add-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0:HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
    if ($Global:LogBox) {
        $Global:LogBox.AppendText($line + "`r`n")
        $Global:LogBox.SelectionStart = $Global:LogBox.TextLength
        $Global:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($Global:LogFile) {
        try { [IO.File]::AppendAllText($Global:LogFile, ($line + "`r`n"), [Text.Encoding]::UTF8) } catch { }
    }
}

function Set-Busy {
    param([bool]$On)
    if ($Global:MainForm) {
        $Global:MainForm.Cursor = if ($On) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Test-ActionAllowed {
    <#
        Gate for every change. In CHECK mode the operation is blocked and logged;
        in ACTION mode it is logged and, with -Confirm, needs a Yes from the operator.
    #>
    param([string]$Operation, [switch]$Confirm)
    if (-not $Global:ActionMode) {
        Add-Log ('CHECK MODE: "' + $Operation + '" was not executed') 'BLOCK'
        [void][System.Windows.Forms.MessageBox]::Show(
            "The toolkit is in CHECK mode.`n`n""$Operation"" is blocked.`nSwitch to ACTION mode at the top of the window.",
            'Check mode', 'OK', 'Information')
        return $false
    }
    if ($Confirm) {
        $answer = [System.Windows.Forms.MessageBox]::Show("$Operation`n`nContinue?", 'Confirm', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { Add-Log ('Cancelled: ' + $Operation) 'WARN'; return $false }
    }
    Add-Log ('EXECUTING: ' + $Operation) 'ACTION'
    return $true
}

function New-Grid {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Location = New-Object System.Drawing.Point($X, $Y)
    $g.Size = New-Object System.Drawing.Size($W, $H)
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.ReadOnly = $true
    $g.SelectionMode = 'FullRowSelect'
    $g.MultiSelect = $false
    $g.AutoSizeColumnsMode = 'Fill'
    $g.RowHeadersVisible = $false
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.Anchor = 'Top,Left,Right'
    return $g
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 150, [int]$H = 28)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    return $b
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 200)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, 18)
    return $l
}

function Set-GridData {
    param([System.Windows.Forms.DataGridView]$Grid, [object[]]$Data)
    $Grid.DataSource = $null
    if (-not $Data) { return }
    $list = New-Object System.Collections.ArrayList
    foreach ($d in $Data) { [void]$list.Add($d) }
    $Grid.DataSource = $list
}

#endregion

#region Remote execution

function Invoke-HostCommand {
    # Like Invoke-OnHost from lib\Common.ps1, but reports problems to the GUI log.
    param([string]$ComputerName, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [int]$TimeoutSec = 120)
    if (-not $ComputerName) { return $null }
    $isLocal = (Get-ShortName $ComputerName) -eq $env:COMPUTERNAME
    if (-not $isLocal -and -not (Test-Connection -ComputerName (Resolve-Fqdn $ComputerName $Global:Config.DnsSuffix) -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Add-Log "$ComputerName : unreachable, skipped" 'WARN'
        return $null
    }
    try {
        if ($isLocal) { return & $ScriptBlock @ArgumentList }
        $option = New-PSSessionOption -OpenTimeout 8000 -OperationTimeout ($TimeoutSec * 1000)
        return Invoke-Command -ComputerName (Resolve-Fqdn $ComputerName $Global:Config.DnsSuffix) -ScriptBlock $ScriptBlock `
            -ArgumentList $ArgumentList -SessionOption $option -ErrorAction Stop
    }
    catch {
        Add-Log "$ComputerName : $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

function Get-DiskTarget {
    # Where to operate on a profile disk: on the file server with a local path (admin share), or here with the UNC path.
    param([hashtable]$Farm, [string]$UncPath)
    $localRoot = ConvertTo-LocalSharePath $Farm.ProfileShare
    if ($localRoot) {
        $relative = $UncPath.Substring($Farm.ProfileShare.TrimEnd('\').Length).TrimStart('\')
        return [PSCustomObject]@{ ComputerName = $Farm.StorageHost; Path = (Join-Path $localRoot $relative) }
    }
    return [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; Path = $UncPath }
}

#endregion

#region Lookups

function Find-UserSessions {
    param([string]$UserName)
    $short = ($UserName -replace '^.*\\', '').ToLower()
    $results = @()
    $checked = @{}
    $haveRdModule = [bool](Get-Module -ListAvailable -Name RemoteDesktop)
    foreach ($farm in $Global:Config.Farms) {
        if ($haveRdModule -and $farm.ContainsKey('Broker') -and $farm.Broker -and $farm.ContainsKey('Collection') -and $farm.Collection) {
            try {
                Import-Module RemoteDesktop -ErrorAction Stop
                foreach ($s in (Get-RDUserSession -ConnectionBroker $farm.Broker -CollectionName $farm.Collection -ErrorAction Stop)) {
                    if ("$($s.UserName)".ToLower() -eq $short) {
                        $results += [PSCustomObject]@{ Farm = $farm.Name; Host = Get-ShortName $s.HostServer; User = $s.UserName; SessionId = [int]$s.UnifiedSessionId; State = "$($s.SessionState)"; Source = 'broker' }
                    }
                }
                foreach ($h in $farm.SessionHosts) { $checked[(Get-ShortName $h)] = $true }
                continue
            }
            catch { Add-Log "Broker $($farm.Broker): $($_.Exception.Message); falling back to query user" 'WARN' }
        }
        foreach ($h in $farm.SessionHosts) {
            $key = Get-ShortName $h
            if ($checked.ContainsKey($key)) { continue }
            $checked[$key] = $true
            foreach ($s in (Get-RdsUserSession -ComputerName $h)) {
                if ($s.UserName.ToLower() -eq $short) {
                    $results += [PSCustomObject]@{ Farm = $farm.Name; Host = $key; User = $s.UserName; SessionId = $s.SessionId; State = $s.State; Source = 'query user' }
                }
            }
        }
    }
    return $results
}

function Find-UserProfileDisks {
    param([string]$Sid, [string]$UserName)
    foreach ($farm in $Global:Config.Farms) {
        $f = Find-ProfileDisk -Farm $farm -Sid $Sid -UserName $UserName
        if (-not $f) { continue }
        [PSCustomObject]@{
            Farm     = $farm.Name
            Type     = $farm.ProfileType
            SizeGB   = [Math]::Round($f.Length / 1GB, 2)
            LimitGB  = $farm.MaxProfileGB
            Modified = $f.LastWriteTime
            IdleDays = [Math]::Round(((Get-Date) - $f.LastWriteTime).TotalDays, 1)
            Path     = $f.FullName
        }
    }
}

function Get-ProfileRegistryState {
    param([string]$Sid, [string[]]$Hosts)
    foreach ($h in $Hosts) {
        $r = Invoke-HostCommand -ComputerName $h -ArgumentList $Sid -ScriptBlock {
            param($Sid)
            $list = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
            $entries = foreach ($k in (Get-ChildItem $list -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "$Sid*" })) {
                $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                [PSCustomObject]@{ Key = $k.PSChildName; Path = $p.ProfileImagePath; State = $p.State; Temp = [bool]($p.State -band 0x800) }
            }
            $mounted = [bool](Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'File Backed Virtual' -and $_.Location -like "*$Sid*" })
            [PSCustomObject]@{ Server = $env:COMPUTERNAME; Entries = @($entries); Mounted = $mounted }
        }
        if (-not $r) { continue }
        if (-not @($r.Entries).Count) {
            [PSCustomObject]@{ Server = $r.Server; Key = '(no entry)'; Path = ''; State = ''; Temp = ''; DiskAttached = $r.Mounted }
            continue
        }
        foreach ($e in $r.Entries) {
            [PSCustomObject]@{ Server = $r.Server; Key = $e.Key; Path = $e.Path; State = $e.State; Temp = $e.Temp; DiskAttached = $r.Mounted }
        }
    }
}

#endregion

#region Actions

function Repair-ProfileRegistry {
    # Restores ProfileList\SID from SID.bak with an export, path verification and rollback.
    param([string]$Sid, [string]$ComputerName)
    Invoke-HostCommand -ComputerName $ComputerName -ArgumentList $Sid, $Global:Config.Settings.LogPath -ScriptBlock {
        param($Sid, $LogDir)
        $ps = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $reg = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $steps = @()
        $fail = { param($msg) [PSCustomObject]@{ Ok = $false; Message = $msg; Steps = $steps } }

        $bak = Get-ItemProperty "$ps\$Sid.bak" -ErrorAction SilentlyContinue
        if (-not $bak) { return & $fail 'No .bak entry: nothing to repair.' }
        if (-not $bak.ProfileImagePath -or $bak.ProfileImagePath -match '\\TEMP\.') { return & $fail '.bak entry has no or a temporary profile path.' }
        if (Test-Path "Registry::HKEY_USERS\$Sid") { return & $fail 'Registry hive is loaded: the user is logged on.' }

        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $backup = Join-Path $LogDir ('ProfileList_{0}_{1:yyyyMMdd_HHmmss}.reg' -f $env:COMPUTERNAME, (Get-Date))
        & reg.exe export $reg $backup /y 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $backup)) { return & $fail 'Registry export failed: nothing changed.' }
        $steps += "backup: $backup"

        & reg.exe delete "$reg\$Sid" /f 2>&1 | Out-Null
        & reg.exe copy "$reg\$Sid.bak" "$reg\$Sid" /s /f 2>&1 | Out-Null
        $check = Get-ItemProperty "$ps\$Sid" -ErrorAction SilentlyContinue
        if (-not $check -or $check.ProfileImagePath -ne $bak.ProfileImagePath) {
            & reg.exe import $backup 2>&1 | Out-Null
            return & $fail 'Path verification failed: ProfileList rolled back.'
        }
        $steps += "path verified: $($check.ProfileImagePath)"
        & reg.exe delete "$reg\$Sid.bak" /f 2>&1 | Out-Null
        Set-ItemProperty -Path "$ps\$Sid" -Name State -Value 0 -Type DWord
        Set-ItemProperty -Path "$ps\$Sid" -Name RefCount -Value 0 -Type DWord
        $steps += '.bak removed, State and RefCount reset'
        [PSCustomObject]@{ Ok = $true; Message = "Profile entry restored: $($check.ProfileImagePath)"; Steps = $steps }
    }
}

function Stop-UserSession {
    param([string]$ComputerName, [int]$SessionId)
    & logoff.exe $SessionId "/server:$ComputerName" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    return -not (Get-RdsUserSession -ComputerName $ComputerName | Where-Object { $_.SessionId -eq $SessionId })
}

$script:DiskFunctions = 'Mount-ProfileDisk', 'Dismount-ProfileDisk', 'Get-FolderSize', 'Get-ProfileRoot'

function Get-ProfileDiskContent {
    param([hashtable]$Farm, [string]$UncPath)
    $target = Get-DiskTarget -Farm $Farm -UncPath $UncPath
    Invoke-HostCommand -ComputerName $target.ComputerName -TimeoutSec 600 `
        -ArgumentList (Get-FunctionDefinition $script:DiskFunctions), $target.Path, @(Get-ProfileFolderCatalog) -ScriptBlock {
        param($Defs, $Path, $Catalog)
        . ([scriptblock]::Create($Defs))
        if ($Path -notlike '\\*' -and @(Get-SmbOpenFile -ErrorAction SilentlyContinue | Where-Object { (Split-Path $_.Path -Leaf) -eq (Split-Path $Path -Leaf) }).Count) {
            return [PSCustomObject]@{ Ok = $false; Message = 'Disk is open (user logged on): not mounted.' }
        }
        $mount = $null
        try {
            $mount = Mount-ProfileDisk -Path $Path -ReadOnly
            $root = Get-ProfileRoot $mount.Root
            $rows = @()
            if ($root) {
                foreach ($e in $Catalog) {
                    $full = Join-Path $root $e.Path
                    if (-not (Test-Path -LiteralPath $full)) { continue }
                    $size = Get-FolderSize $full
                    if ($size.Bytes -ge 1MB) { $rows += [PSCustomObject]@{ Name = $e.Name; Junk = $e.Junk; MB = [Math]::Round($size.Bytes / 1MB); Files = $size.Files } }
                }
            }
            [PSCustomObject]@{ Ok = $true; Volume = $mount; Rows = @($rows | Sort-Object MB -Descending); Dismounted = $false }
        }
        catch { [PSCustomObject]@{ Ok = $false; Message = $_.Exception.Message } }
        finally { if ($mount) { [void](Dismount-ProfileDisk -Path $Path) } }
    }
}

function Clear-ProfileDiskJunk {
    param([hashtable]$Farm, [string]$UncPath)
    $target = Get-DiskTarget -Farm $Farm -UncPath $UncPath
    Invoke-HostCommand -ComputerName $target.ComputerName -TimeoutSec 900 `
        -ArgumentList (Get-FunctionDefinition $script:DiskFunctions), $target.Path, @(Get-ProfileFolderCatalog | Where-Object Junk) -ScriptBlock {
        param($Defs, $Path, $Catalog)
        . ([scriptblock]::Create($Defs))
        if ($Path -notlike '\\*' -and @(Get-SmbOpenFile -ErrorAction SilentlyContinue | Where-Object { (Split-Path $_.Path -Leaf) -eq (Split-Path $Path -Leaf) }).Count) {
            return [PSCustomObject]@{ Ok = $false; Message = 'Disk is open (user logged on).' }
        }
        $mount = $null
        $freed = [double]0
        try {
            $mount = Mount-ProfileDisk -Path $Path
            $root = Get-ProfileRoot $mount.Root
            if (-not $root) { throw 'Profile folder not found inside the disk.' }
            foreach ($e in $Catalog) {
                $full = Join-Path $root $e.Path
                if (-not (Test-Path -LiteralPath $full)) { continue }
                $before = (Get-FolderSize $full).Bytes
                Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                $freed += $before - (Get-FolderSize $full).Bytes
            }
            [PSCustomObject]@{ Ok = $true; FreedMB = [Math]::Round($freed / 1MB) }
        }
        catch { [PSCustomObject]@{ Ok = $false; Message = $_.Exception.Message } }
        finally { if ($mount) { [void](Dismount-ProfileDisk -Path $Path) } }
    }
}

function Compress-ProfileDisk {
    param([hashtable]$Farm, [string]$UncPath)
    $target = Get-DiskTarget -Farm $Farm -UncPath $UncPath
    Invoke-HostCommand -ComputerName $target.ComputerName -TimeoutSec 1800 `
        -ArgumentList (Get-FunctionDefinition $script:DiskFunctions), $target.Path -ScriptBlock {
        param($Defs, $Path)
        . ([scriptblock]::Create($Defs))
        if ($Path -notlike '\\*' -and @(Get-SmbOpenFile -ErrorAction SilentlyContinue | Where-Object { (Split-Path $_.Path -Leaf) -eq (Split-Path $Path -Leaf) }).Count) {
            return [PSCustomObject]@{ Ok = $false; Message = 'Disk is open (user logged on).' }
        }
        $before = (Get-Item -LiteralPath $Path).Length
        try {
            $mount = Mount-ProfileDisk -Path $Path
            Optimize-Volume -DriveLetter $mount.Root.Substring(0, 1) -ReTrim -ErrorAction SilentlyContinue
        }
        catch { }
        finally { [void](Dismount-ProfileDisk -Path $Path) }

        $dpScript = Join-Path $env:TEMP ('compact_' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $dpScript -Encoding ASCII -Value @("select vdisk file=""$Path""", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk', 'exit')
        & diskpart.exe /s $dpScript 2>&1 | Out-Null
        $code = $LASTEXITCODE
        Remove-Item -LiteralPath $dpScript -Force -ErrorAction SilentlyContinue
        [void](Dismount-ProfileDisk -Path $Path)
        $after = (Get-Item -LiteralPath $Path).Length
        [PSCustomObject]@{ Ok = ($code -eq 0); Message = "diskpart exit code $code"; BeforeGB = [Math]::Round($before / 1GB, 2); AfterGB = [Math]::Round($after / 1GB, 2) }
    }
}

function Resize-ProfileDisk {
    # Expands the virtual disk with diskpart, then grows the partition to the new maximum.
    param([hashtable]$Farm, [string]$UncPath, [int]$NewSizeGB)
    $target = Get-DiskTarget -Farm $Farm -UncPath $UncPath
    Invoke-HostCommand -ComputerName $target.ComputerName -TimeoutSec 900 `
        -ArgumentList (Get-FunctionDefinition $script:DiskFunctions), $target.Path, $NewSizeGB -ScriptBlock {
        param($Defs, $Path, $SizeGB)
        . ([scriptblock]::Create($Defs))
        if ($Path -notlike '\\*' -and @(Get-SmbOpenFile -ErrorAction SilentlyContinue | Where-Object { (Split-Path $_.Path -Leaf) -eq (Split-Path $Path -Leaf) }).Count) {
            return [PSCustomObject]@{ Ok = $false; Message = 'Disk is open (user logged on).' }
        }
        $dpScript = Join-Path $env:TEMP ('expand_' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $dpScript -Encoding ASCII -Value @("select vdisk file=""$Path""", "expand vdisk maximum=$($SizeGB * 1024)", 'exit')
        $output = & diskpart.exe /s $dpScript 2>&1
        $code = $LASTEXITCODE
        Remove-Item -LiteralPath $dpScript -Force -ErrorAction SilentlyContinue
        if ($code -ne 0) { return [PSCustomObject]@{ Ok = $false; Message = 'diskpart did not expand the disk: ' + (($output | Select-Object -Last 3) -join ' ') } }

        $grown = $false
        try {
            $mount = Mount-ProfileDisk -Path $Path
            $partition = Get-Partition -DriveLetter $mount.Root.Substring(0, 1)
            $max = (Get-PartitionSupportedSize -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber).SizeMax
            if ($max -gt $partition.Size) {
                Resize-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -Size $max
                $grown = $true
            }
        }
        finally { [void](Dismount-ProfileDisk -Path $Path) }
        $msg = if ($grown) { 'virtual disk and partition expanded' } else { 'virtual disk expanded, partition already at maximum' }
        [PSCustomObject]@{ Ok = $true; Message = $msg; MaxGB = $SizeGB }
    }
}

#endregion
