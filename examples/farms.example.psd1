# RDS farm configuration for rds-toolkit.
# Copy to config\farms.psd1 (ignored by git) or pass any path with -ConfigPath.
@{
    # Appended to short host names when connecting over WinRM. Leave empty if short names resolve.
    DnsSuffix = 'contoso.local'

    # NetBIOS domain used to resolve logon names to SIDs.
    Domain    = 'CONTOSO'

    Farms     = @(
        @{
            Name         = 'Office'                       # any label, used in -Farm parameters
            ProfileType  = 'UPD'                          # UPD (User Profile Disks) or FSLogix
            Broker       = 'rds-cb-01.contoso.local'      # optional: RD Connection Broker
            Collection   = 'Office'                       # optional: collection name on the broker
            SessionHosts = @('rds-sh-01', 'rds-sh-02')
            ProfileShare = '\\fs-01\D$\UPD\Office'        # where UVHD-<SID>.vhdx files live
            StorageHost  = 'fs-01'                        # optional: file server (default: taken from ProfileShare)
            MaxProfileGB = 10                             # optional: shown next to disk size
        }
        @{
            Name         = 'Accounting'
            ProfileType  = 'FSLogix'
            Broker       = 'rds-cb-01.contoso.local'
            Collection   = 'Accounting'
            SessionHosts = @('rds-sh-11', 'rds-sh-12')
            ProfileShare = '\\fs-02\P$\FSLogix'           # <SID>_<user>\Profile_<user>.vhdx
            MaxProfileGB = 20
        }
    )

    Settings  = @{
        LogPath         = 'C:\ProgramData\rds-toolkit\logs'
        ResizeDefaultGB = 20      # GUI: default new size when expanding a profile disk
        ResizeMaxGB     = 50      # GUI: upper limit for expansion
    }
}
