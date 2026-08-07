#Requires -Version 5.1
<#
.SYNOPSIS
    Restores USMT user state (captured from GC0) onto WIN-GC4.

.DESCRIPTION
    Remotely invokes USMT LoadState on WIN-GC4 via PowerShell Remoting, restoring
    the migration store previously captured by ScanState_GC0.ps1. All profiles in
    the store are restored in a single LoadState pass. No user or domain remapping
    is performed (/mu, /md) - source and target accounts are the same domain users,
    so USMT restores each profile back onto its matching domain account by SID.

    The large store transfer is done with robocopy run ON WIN-GC4 (inside the
    PSSession), not Copy-Item -ToSession / -FromSession (which trips a PowerShell
    bug - "the property 'Length' cannot be found" - on large store trees) and not a
    caller-side \\WIN-GC4\C$ copy (WIN-GC4 blocks inbound SMB, so its C$ share is
    unreachable from the caller - same as the source machine). WIN-GC4 reaches the
    file share via the RBCD delegation configured for it. The script:
      1. Opens a persistent PSSession to WIN-GC4
      2. Pushes USMT binaries from the admin workstation to C:\USMT on WIN-GC4
      3. Robocopies the captured MigStore from the network share to a local path on
         WIN-GC4 (C:\USMT\MigStore\<SourceComputerName>) - robocopy is run ON WIN-GC4
         (target-side pull) because WIN-GC4 blocks inbound SMB, so its C$ share is
         unreachable from the caller; the inbound pull works via WIN-GC4's RBCD
         delegation to the file server
      4. Runs LoadState on WIN-GC4 against the local copy of the store
      5. Robocopies the resulting load logs back to the network MigStore folder
         (also run on WIN-GC4, outbound via RBCD)

    The migration store is read from:
        \\HL-DC30\IT\USMT\MigStore\<SourceComputerName>\

.PARAMETER SourceComputerName
    Name of the computer whose captured MigStore should be restored. Defaults to
    'GC0'.

.PARAMETER TargetComputerName
    Name of the computer to restore the user state onto. Defaults to 'WIN-GC4'.

.PARAMETER Credential
    Credentials for the PSRemoting session on the target computer. If omitted the
    current user's Kerberos token is used.

.EXAMPLE
    .\LoadState_WIN-GC4.ps1
    Restores the GC0 migration store onto WIN-GC4 using current credentials.

.EXAMPLE
    .\LoadState_WIN-GC4.ps1 -Credential (Get-Credential)
    Restores using explicitly supplied credentials.

.NOTES
    LoadState must execute on the destination computer itself; this script uses
    PSRemoting to achieve that without requiring a local logon to WIN-GC4.

    Restore scope:
    - /lac  : create local accounts if they don't already exist (disabled)
    - /lae  : enable any account created by /lac
    - /c    : continue on non-fatal errors

    WIN-GC4 must already be domain-joined before running this script so that the
    captured domain user profiles resolve correctly by SID.

    A reboot of WIN-GC4 is recommended after LoadState completes so that all
    restored settings (shell, IE, etc.) take effect.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$SourceComputerName = 'GC0',

    [string]$TargetComputerName = 'WIN-GC4',

    [System.Management.Automation.PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RemoteUSMTPath      = '\\HL-DC30\IT\USMT'
$NetworkMigStorePath = Join-Path (Join-Path $RemoteUSMTPath 'MigStore') $SourceComputerName
$LocalBinSource       = Join-Path $PSScriptRoot '..\amd64'

#region Verify the source MigStore exists
if (-not (Test-Path $NetworkMigStorePath)) {
    throw "MigStore not found for '$SourceComputerName': $NetworkMigStorePath. Run ScanState first."
}
#endregion

if (-not $PSCmdlet.ShouldProcess($TargetComputerName, "Restore USMT user state captured from $SourceComputerName")) {
    return
}

#region Open PSSession
Write-Host "Connecting to $TargetComputerName via PSRemoting..."
$sessionParams = @{ ComputerName = $TargetComputerName }
if ($PSBoundParameters.ContainsKey('Credential')) {
    $sessionParams.Credential = $Credential
}
$session = New-PSSession @sessionParams
#endregion

try {
    #region Push USMT binaries to target
    $hasBinaries = Invoke-Command -Session $session -ScriptBlock {
        Test-Path 'C:\USMT\amd64\loadstate.exe'
    }

    if (-not $hasBinaries) {
        Write-Host "Copying USMT binaries to $TargetComputerName..."
        Invoke-Command -Session $session -ScriptBlock {
            if (-not (Test-Path 'C:\USMT')) {
                New-Item -Path 'C:\USMT' -ItemType Directory | Out-Null
            }
        }
        Copy-Item -Path $LocalBinSource -Destination 'C:\USMT\amd64' -ToSession $session -Recurse -Force
    } else {
        Write-Host "USMT binaries already present on $TargetComputerName."
    }
    #endregion

    #region Pull the migration store to target (target-side pull via RBCD)
    $localMigStore = Join-Path 'C:\USMT\MigStore' $SourceComputerName

    $hasStore = Invoke-Command -Session $session -ScriptBlock {
        param([string]$LocalMigStore)
        Test-Path (Join-Path $LocalMigStore 'USMT')
    } -ArgumentList $localMigStore

    if (-not $hasStore) {
        # Run robocopy ON the target (inside the PSSession) pulling the store INBOUND
        # from the file share to a local path, rather than pushing from the caller to
        # the target's C$ admin share. The target blocks inbound SMB (same as the
        # source machine), so \\<target>\C$ is unreachable from the caller; and
        # Copy-Item -ToSession trips a PowerShell bug on large store trees. The
        # target's inbound reach to the file share works via the RBCD delegation
        # configured for it (see Staging/NETLOGON/Config/KerberosDelegation.json).
        Write-Host "Copying MigStore from $NetworkMigStorePath to $TargetComputerName (target-side pull)..."
        $copyExit = Invoke-Command -Session $session -ScriptBlock {
            param([string]$NetworkMigStorePath, [string]$LocalMigStore)
            if (-not (Test-Path $LocalMigStore)) {
                New-Item -Path $LocalMigStore -ItemType Directory -Force | Out-Null
            }
            robocopy $NetworkMigStorePath $LocalMigStore /E /R:2 /W:5 /NP /NFL /NDL | Out-Host
            $LASTEXITCODE
        } -ArgumentList $NetworkMigStorePath, $localMigStore
        if ($copyExit -ge 8) {
            throw "robocopy (on $TargetComputerName) failed copying MigStore from $NetworkMigStorePath (exit $copyExit)."
        }
    } else {
        Write-Host "MigStore already present on $TargetComputerName."
    }
    #endregion

    #region Run LoadState locally on target
    Invoke-Command -Session $session -ScriptBlock {
        param([string]$LocalMigStore)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $LogFilePath  = Join-Path $LocalMigStore 'load_all.log'
        $ProgFilePath = Join-Path $LocalMigStore 'prog_load_all.log'

        Write-Host "Starting LoadState on $env:COMPUTERNAME (all captured profiles)..."
        Write-Host "  MigStore : $LocalMigStore"
        Write-Host "  Log      : $LogFilePath"

        Push-Location 'C:\USMT\amd64'
        try {
            .\loadstate.exe "$LocalMigStore" `
                /i:MigDocs.xml `
                /i:MigApp.xml `
                /i:MigAppData.xml `
                /v:13 `
                /lac `
                /lae `
                /progress:"$ProgFilePath" `
                /l:"$LogFilePath" `
                /c

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "loadstate.exe exited with code $LASTEXITCODE. Review: $LogFilePath"
            } else {
                Write-Host "LoadState completed successfully."
            }
        } finally {
            Pop-Location
        }
    } -ArgumentList $localMigStore
    #endregion

    #region Push load logs back to network MigStore for record-keeping (target-side push)
    # Run robocopy ON the target pushing the load logs OUTBOUND to the file share
    # (via RBCD), mirroring the store pull. Same reason: the target blocks inbound SMB.
    Write-Host "Copying load logs from $TargetComputerName to $NetworkMigStorePath..."
    $logExit = Invoke-Command -Session $session -ScriptBlock {
        param([string]$LocalMigStore, [string]$NetworkMigStorePath)
        robocopy $LocalMigStore $NetworkMigStorePath load_all.log prog_load_all.log /R:2 /W:5 /NP /NFL /NDL | Out-Host
        $LASTEXITCODE
    } -ArgumentList $localMigStore, $NetworkMigStorePath
    if ($logExit -ge 8) {
        Write-Warning "robocopy (on $TargetComputerName) failed pushing load logs to $NetworkMigStorePath (exit $logExit)."
    }
    Write-Host "Restore complete. Reboot $TargetComputerName for all settings to take effect."
    #endregion
} finally {
    Remove-PSSession $session
}
