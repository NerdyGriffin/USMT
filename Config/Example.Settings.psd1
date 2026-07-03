<#
    Example.Settings.psd1 - global configuration template for the USMT toolkit.

    Copy this file to Config\Settings.psd1 (Setup.ps1 does this for you) and edit
    the values. Config\Settings.psd1 is gitignored: real environment identity
    (share paths, hostnames) lives only there, never in tracked files.

    Every value here is optional. A blank/absent key falls back to the built-in
    default shown in the comment beside it, and any value can be overridden per-run
    by the matching command-line parameter on Backup-UserState.ps1 /
    Restore-UserState.ps1.

    Resolution order: command-line parameter > job config > this file > default.
#>
@{
    # Where migration stores live: 'Local' (in-repo MigStore) or 'Network' (UNC share).
    # Default: 'Local'
    MigStoreMode        = 'Local'

    # Local store root. Default: <repo>\MigStore
    MigStoreLocalPath   = ''

    # UNC store root, e.g. '\\fileserver\share\USMT\MigStore'. Blank = Local only.
    # Required when MigStoreMode = 'Network'.
    MigStoreNetworkPath = ''

    # Where the amd64 USMT binaries live. Default: <repo>\amd64 (populated by Setup.ps1)
    UsmtBinPath         = ''

    # Transcript / log directory. Default: <repo>\Logs
    LogRoot             = ''

    # Working directory created on remote machines for staging binaries and the
    # store. Default: 'C:\USMT'
    RemoteStagingPath   = 'C:\USMT'

    # Store transfer strategy for remote runs:
    #   'Auto'            - probe AdminShare, then SessionPushPull, then fail (default)
    #   'AdminShare'      - caller-side robocopy over the remote's C$ admin share
    #   'SessionPushPull' - robocopy run inside the remote session (needs the
    #                       remote's second hop to the file share to succeed)
    # See the double-hop guidance in README.md.
    TransferMethod      = 'Auto'

    # Exclude-rule XML file names (from ExcludeRules\) always applied at capture.
    # These extend, and are extended by, any per-job ExcludeRules.
    # Example: @('ExcludeBulkData.xml', 'ExcludeDefender.xml')
    DefaultExcludeRules = @()

    # scanstate/loadstate /v verbosity level (0-13). Default: 13 (most detailed).
    Verbosity           = 13
}
