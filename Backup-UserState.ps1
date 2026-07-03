#Requires -Version 5.1
<#
.SYNOPSIS
    Captures USMT user state (scanstate) from the local machine or a remote one.

.DESCRIPTION
    Config-driven backup pipeline for the USMT toolkit. Behavior comes from
    Config\Settings.psd1 and an optional -JobConfig; any parameter below overrides
    its configured value for this run (parameter > job > global > default).

    Local is the default: with no -SourceComputer the local machine is captured.
    Supplying -SourceComputer activates the remote (PSRemoting) path - scanstate
    still runs ON the source machine, and the store is transferred per the
    configured TransferMethod (see the transfer abstraction in DESIGN.md).

    scanstate always runs with /o /vsc /localonly /c and the configured verbosity.
    Exclude-rule XMLs (global DefaultExcludeRules plus any job/parameter
    ExcludeRules) are validated and applied at capture.

.PARAMETER SourceComputer
    Machine to capture from. Omit (or use the local name) to capture locally.

.PARAMETER Users
    'All' (default) captures every local profile. An explicit list
    (e.g. 'CONTOSO\jsmith','CONTOSO\ajones') restricts capture to those users
    via scanstate /ue:*\* + /ui:<user>.

.PARAMETER ExcludeRules
    Exclude-rule XML file names (from ExcludeRules\) to apply in addition to the
    global DefaultExcludeRules.

.PARAMETER SkipStaleProfileDays
    Opt-in: skip profiles not logged into within N days (scanstate /uel:N).
    0 (default) captures all users, including dormant ones.

.PARAMETER MigStoreName
    Store subfolder name. Defaults to the source computer name.

.PARAMETER MigStoreMode
    'Local' or 'Network' - overrides the configured store mode.

.PARAMETER MigStoreLocalPath
    Local store root override.

.PARAMETER MigStoreNetworkPath
    UNC store root override (required when the effective mode is Network).

.PARAMETER UsmtBinPath
    Directory holding the amd64 USMT binaries (override).

.PARAMETER LogRoot
    Transcript/log directory (override).

.PARAMETER RemoteStagingPath
    Working directory created on the remote machine (override).

.PARAMETER TransferMethod
    'Auto', 'AdminShare', or 'SessionPushPull' (override) for remote store copies.

.PARAMETER Verbosity
    scanstate /v level (override).

.PARAMETER JobConfig
    Path to a <name>.Migration.psd1 job file.

.PARAMETER Credential
    Credential for the remote PSSession. Defaults to the caller's Kerberos token.

.EXAMPLE
    .\Backup-UserState.ps1
    Captures all local profiles into the configured store.

.EXAMPLE
    .\Backup-UserState.ps1 -SourceComputer PC-OLD
    Captures all profiles on PC-OLD via PSRemoting.

.EXAMPLE
    .\Backup-UserState.ps1 -JobConfig .\Config\pc-old.Migration.psd1
    Runs a saved job definition.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$SourceComputer,

    [string[]]$Users,

    [string[]]$ExcludeRules,

    [int]$SkipStaleProfileDays,

    [string]$MigStoreName,

    [ValidateSet('Local', 'Network')]
    [string]$MigStoreMode,

    [string]$MigStoreLocalPath,

    [string]$MigStoreNetworkPath,

    [string]$UsmtBinPath,

    [string]$LogRoot,

    [string]$RemoteStagingPath,

    [ValidateSet('Auto', 'AdminShare', 'SessionPushPull')]
    [string]$TransferMethod,

    [int]$Verbosity,

    [string]$JobConfig,

    [System.Management.Automation.PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Load modules
$moduleDir = Join-Path $PSScriptRoot 'Modules'
Import-Module (Join-Path $moduleDir 'UsmtConfig.psm1')  -Force
Import-Module (Join-Path $moduleDir 'UsmtLogging.psm1') -Force
Import-Module (Join-Path $moduleDir 'UsmtCore.psm1')    -Force
#endregion

#region Resolve configuration
$resolveParams = @{ Parameters = $PSBoundParameters }
if ($PSBoundParameters.ContainsKey('JobConfig') -and $JobConfig) {
    $resolveParams['JobConfigPath'] = $JobConfig
}
$config = Resolve-UsmtConfiguration @resolveParams

$sourceComputer = [string]$config.SourceComputer
$isLocal        = Test-UsmtLocalComputer -ComputerName $sourceComputer
$subjectLabel   = if ($isLocal) { $env:COMPUTERNAME } else { $sourceComputer }

# Store subfolder name defaults to the subject machine name.
$storeName = [string]$config.MigStoreName
if ([string]::IsNullOrWhiteSpace($storeName)) {
    $storeName = $subjectLabel
}

# Durable store path (where the store ultimately lives).
if ($config.MigStoreMode -eq 'Network') {
    if ([string]::IsNullOrWhiteSpace([string]$config.MigStoreNetworkPath)) {
        throw "MigStoreMode is 'Network' but MigStoreNetworkPath is not set. Set it in Config\Settings.psd1 or pass -MigStoreNetworkPath."
    }
    $storeRoot = [string]$config.MigStoreNetworkPath
} else {
    $storeRoot = [string]$config.MigStoreLocalPath
}
$storePath = Join-Path $storeRoot $storeName

# Working path (where scanstate actually writes; local to the subject machine).
if (-not $isLocal) {
    $workPath = Join-Path (Join-Path $config.RemoteStagingPath 'MigStore') $storeName
} elseif ($config.MigStoreMode -eq 'Network') {
    # Local subject, network store: stage locally, then upload.
    $workPath = Join-Path $config.MigStoreLocalPath $storeName
} else {
    # Local subject, local store: scanstate writes straight to the store.
    $workPath = $storePath
}

# Resolve and validate exclude-rule XMLs (fail fast on a bad rule file).
$excludeXmlPaths = @()
foreach ($ruleName in @($config.EffectiveExcludeRules)) {
    if (-not $ruleName) { continue }
    $rulePath = Join-Path (Join-Path $config.RepoRoot 'ExcludeRules') $ruleName
    Test-UsmtXmlFile -Path $rulePath | Out-Null
    $excludeXmlPaths += $rulePath
}

# Normalize the user selection: 'All' (the default) means capture everyone.
$includeUser = @()
$usersValue = $config.Users
if ($usersValue) {
    $usersArr = @($usersValue)
    if (-not ($usersArr.Count -eq 1 -and $usersArr[0] -ieq 'All')) {
        $includeUser = $usersArr
    }
}
#endregion

Start-UsmtLog -ScriptName 'Backup-UserState' -LogRoot $config.LogRoot -ComputerName $subjectLabel | Out-Null

try {
    Write-Log "Backup starting for '$subjectLabel'." 'INFO'
    Write-Log "  Store        : $storePath" 'INFO'
    Write-Log "  Working path : $workPath" 'INFO'
    Write-Log "  Mode         : $($config.MigStoreMode) (local subject: $isLocal)" 'INFO'
    if ($includeUser.Count -gt 0) {
        Write-Log "  Users        : $($includeUser -join ', ')" 'INFO'
    } else {
        Write-Log "  Users        : All local profiles" 'INFO'
    }
    if ($excludeXmlPaths.Count -gt 0) {
        Write-Log "  ExcludeRules : $((@($config.EffectiveExcludeRules)) -join ', ')" 'INFO'
    }

    if (-not $PSCmdlet.ShouldProcess($subjectLabel, 'Run USMT ScanState and store user state')) {
        return
    }

    # Ensure the durable store root exists (single-hop, caller identity).
    if (-not (Test-Path -LiteralPath $storeRoot)) {
        New-Item -Path $storeRoot -ItemType Directory -Force | Out-Null
    }

    $session = New-UsmtSession -ComputerName $sourceComputer -Credential $Credential
    try {
        if ($session) {
            Write-Log "Connected to '$sourceComputer' via PSRemoting." 'INFO'
        }

        # Stage binaries + exclude XMLs on the subject machine.
        $staged = Copy-UsmtBinary -Session $session -BinPath $config.UsmtBinPath `
            -StagingPath $config.RemoteStagingPath -ExcludeXmlPath $excludeXmlPaths

        # Capture.
        $scanExit = Invoke-UsmtScanState -Session $session -BinPath $staged.BinPath `
            -StorePath $workPath -ExcludeXmlPath $staged.ExcludeXmlPath `
            -Verbosity $config.Verbosity -IncludeUser $includeUser `
            -SkipStaleProfileDays $config.SkipStaleProfileDays

        if ($scanExit -ne 0) {
            Write-Log "scanstate exited with code $scanExit; review scan_all.log beside the store." 'WARN'
        } else {
            Write-Log "scanstate completed successfully." 'SUCCESS'
        }

        # Transfer the store to its durable location (skipped when work == store).
        if ($session -or ($workPath -ne $storePath)) {
            Write-Log "Transferring store to $storePath ..." 'INFO'
            $rc = Copy-MigStore -Direction 'Upload' -Session $session -ComputerName $sourceComputer `
                -WorkPath $workPath -StorePath $storePath -TransferMethod $config.TransferMethod
            if (-not (Test-UsmtRobocopyOk -ExitCode $rc)) {
                throw "robocopy failed (exit $rc) copying the store to '$storePath'."
            }
            Write-Log "Store transfer complete." 'SUCCESS'
        }

        Write-Log "Backup complete. Store: $storePath" 'SUCCESS'
    } finally {
        if ($session) {
            Remove-PSSession $session
        }
    }
} finally {
    Stop-UsmtLog
}
