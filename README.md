# rds-toolkit

PowerShell tools for Remote Desktop Services farms with **User Profile Disks (UPD)** or **FSLogix**:
profile disk maintenance, cache cleanup, broken profile repair, disk and memory diagnostics, and a
WinForms tool for helpdesk that shows everything about one user's profile in one window.

> **🇷🇺 Кратко.** Инструменты для RDS-ферм с UPD или FSLogix: инвентаризация и сжатие VHDX-дисков профилей,
> очистка кешей (1С, браузеры, Acrobat) внутри диска пользователя, ремонт сломанных профилей (TEMP, SID.bak),
> очистка системного диска сессионных хостов, диагностика места и памяти, плюс GUI для первой линии
> с режимами «ПРОВЕРКА/ДЕЙСТВИЕ». Всё, что меняет систему, по умолчанию работает как сухой прогон.

## Contents

| Script | What it does | Changes anything? |
|---|---|---|
| [gui/RDS-Toolkit.ps1](gui/RDS-Toolkit.ps1) | One window per user: sessions, profile disks, ProfileList on hosts; log off, repair, analyze, clear, compact, expand | Only in ACTION mode, with confirmation |
| [profile-disks/Export-ProfileDiskReport.ps1](profile-disks/Export-ProfileDiskReport.ps1) | Inventory of all profile disks in a farm joined with AD (owner, account state, last logon, size, idle days, open now) to XLSX/CSV | No |
| [profile-disks/Inspect-ProfileDisk.ps1](profile-disks/Inspect-ProfileDisk.ps1) | What takes space inside one disk: caches vs user data, largest files, space returned by compact | No (read-only mount) |
| [profile-disks/Compact-ProfileDisk.ps1](profile-disks/Compact-ProfileDisk.ps1) | Compacts idle VHDX files on the file server, optional re-trim | Dry run unless `-Execute` |
| [profile-disks/Clear-ProfileDiskCache.ps1](profile-disks/Clear-ProfileDiskCache.ps1) | Clears 1C:Enterprise / browser / Adobe / Office / temp caches inside one user's disk, optionally logging the user off first | Dry run unless `-Execute` |
| [session-host/Clear-SessionHostDisk.ps1](session-host/Clear-SessionHostDisk.ps1) | Frees the system drive of a session host (installer caches, dumps, logs, temp), writes a status line for monitoring | Dry run unless `-Execute` |
| [session-host/Repair-UserProfile.ps1](session-host/Repair-UserProfile.ps1) | Classifies `C:\Users`, quarantines leftover profiles, repairs ProfileList (SID.bak pairs) with backup and rollback | Dry run unless `-Execute` |
| [session-host/Get-DiskUsageReport.ps1](session-host/Get-DiskUsageReport.ps1) | One-pass analysis of the system drive with cleanup candidates grouped by risk (SAFE / CAUTION / WINDOW) | No |
| [session-host/Get-MemoryPressureReport.ps1](session-host/Get-MemoryPressureReport.ps1) | Memory by session and process, disconnected sessions, time-limit policies, resource events; `-Watch` mode to CSV | No |

## Requirements

- Windows Server 2016+ / Windows PowerShell 5.1 (the GUI relaunches itself in 5.1 STA if started from PowerShell 7).
- Admin rights on session hosts and the file server; WinRM between the admin host and them.
- Disk images are attached with `Mount-DiskImage`, so **the Hyper-V role or module is not required**.
- Optional: `RemoteDesktop` module (session lookup through the Connection Broker in the GUI).
- No ActiveDirectory module needed: SIDs and account data are read over LDAP.

## Setup

Copy the example configuration and describe your farms:

```powershell
Copy-Item .\examples\farms.example.psd1 .\config\farms.psd1
notepad .\config\farms.psd1
```

```powershell
@{
    DnsSuffix = 'contoso.local'
    Domain    = 'CONTOSO'
    Farms     = @(
        @{ Name = 'Office'; ProfileType = 'UPD'; SessionHosts = @('rds-sh-01', 'rds-sh-02'); ProfileShare = '\\fs-01\D$\UPD\Office' }
        @{ Name = 'Accounting'; ProfileType = 'FSLogix'; SessionHosts = @('rds-sh-11'); ProfileShare = '\\fs-02\P$\FSLogix' }
    )
}
```

`config\` is ignored by git. Session-host scripts do not need the configuration: they run on the host itself.

## Usage

```powershell
# helpdesk GUI
.\gui\RDS-Toolkit.ps1 -ConfigPath .\config\farms.psd1

# who owns which profile disk, which accounts are disabled, what is idle
.\profile-disks\Export-ProfileDiskReport.ps1 -ConfigPath .\config\farms.psd1 -Farm Office

# 1C client misbehaves: dry run first, then log the user off and clear the cache
.\profile-disks\Clear-ProfileDiskCache.ps1 -ConfigPath .\config\farms.psd1 -Farm Accounting -UserName jdoe
.\profile-disks\Clear-ProfileDiskCache.ps1 -ConfigPath .\config\farms.psd1 -Farm Accounting -UserName jdoe -LogoffUser -Execute

# return empty space from idle disks to the file server (maintenance window)
.\profile-disks\Compact-ProfileDisk.ps1 -ConfigPath .\config\farms.psd1 -Farm Office -MaxFiles 20 -WithRetrim -Execute

# on a session host: nightly cleanup task and a profile health check
.\session-host\Clear-SessionHostDisk.ps1 -Execute -IncludeProfiles
.\session-host\Repair-UserProfile.ps1
```

Every script has comment-based help: `Get-Help .\profile-disks\Compact-ProfileDisk.ps1 -Full`.

### Example output

`Compact-ProfileDisk.ps1` dry run (names are illustrative):

```text
==========================================================================================
  COMPACT IDLE PROFILE DISKS
==========================================================================================
Server   : fs-01
Folder   : D:\UPD\Office
Mode     : DRY RUN
Filter   : > 1 GB, idle >= 7 days, max 5 disk(s)

  User                              GB Modified     Idle  State
  CONTOSO\jdoe                    9.84 2026-09-14    24d  can be compacted
  CONTOSO\asmith                  7.12 2026-09-28    10d  can be compacted
  CONTOSO\bwhite                  6.40 2026-09-30     8d  open from 10.0.0.21

  Matching filter : 3
  Selected        : 2, total 16.96 GB
```

`Clear-SessionHostDisk.ps1` writes a line that a monitoring agent can read
(for example a Zabbix `vfs.file.contents` item with a regex preprocessing step):

```text
time=2026-10-08T03:00:12 status=OK free_gb=41.27 freed_mb=3870 targets=17
```

## Safety model

- **Dry run by default.** Scripts that change anything need `-Execute`; without it they show exactly what would happen.
- **CHECK / ACTION modes in the GUI.** The tool starts in CHECK mode where every change is blocked and logged;
  ACTION mode is switched on explicitly and destructive actions ask for confirmation.
- **Read-only where possible.** Inspection mounts disks read-only; every mount is paired with a dismount in
  `finally` (three attempts, result reported).
- **Nothing is touched while in use.** Disks open over SMB, users with sessions or loaded registry hives are skipped.
- **Reversible profile repair.** Leftover profile folders are moved to a quarantine folder, not deleted.
  ProfileList is exported to a `.reg` file before any change, the restored path is verified and the export is
  imported back if verification fails.
- **Protected paths.** Page file, WinSxS, `Windows\Installer`, registry hives and application program folders
  are excluded from cleanup.

## How it works

- **Profile disk layout.** UPD stores `UVHD-<SID>.vhdx` in the share root with the profile at the volume root.
  FSLogix stores `<SID>_<user>\Profile_<user>.vhdx` (or `<user>_<SID>` with FlipFlop naming) with the profile under `\Profile`.
  `lib\Common.ps1` handles both.
- **Compaction without Hyper-V.** `diskpart`: `attach vdisk readonly`, `compact vdisk`, `detach vdisk`. With re-trim the
  volume is first mounted and `Optimize-Volume -ReTrim` releases blocks freed inside NTFS, which makes compaction much more effective.
- **Remote execution.** Disk operations run on the file server through WinRM with local paths, so data does not travel
  over SMB twice. Helper functions are shipped into the remote session as source text (`Get-FunctionDefinition`).
- **XLSX without Excel.** `lib\Xlsx.ps1` writes Office Open XML parts into a ZIP container directly:
  frozen header, auto-filter, typed date and number cells, highlighted rows.

## Project layout

```text
gui/             RDS-Toolkit.ps1 (entry point), Toolkit.Functions.ps1, UserTab.ps1
profile-disks/   scripts that work with VHDX files on the file server
session-host/    scripts that run on an RDS session host
lib/             Common.ps1 (config, identity, sessions, disk mount, reports), Xlsx.ps1
examples/        farms.example.psd1
```

## Limitations

- Windows only; written for Windows Server 2016+ with UPD and FSLogix profile containers (ODFC containers are not handled).
- `query user` is used when the broker is not available: it lists sessions, not RemoteApp details.
- Compaction reads and rewrites whole files: plan it for a maintenance window.
- Cache paths in the catalog cover common applications; extend `$script:ProfileFolderCatalog` in `lib\Common.ps1` for your own.

## License

[MIT](LICENSE)
