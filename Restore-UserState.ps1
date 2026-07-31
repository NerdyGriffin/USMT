#Requires -Version 5.1
<#
.SYNOPSIS
    Restores USMT user state (loadstate) onto the local machine or a remote one.

.DESCRIPTION
    Config-driven restore pipeline for the USMT toolkit. Behavior comes from
    Config\Settings.psd1 and an optional -JobConfig; any parameter below overrides
    its configured value for this run (parameter > job > global > default).

    Local is the default: with no -TargetComputer the local machine is restored.
    Supplying -TargetComputer activates the remote (PSRemoting) path - loadstate
    still runs ON the target machine, with the store transferred to it per the
    configured TransferMethod (see the transfer abstraction in DESIGN.md).

    loadstate runs with /lac /lae /c and the configured verbosity. Exclude rules
    are not applied at restore - the store already excludes that content at capture.

.PARAMETER TargetComputer
    Machine to restore onto. Omit (or use the local name) to restore locally.

.PARAMETER SourceComputer
    Name of the machine whose store is being restored. Used as the default
    MigStoreName when one is not given.

.PARAMETER MigStoreName
    Store subfolder to restore. Defaults to SourceComputer.

.PARAMETER Users
    'All' (default) restores every profile in the store. An explicit list
    restricts restore to those users via loadstate /ue:*\* + /ui:<user>.

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
    loadstate /v level (override).

.PARAMETER CreateLocalAccounts
    Opt-in: add loadstate /lac to create local accounts that are in the store but
    missing on the target. USMT creates them with a BLANK password, so this is off
    by default. Domain accounts are unaffected (they are never created by /lac).

.PARAMETER EnableLocalAccounts
    Opt-in: add loadstate /lae to enable the accounts created by /lac. Requires
    -CreateLocalAccounts (USMT: /lae is only valid with /lac). Off by default.

.PARAMETER JobConfig
    Path to a <name>.Migration.psd1 job file.

.PARAMETER Credential
    Credential for the remote PSSession. Defaults to the caller's Kerberos token.

.EXAMPLE
    .\Restore-UserState.ps1 -MigStoreName PC-OLD
    Restores the PC-OLD store onto the local machine.

.EXAMPLE
    .\Restore-UserState.ps1 -TargetComputer PC-NEW -MigStoreName PC-OLD `
        -MigStoreNetworkPath \\fileserver\share\USMT\MigStore
    Restores the PC-OLD store onto PC-NEW from a network share.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$TargetComputer,

    [string]$SourceComputer,

    [string]$MigStoreName,

    [string[]]$Users,

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

    [switch]$CreateLocalAccounts,

    [switch]$EnableLocalAccounts,

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

$targetComputer = [string]$config.TargetComputer
$isLocal        = Test-UsmtLocalComputer -ComputerName $targetComputer
$subjectLabel   = if ($isLocal) { $env:COMPUTERNAME } else { $targetComputer }

# Which store to restore: MigStoreName, else the source computer name.
$storeName = [string]$config.MigStoreName
if ([string]::IsNullOrWhiteSpace($storeName)) {
    $storeName = [string]$config.SourceComputer
}
if ([string]::IsNullOrWhiteSpace($storeName)) {
    throw "No store specified. Pass -MigStoreName (or -SourceComputer) to identify which store to restore."
}

# Durable store path (where the store currently lives).
if ($config.MigStoreMode -eq 'Network') {
    if ([string]::IsNullOrWhiteSpace([string]$config.MigStoreNetworkPath)) {
        throw "MigStoreMode is 'Network' but MigStoreNetworkPath is not set. Set it in Config\Settings.psd1 or pass -MigStoreNetworkPath."
    }
    $storeRoot = [string]$config.MigStoreNetworkPath
} else {
    $storeRoot = [string]$config.MigStoreLocalPath
}
$storePath = Join-Path $storeRoot $storeName

# Working path (where loadstate reads; local to the subject machine).
if (-not $isLocal) {
    $workPath = Join-Path (Join-Path $config.RemoteStagingPath 'MigStore') $storeName
} elseif ($config.MigStoreMode -eq 'Network') {
    # Local subject, network store: download to a local staging path first.
    $workPath = Join-Path $config.MigStoreLocalPath $storeName
} else {
    # Local subject, local store: loadstate reads the store in place.
    $workPath = $storePath
}

# Normalize the user selection: 'All' (the default) restores everyone.
$includeUser = @()
$usersValue = $config.Users
if ($usersValue) {
    $usersArr = @($usersValue)
    if (-not ($usersArr.Count -eq 1 -and $usersArr[0] -ieq 'All')) {
        $includeUser = $usersArr
    }
}

# Local-account creation on restore (loadstate /lac /lae) - opt-in, default off,
# because /lac creates missing local accounts with a blank password.
$createLocalAccounts = [bool]$config.CreateLocalAccounts
$enableLocalAccounts = [bool]$config.EnableLocalAccounts
# USMT: /lae is only valid with /lac. Enabling without creating is a config error.
if ($enableLocalAccounts -and -not $createLocalAccounts) {
    throw "EnableLocalAccounts requires CreateLocalAccounts (USMT /lae requires /lac). Enable CreateLocalAccounts as well, or clear EnableLocalAccounts."
}
#endregion

Start-UsmtLog -ScriptName 'Restore-UserState' -LogRoot $config.LogRoot -ComputerName $subjectLabel | Out-Null

try {
    Write-Log "Restore starting for '$subjectLabel'." 'INFO'
    Write-Log "  Store        : $storePath" 'INFO'
    Write-Log "  Working path : $workPath" 'INFO'
    Write-Log "  Mode         : $($config.MigStoreMode) (local subject: $isLocal)" 'INFO'
    if ($includeUser.Count -gt 0) {
        Write-Log "  Users        : $($includeUser -join ', ')" 'INFO'
    } else {
        Write-Log "  Users        : All profiles in store" 'INFO'
    }
    Write-Log "  Local accts  : create=$createLocalAccounts enable=$enableLocalAccounts (/lac /lae opt-in)" 'INFO'

    # Fail fast on a missing store, but only when the caller can actually see it:
    # if the store root is reachable yet the named subfolder is absent, that is a
    # real "wrong store" error. If the root itself is unreachable from the caller
    # (e.g. a UNC only the remote can reach via its second hop), skip the check and
    # let the transfer step surface any genuine problem.
    $storeParent = Split-Path $storePath -Parent
    if ((Test-Path -LiteralPath $storeParent -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath $storePath -ErrorAction SilentlyContinue)) {
        throw "Store not found: '$storePath'. Run Backup-UserState.ps1 first (or check MigStoreName)."
    }

    if (-not $PSCmdlet.ShouldProcess($subjectLabel, "Run USMT LoadState from store '$storeName'")) {
        return
    }

    $session = New-UsmtSession -ComputerName $targetComputer -Credential $Credential
    try {
        if ($session) {
            Write-Log "Connected to '$targetComputer' via PSRemoting." 'INFO'
        }

        # Stage binaries on the subject machine (no exclude XMLs at restore).
        $staged = Copy-UsmtBinary -Session $session -BinPath $config.UsmtBinPath `
            -StagingPath $config.RemoteStagingPath

        # Bring the store to the working path (skipped when work == store).
        if ($session -or ($workPath -ne $storePath)) {
            Write-Log "Transferring store from $storePath ..." 'INFO'
            $rc = Copy-MigStore -Direction 'Download' -Session $session -ComputerName $targetComputer `
                -WorkPath $workPath -StorePath $storePath -TransferMethod $config.TransferMethod
            if (-not (Test-UsmtRobocopyOk -ExitCode $rc)) {
                throw "robocopy failed (exit $rc) copying the store from '$storePath'."
            }
            Write-Log "Store transfer complete." 'SUCCESS'
        }

        # Restore.
        $loadExit = Invoke-UsmtLoadState -Session $session -BinPath $staged.BinPath `
            -StorePath $workPath -Verbosity $config.Verbosity -IncludeUser $includeUser `
            -CreateLocalAccount $createLocalAccounts -EnableLocalAccount $enableLocalAccounts

        # Classify the loadstate result. With /c, code 3 (USMT_WOULD_HAVE_FAILED)
        # means the restore completed but some non-fatal errors were skipped - a
        # usable restore, not a failure. Only other non-zero codes are fatal.
        $loadDisposition = Get-UsmtExitDisposition -ExitCode $loadExit
        switch ($loadDisposition) {
            'Success' {
                Write-Log "loadstate completed successfully." 'SUCCESS'
            }
            'CompletedWithSkips' {
                Write-Log "loadstate returned exit code 3: the restore completed, but /c skipped one or more non-fatal errors (e.g. locked or ACL-protected files). Review load_all.log in $storePath to see what was skipped." 'WARN'
            }
            default {
                Write-Log "loadstate returned exit code $loadExit; pushing logs for diagnosis, then failing." 'ERROR'
            }
        }

        # Push load logs back to the durable store for record-keeping (non-fatal),
        # done even on failure so the logs are available for diagnosis.
        if ($session -or ($workPath -ne $storePath)) {
            Write-Log "Pushing load logs back to $storePath ..." 'INFO'
            $logRc = Copy-MigStore -Direction 'Upload' -Session $session -ComputerName $targetComputer `
                -WorkPath $workPath -StorePath $storePath -TransferMethod $config.TransferMethod `
                -File @('load_all.log', 'prog_load_all.log')
            if (-not (Test-UsmtRobocopyOk -ExitCode $logRc)) {
                Write-Log "robocopy failed (exit $logRc) pushing load logs; the restore itself is unaffected." 'WARN'
            }
        }

        # Only a genuine failure is fatal; codes 0 and 3 both leave a usable restore.
        if ($loadDisposition -eq 'Failure') {
            throw "loadstate returned exit code $loadExit on '$subjectLabel'; review load_all.log in $storePath."
        }

        Write-Log "Restore complete. Reboot '$subjectLabel' for all settings to take effect." 'SUCCESS'
    } finally {
        if ($session) {
            Remove-PSSession $session
        }
    }
} finally {
    Stop-UsmtLog
}

# Reached only on the success path (a thrown error propagates out before here and
# terminates the script non-zero). Set a clean exit code so a benign robocopy
# result (e.g. exit 1 = "files copied") left in $LASTEXITCODE cannot be mistaken
# for failure by an automated caller.
exit 0
