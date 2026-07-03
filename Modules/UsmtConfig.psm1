#Requires -Version 5.1
<#
.SYNOPSIS
    Configuration loading and resolution for the USMT toolkit.

.DESCRIPTION
    Loads the two tiers of PSD1 configuration (global Settings.psd1 and an
    optional per-job <name>.Migration.psd1) and resolves every setting using the
    precedence defined in DESIGN.md:

        command-line parameter  >  job config  >  global config  >  built-in default

    All defaults are computed relative to the repository root so the toolkit is
    self-contained: a fresh clone works with no config file at all (everything
    falls back to sensible in-repo defaults), and any single value can be
    overridden per-run from the command line.

    PSD1 (not JSON) is used deliberately: it is idiomatic for a pure-PowerShell
    tool, supports comments, and parses natively on Windows PowerShell 5.1 via
    Import-PowerShellDataFile.
#>

Set-StrictMode -Version Latest

#region Repository root

function Get-UsmtRepoRoot {
    <#
    .SYNOPSIS
        Returns the repository root (the parent of the Modules directory).
    #>
    [CmdletBinding()]
    param()

    # This module lives in <repo>\Modules; the repo root is one level up.
    return (Split-Path -Path $PSScriptRoot -Parent)
}

#endregion

#region Config file loading

function Import-UsmtConfigFile {
    <#
    .SYNOPSIS
        Imports a PSD1 config file and returns it as a hashtable.

    .DESCRIPTION
        Thin wrapper over Import-PowerShellDataFile that normalizes the result
        to an ordinary hashtable and raises a clear error when the file is
        missing or does not parse.

    .PARAMETER Path
        Path to the .psd1 file.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path
    } catch {
        throw "Failed to parse config file '$Path': $($_.Exception.Message)"
    }

    if ($null -eq $data) {
        return @{}
    }

    # Import-PowerShellDataFile returns a Hashtable already, but copy into a
    # plain hashtable so callers can mutate it freely.
    $result = @{}
    foreach ($key in $data.Keys) {
        $result[$key] = $data[$key]
    }
    return $result
}

#endregion

#region Defaults

function Get-UsmtDefaultSettings {
    <#
    .SYNOPSIS
        Returns the built-in default configuration hashtable.

    .PARAMETER RepoRoot
        Repository root used to compute path defaults. Defaults to the value of
        Get-UsmtRepoRoot.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [string]$RepoRoot
    )

    if (-not $RepoRoot) {
        $RepoRoot = Get-UsmtRepoRoot
    }

    return @{
        # --- Global (Settings.psd1) ---
        MigStoreMode         = 'Local'
        MigStoreLocalPath    = (Join-Path $RepoRoot 'MigStore')
        MigStoreNetworkPath  = ''
        UsmtBinPath          = (Join-Path $RepoRoot 'amd64')
        LogRoot              = (Join-Path $RepoRoot 'Logs')
        RemoteStagingPath    = 'C:\USMT'
        TransferMethod       = 'Auto'
        DefaultExcludeRules  = @()
        Verbosity            = 13

        # --- Per-job (<name>.Migration.psd1) ---
        SourceComputer       = ''
        TargetComputer       = ''
        Users                = 'All'
        OldUser              = ''
        NewUser              = ''
        ExcludeRules         = @()
        SkipStaleProfileDays = 0
        MigStoreName         = ''
    }
}

#endregion

#region Resolution

function Resolve-UsmtSetting {
    <#
    .SYNOPSIS
        Resolves a single setting using param > job > global > default precedence.

    .PARAMETER Key
        The setting name to resolve.

    .PARAMETER Parameters
        Explicitly-bound command-line parameters (typically $PSBoundParameters).
        Presence of the key here always wins.

    .PARAMETER Job
        The per-job config hashtable (may be empty).

    .PARAMETER Settings
        The global settings hashtable (may be empty).

    .PARAMETER Default
        The built-in default value used when no tier supplies the key.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Key,

        [hashtable]$Parameters = @{},

        [hashtable]$Job = @{},

        [hashtable]$Settings = @{},

        $Default
    )

    # A bound command-line parameter always wins, even if it is an empty string
    # (an explicit override is an explicit override).
    if ($Parameters.ContainsKey($Key)) {
        return $Parameters[$Key]
    }

    # Job and global tiers win only when they actually supply a non-null value.
    if ($Job.ContainsKey($Key) -and $null -ne $Job[$Key]) {
        return $Job[$Key]
    }

    if ($Settings.ContainsKey($Key) -and $null -ne $Settings[$Key]) {
        return $Settings[$Key]
    }

    return $Default
}

function Resolve-UsmtConfiguration {
    <#
    .SYNOPSIS
        Produces the fully-resolved configuration hashtable for a toolkit run.

    .DESCRIPTION
        Loads the global Settings.psd1 (if present) and an optional job config,
        then resolves every known key with param > job > global > default
        precedence. The returned hashtable also includes:
          - RepoRoot            : the repository root
          - EffectiveExcludeRules : DefaultExcludeRules plus job/param ExcludeRules,
                                    de-duplicated (job rules extend the defaults)

    .PARAMETER Parameters
        Explicitly-bound command-line parameters (pass $PSBoundParameters from the
        calling script). Only keys that match known settings are considered.

    .PARAMETER JobConfigPath
        Optional path to a <name>.Migration.psd1 job file.

    .PARAMETER SettingsPath
        Optional override for the global settings file. Defaults to
        <repo>\Config\Settings.psd1.

    .PARAMETER RepoRoot
        Optional override for the repository root (used mainly by tests).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [hashtable]$Parameters = @{},

        [string]$JobConfigPath,

        [string]$SettingsPath,

        [string]$RepoRoot
    )

    if (-not $RepoRoot) {
        $RepoRoot = Get-UsmtRepoRoot
    }

    # --- Load global settings ---
    if (-not $SettingsPath) {
        $SettingsPath = Join-Path (Join-Path $RepoRoot 'Config') 'Settings.psd1'
    }
    $settings = @{}
    if (Test-Path -LiteralPath $SettingsPath) {
        $settings = Import-UsmtConfigFile -Path $SettingsPath
    }

    # --- Load job config ---
    $job = @{}
    if ($JobConfigPath) {
        # A caller-supplied job path that does not exist is a hard error rather
        # than a silent fallback to defaults.
        $job = Import-UsmtConfigFile -Path $JobConfigPath
    }

    # --- Resolve every known key ---
    $defaults = Get-UsmtDefaultSettings -RepoRoot $RepoRoot
    $resolved = @{}
    foreach ($key in $defaults.Keys) {
        $resolved[$key] = Resolve-UsmtSetting -Key $key -Parameters $Parameters `
            -Job $job -Settings $settings -Default $defaults[$key]
    }

    $resolved['RepoRoot'] = $RepoRoot

    # --- Effective exclude rules: defaults + job/param rules, de-duplicated ---
    # Job-level ExcludeRules extend (do not replace) the global DefaultExcludeRules.
    $combined = @()
    if ($resolved['DefaultExcludeRules']) {
        $combined += $resolved['DefaultExcludeRules']
    }
    if ($resolved['ExcludeRules']) {
        $combined += $resolved['ExcludeRules']
    }
    $effective = @()
    foreach ($rule in $combined) {
        if ($rule -and ($effective -notcontains $rule)) {
            $effective += $rule
        }
    }
    $resolved['EffectiveExcludeRules'] = $effective

    return $resolved
}

#endregion

Export-ModuleMember -Function `
    Get-UsmtRepoRoot, `
    Import-UsmtConfigFile, `
    Get-UsmtDefaultSettings, `
    Resolve-UsmtSetting, `
    Resolve-UsmtConfiguration
