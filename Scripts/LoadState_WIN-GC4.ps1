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

    To avoid the Kerberos double-hop problem (WIN-GC4 cannot forward credentials to
    the file server - it is also outside the Workstations OU covered by the RBCD
    delegation config, see Staging/NETLOGON/Config/KerberosDelegation.json), this
    script:
      1. Opens a persistent PSSession to WIN-GC4
      2. Pushes USMT binaries from the admin workstation to C:\USMT on WIN-GC4
      3. Pushes the captured MigStore from the network share to a local path on
         WIN-GC4 (C:\USMT\MigStore\<SourceComputerName>)
      4. Runs LoadState on WIN-GC4 against the local copy of the store
      5. Pulls the resulting load logs back to the network MigStore folder

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

    #region Push the migration store to target
    $localMigStore = Join-Path 'C:\USMT\MigStore' $SourceComputerName

    $hasStore = Invoke-Command -Session $session -ScriptBlock {
        param([string]$LocalMigStore)
        Test-Path (Join-Path $LocalMigStore 'USMT')
    } -ArgumentList $localMigStore

    if (-not $hasStore) {
        Write-Host "Copying MigStore from $NetworkMigStorePath to $TargetComputerName..."
        Invoke-Command -Session $session -ScriptBlock {
            if (-not (Test-Path 'C:\USMT\MigStore')) {
                New-Item -Path 'C:\USMT\MigStore' -ItemType Directory | Out-Null
            }
        }
        Copy-Item -Path $NetworkMigStorePath -Destination 'C:\USMT\MigStore' -ToSession $session -Recurse -Force
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

    #region Pull load logs back to network MigStore for record-keeping
    Write-Host "Copying load logs from $TargetComputerName to $NetworkMigStorePath..."
    Copy-Item -Path (Join-Path $localMigStore 'load_all.log') -Destination $NetworkMigStorePath -FromSession $session -Force
    Copy-Item -Path (Join-Path $localMigStore 'prog_load_all.log') -Destination $NetworkMigStorePath -FromSession $session -Force
    Write-Host "Restore complete. Reboot $TargetComputerName for all settings to take effect."
    #endregion
} finally {
    Remove-PSSession $session
}
