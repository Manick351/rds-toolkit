<#
.SYNOPSIS
    WinForms tool for helpdesk / L2: everything about one user's RDS profile in one window.

.DESCRIPTION
    Enter a login and the tool shows, across all farms from the configuration:
      - the user's sessions (through the Connection Broker, or "query user" on each host);
      - profile disks (UPD or FSLogix) with size, limit and idle time;
      - ProfileList entries on session hosts (SID.bak pairs and TEMP flags = broken profile).

    Actions: log off a session, restore a broken profile entry (with export and rollback),
    analyze disk content read-only, clear caches inside the disk, compact it, expand it.

    The tool starts in CHECK mode: every change is blocked and logged. ACTION mode must be
    switched on explicitly, and destructive actions ask for confirmation. All operations are
    written to a daily log file.

.PARAMETER ConfigPath
    Farm configuration (.psd1). Default: ..\config\farms.psd1 next to the toolkit.

.EXAMPLE
    .\RDS-Toolkit.ps1 -ConfigPath C:\Tools\rds-toolkit\config\farms.psd1

.NOTES
    WinForms requires Windows PowerShell 5.1 in STA mode; the script relaunches itself if needed.
    Optional: RemoteDesktop module (session lookup through the broker).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\farms.psd1')
)

$ErrorActionPreference = 'Continue'

# WinForms is reliable only in Windows PowerShell 5.1 with a single-threaded apartment.
$ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($PSVersionTable.PSVersion.Major -ge 6 -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'Restarting in Windows PowerShell 5.1 (STA)...' -ForegroundColor Yellow
    $fullConfig = if (Test-Path -LiteralPath $ConfigPath) { (Resolve-Path -LiteralPath $ConfigPath).Path } else { $ConfigPath }
    Start-Process -FilePath $ps5 -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath), '-ConfigPath', ('"{0}"' -f $fullConfig))
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot '..\lib\Common.ps1')
. (Join-Path $PSScriptRoot 'Toolkit.Functions.ps1')
. (Join-Path $PSScriptRoot 'UserTab.ps1')

try { $Global:Config = Import-RdsConfig -Path $ConfigPath }
catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'RDS Toolkit', 'OK', 'Error')
    return
}
Initialize-ToolkitLog -LogPath $Global:Config.Settings.LogPath

$Global:MainForm = New-Object System.Windows.Forms.Form
$Global:MainForm.Text = 'RDS Toolkit'
$Global:MainForm.Size = New-Object System.Drawing.Size(1070, 780)
$Global:MainForm.MinimumSize = New-Object System.Drawing.Size(900, 600)
$Global:MainForm.StartPosition = 'CenterScreen'

$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = 'Top'
$panelTop.Height = 40
$panelTop.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$Global:MainForm.Controls.Add($panelTop)

$lblMode = New-Label 'CHECK MODE - changes are blocked' 12 11 420
$lblMode.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblMode.ForeColor = [System.Drawing.Color]::DarkGreen
$panelTop.Controls.Add($lblMode)
$btnMode = New-Button 'Switch to ACTION mode' 440 7 210 27
$panelTop.Controls.Add($btnMode)
$panelTop.Controls.Add((New-Label ("$env:USERDOMAIN\$env:USERNAME  |  $env:COMPUTERNAME") 670 11 340))

$btnMode.Add_Click({
        if (-not $Global:ActionMode) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Switch to ACTION mode?`n`nIn this mode the tool can log off sessions, edit the registry and change profile disks.",
                'Change mode', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
            $Global:ActionMode = $true
            $lblMode.Text = 'ACTION MODE - changes are allowed'
            $lblMode.ForeColor = [System.Drawing.Color]::Firebrick
            $btnMode.Text = 'Back to CHECK mode'
            $panelTop.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 235)
            Add-Log 'Mode switched to ACTION' 'MODE'
        }
        else {
            $Global:ActionMode = $false
            $lblMode.Text = 'CHECK MODE - changes are blocked'
            $lblMode.ForeColor = [System.Drawing.Color]::DarkGreen
            $btnMode.Text = 'Switch to ACTION mode'
            $panelTop.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
            Add-Log 'Mode switched to CHECK' 'MODE'
        }
    })

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(8, 46)
$tabs.Size = New-Object System.Drawing.Size(1040, 520)
$tabs.Anchor = 'Top,Left,Right,Bottom'
$tabs.TabPages.Add((New-UserTab))
$Global:MainForm.Controls.Add($tabs)

$lblLog = New-Label 'Operation log:' 10 574 200
$lblLog.Anchor = 'Left,Bottom'
$Global:MainForm.Controls.Add($lblLog)

$Global:LogBox = New-Object System.Windows.Forms.TextBox
$Global:LogBox.Location = New-Object System.Drawing.Point(10, 594)
$Global:LogBox.Size = New-Object System.Drawing.Size(1035, 130)
$Global:LogBox.Multiline = $true
$Global:LogBox.ScrollBars = 'Vertical'
$Global:LogBox.ReadOnly = $true
$Global:LogBox.BackColor = [System.Drawing.Color]::Black
$Global:LogBox.ForeColor = [System.Drawing.Color]::LightGray
$Global:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$Global:LogBox.Anchor = 'Left,Right,Bottom'
$Global:MainForm.Controls.Add($Global:LogBox)

$btnClearLog = New-Button 'Clear' 880 570 80 24
$btnClearLog.Anchor = 'Right,Bottom'
$btnClearLog.Add_Click({ $Global:LogBox.Clear() })
$Global:MainForm.Controls.Add($btnClearLog)
$btnOpenLog = New-Button 'Log file' 965 570 80 24
$btnOpenLog.Anchor = 'Right,Bottom'
$btnOpenLog.Add_Click({ if ($Global:LogFile -and (Test-Path -LiteralPath $Global:LogFile)) { Start-Process notepad.exe $Global:LogFile } })
$Global:MainForm.Controls.Add($btnOpenLog)

Add-Log "RDS Toolkit started on $env:COMPUTERNAME, farms in config: $(@($Global:Config.Farms).Count)"
Add-Log 'Mode: CHECK. Changes are blocked.'
if (-not (Get-Module -ListAvailable -Name RemoteDesktop)) { Add-Log 'RemoteDesktop module not found: sessions are read with "query user"' 'WARN' }

[void]$Global:MainForm.ShowDialog()
