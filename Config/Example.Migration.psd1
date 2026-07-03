<#
    Example.Migration.psd1 - per-job configuration template for the USMT toolkit.

    A job file bundles the settings for one migration so it can be re-run and
    version-referenced instead of retyped as parameters:

        .\Backup-UserState.ps1  -JobConfig .\Config\pc-old.Migration.psd1
        .\Restore-UserState.ps1 -JobConfig .\Config\pc-old.Migration.psd1

    Copy this file to Config\<name>.Migration.psd1 (gitignored) and edit. Every
    key is optional - anything omitted here can still be supplied as a command-line
    parameter, and a command-line parameter always overrides the job file.

    NEVER put credentials in a config file. Pass -Credential at runtime instead;
    the default is the caller's own Kerberos token.
#>
@{
    # Machine to capture FROM (Backup). Absent/blank = the local machine.
    SourceComputer       = ''

    # Machine to restore ONTO (Restore). Absent/blank = the local machine.
    TargetComputer       = ''

    # Which profiles to migrate:
    #   'All'                       - every local profile (default)
    #   @('CONTOSO\jsmith', ...)    - explicit list -> scanstate /ui + /ue:*\*
    Users                = 'All'

    # Per-job exclude-rule XML names (from ExcludeRules\). These EXTEND the global
    # DefaultExcludeRules; they do not replace them.
    # Example: @('ExcludeBulkData.xml')
    ExcludeRules         = @()

    # Opt-in staleness filter: skip profiles not logged into within N days
    # (scanstate /uel:N). Absent or 0 = capture ALL users, including dormant ones.
    SkipStaleProfileDays = 0

    # Store subfolder name under the store root. Default: the source computer name
    # (Backup) or whichever store you are restoring (Restore).
    MigStoreName         = ''

    # --- v2 (same-machine user rename via /mu) - not yet implemented ---
    # OldUser = 'CONTOSO\olduser'
    # NewUser = 'CONTOSO\newuser'
}
