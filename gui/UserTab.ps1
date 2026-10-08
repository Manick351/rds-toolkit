# "User" tab: find a user's sessions, profile disks and ProfileList entries across all farms, and act on them.

function New-UserTab {
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = 'User'
    $tab.BackColor = [System.Drawing.Color]::WhiteSmoke

    $tab.Controls.Add((New-Label 'Login:' 10 14 50))
    $script:TxtLogin = New-Object System.Windows.Forms.TextBox
    $script:TxtLogin.Location = New-Object System.Drawing.Point(60, 11)
    $script:TxtLogin.Size = New-Object System.Drawing.Size(160, 22)
    $tab.Controls.Add($script:TxtLogin)
    $script:BtnFind = New-Button 'Find' 230 9 90
    $tab.Controls.Add($script:BtnFind)
    $script:LblInfo = New-Label '' 330 14 700
    $script:LblInfo.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $tab.Controls.Add($script:LblInfo)

    $tab.Controls.Add((New-Label 'Sessions:' 10 46 100))
    $script:GridSessions = New-Grid 10 66 1020 100
    $tab.Controls.Add($script:GridSessions)
    $script:BtnLogoff = New-Button 'Log off session' 10 172 150
    $script:BtnRepair = New-Button 'Repair profile entry' 170 172 150
    $tab.Controls.Add($script:BtnLogoff)
    $tab.Controls.Add($script:BtnRepair)
    $tab.Controls.Add((New-Label '(select a row in the ProfileList table below to repair)' 330 177 340))

    $tab.Controls.Add((New-Label 'Profile disks:' 10 208 120))
    $script:GridDisks = New-Grid 10 228 1020 90
    $tab.Controls.Add($script:GridDisks)
    $script:BtnInspect = New-Button 'Analyze content' 10 324 130
    $script:BtnClean = New-Button 'Clear caches' 150 324 110
    $script:BtnCompact = New-Button 'Compact disk' 270 324 110
    $tab.Controls.Add($script:BtnInspect)
    $tab.Controls.Add($script:BtnClean)
    $tab.Controls.Add($script:BtnCompact)
    $tab.Controls.Add((New-Label 'New size, GB:' 400 329 90))
    $script:NumSize = New-Object System.Windows.Forms.NumericUpDown
    $script:NumSize.Location = New-Object System.Drawing.Point(490, 326)
    $script:NumSize.Size = New-Object System.Drawing.Size(60, 22)
    $script:NumSize.Minimum = 2
    $script:NumSize.Maximum = $Global:Config.Settings.ResizeMaxGB
    $script:NumSize.Value = [Math]::Min($Global:Config.Settings.ResizeDefaultGB, $Global:Config.Settings.ResizeMaxGB)
    $tab.Controls.Add($script:NumSize)
    $script:BtnResize = New-Button 'Expand disk' 560 324 110
    $tab.Controls.Add($script:BtnResize)

    $tab.Controls.Add((New-Label 'ProfileList on session hosts:' 10 360 250))
    $script:GridRegistry = New-Grid 10 380 1020 120
    $tab.Controls.Add($script:GridRegistry)

    $script:CurrentSid = $null
    $script:CurrentLogin = $null

    $script:SelectedDisk = {
        if ($script:GridDisks.SelectedRows.Count -eq 0) { Add-Log 'Select a profile disk first' 'WARN'; return $null }
        $row = $script:GridDisks.SelectedRows[0].DataBoundItem
        $farm = $Global:Config.Farms | Where-Object { $_.Name -eq $row.Farm } | Select-Object -First 1
        return [PSCustomObject]@{ Row = $row; Farm = $farm }
    }

    $script:BtnFind.Add_Click({
            try {
                $login = $script:TxtLogin.Text.Trim() -replace '^.*\\', ''
                if (-not $login) { Add-Log 'Enter a login' 'WARN'; return }
                Set-Busy $true
                Add-Log "Looking up $login"
                $sid = Get-UserSid -UserName $login -Domain $Global:Config.Domain
                $script:CurrentSid = $sid
                $script:CurrentLogin = $login
                if (-not $sid) {
                    $script:LblInfo.Text = 'SID not found'
                    $script:LblInfo.ForeColor = [System.Drawing.Color]::Red
                    Add-Log 'SID not resolved, check the login' 'ERROR'
                    return
                }
                $account = Get-UserFromSid $sid
                $script:LblInfo.Text = "SID: $sid   |   account: $account"
                $script:LblInfo.ForeColor = [System.Drawing.Color]::Black

                $sessions = @(Find-UserSessions -UserName $login)
                Set-GridData -Grid $script:GridSessions -Data $sessions
                Add-Log "Sessions: $($sessions.Count)"

                $disks = @(Find-UserProfileDisks -Sid $sid -UserName $login)
                Set-GridData -Grid $script:GridDisks -Data $disks
                Add-Log "Profile disks: $($disks.Count)"

                # Query ProfileList on hosts where the user has a disk or a session; all hosts if neither.
                $hosts = @()
                foreach ($d in $disks) { $hosts += ($Global:Config.Farms | Where-Object { $_.Name -eq $d.Farm }).SessionHosts }
                $hosts += $sessions | ForEach-Object { $_.Host }
                if (-not $hosts) {
                    $hosts = $Global:Config.Farms | ForEach-Object { $_.SessionHosts }
                    Add-Log 'No disk or session found, querying all session hosts' 'WARN'
                }
                $hosts = @($hosts | Where-Object { $_ } | ForEach-Object { Get-ShortName $_ } | Sort-Object -Unique)
                Add-Log ('Querying ProfileList on: ' + ($hosts -join ', '))
                $registry = @(Get-ProfileRegistryState -Sid $sid -Hosts $hosts)
                Set-GridData -Grid $script:GridRegistry -Data $registry
                $broken = @($registry | Where-Object { $_.Key -like '*.bak' -or $_.Temp -eq $true })
                if ($broken) { Add-Log "Broken profile entries found on: $(($broken.Server | Sort-Object -Unique) -join ', ')" 'WARN' }
            }
            catch { Add-Log ('Lookup failed: ' + $_.Exception.Message) 'ERROR' }
            finally { Set-Busy $false }
        })

    $script:BtnLogoff.Add_Click({
            try {
                if ($script:GridSessions.SelectedRows.Count -eq 0) { Add-Log 'Select a session first' 'WARN'; return }
                $row = $script:GridSessions.SelectedRows[0].DataBoundItem
                if (-not (Test-ActionAllowed -Operation "Log off session $($row.SessionId) of $($row.User) on $($row.Host)" -Confirm)) { return }
                Set-Busy $true
                if (Stop-UserSession -ComputerName $row.Host -SessionId $row.SessionId) { Add-Log 'Session ended' 'OK' }
                else { Add-Log 'Logoff not confirmed yet, refresh in a few seconds' 'WARN' }
            }
            catch { Add-Log ('Error: ' + $_.Exception.Message) 'ERROR' }
            finally { Set-Busy $false }
        })

    $script:BtnRepair.Add_Click({
            try {
                if (-not $script:CurrentSid) { Add-Log 'Find a user first' 'WARN'; return }
                if ($script:GridRegistry.SelectedRows.Count -eq 0) { Add-Log 'Select the server row in the ProfileList table' 'WARN'; return }
                $server = $script:GridRegistry.SelectedRows[0].DataBoundItem.Server
                if (-not (Test-ActionAllowed -Operation "Restore the profile entry of $($script:CurrentLogin) on $server" -Confirm)) { return }
                Set-Busy $true
                $r = Repair-ProfileRegistry -Sid $script:CurrentSid -ComputerName $server
                if ($r) {
                    foreach ($s in $r.Steps) { Add-Log "  $s" }
                    Add-Log $r.Message $(if ($r.Ok) { 'OK' } else { 'ERROR' })
                }
            }
            catch { Add-Log ('Error: ' + $_.Exception.Message) 'ERROR' }
            finally { Set-Busy $false }
        })

    $script:BtnInspect.Add_Click({
            try {
                $d = & $script:SelectedDisk
                if (-not $d) { return }
                Set-Busy $true
                Add-Log "Analyzing $($d.Row.Path) (read-only)"
                $r = Get-ProfileDiskContent -Farm $d.Farm -UncPath $d.Row.Path
                if ($r -and $r.Ok) {
                    Add-Log ('  volume {0} GB, used {1} GB, free {2} GB' -f $r.Volume.SizeGB, $r.Volume.UsedGB, $r.Volume.FreeGB)
                    Add-Log ('  empty space in the file: {0:N2} GB - returned by "Compact disk"' -f ($d.Row.SizeGB - $r.Volume.UsedGB))
                    foreach ($x in $r.Rows) { Add-Log ('  [{0}] {1} = {2} MB' -f $(if ($x.Junk) { 'cache' } else { 'data' }), $x.Name, $x.MB) }
                }
                elseif ($r) { Add-Log $r.Message 'WARN' }
            }
            catch { Add-Log ('Error: ' + $_.Exception.Message) 'ERROR' }
            finally { Set-Busy $false }
        })

    $script:BtnClean.Add_Click({
            try {
                $d = & $script:SelectedDisk
                if (-not $d) { return }
                if (-not (Test-ActionAllowed -Operation "Delete caches inside $($d.Row.Path)" -Confirm)) { return }
                Set-Busy $true
                $r = Clear-ProfileDiskJunk -Farm $d.Farm -UncPath $d.Row.Path
                if ($r -and $r.Ok) { Add-Log "Caches deleted: $($r.FreedMB) MB. Run 'Compact disk' to return the space to the file server." 'OK' }
                elseif ($r) { Add-Log $r.Message 'WARN' }
            }
            catch { Add-Log ('Error: ' + $_.Exception.Message) 'ERROR' }
            finally { Set-Busy $false }
        })

    $script:BtnCompact.Add_Click({
            try {
                $d = & $script:SelectedDisk
                if (-not $d) { return }
                if (-not (Test-ActionAllowed -Operation "Compact $($d.Row.Path)")) { return }
                Set-Busy $true
                $r = Compress-ProfileDisk -Farm $d.Farm -UncPath $d.Row.Path
                if ($r -and $r.Ok) { Add-Log ('Compacted: {0} -> {1} GB' -f $r.BeforeGB, $r.AfterGB) 'OK' }
                elseif ($r) { Add-Log $r.Message 'WARN' }
            }
            catch { Add-Log ('Error: ' + $_.Exception.Message) 'ERROR' }
            finally { Set-Busy $false }
        })

    $script:BtnResize.Add_Click({
            try {
                $d = & $script:SelectedDisk
                if (-not $d) { return }
                $size = [int]$script:NumSize.Value
                if ($size -le [double]$d.Row.SizeGB) { Add-Log 'New size must be larger than the current file size' 'WARN'; return }
                if (-not (Test-ActionAllowed -Operation "Expand $($d.Row.Path) to $size GB" -Confirm)) { return }
                Set-Busy $true
                $r = Resize-ProfileDisk -Farm $d.Farm -UncPath $d.Row.Path -NewSizeGB $size
                if ($r) { Add-Log $r.Message $(if ($r.Ok) { 'OK' } else { 'ERROR' }) }
            }
            catch { Add-Log ('Error: ' + $_.Exception.Message) 'ERROR' }
            finally { Set-Busy $false }
        })

    $script:TxtLogin.Add_KeyDown({
            if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; $script:BtnFind.PerformClick() }
        })

    return $tab
}
