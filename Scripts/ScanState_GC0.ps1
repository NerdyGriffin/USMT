#Requires -Version 5.1
<#
.SYNOPSIS
    Captures USMT user state for all profiles on GC0 to the network MigStore.

.DESCRIPTION
    Remotely invokes USMT ScanState on GC0 via PowerShell Remoting. All local user
    profiles are captured in a single ScanState pass.

    To avoid the Kerberos double-hop problem (GC0 cannot forward credentials to the
    file server), this script:
      1. Opens a persistent PSSession to GC0
      2. Pushes USMT binaries from the admin workstation to C:\USMT on GC0
      3. Runs ScanState on GC0, writing the store to a local path (C:\USMT\MigStore\)
      4. Pulls the completed store back to the network MigStore via Copy-Item -FromSession

    The resulting migration store is written to:
        \\HL-DC30\IT\USMT\MigStore\GC0\

    Prerequisites:
    - WinRM / PSRemoting must be enabled on GC0
    - The account running this script must have local admin rights on GC0

.PARAMETER Credential
    Credentials for the PSRemoting session on GC0. If omitted the current user's
    Kerberos token is used (sufficient when running as a domain admin from a domain
    workstation joined to the same domain as GC0).

.EXAMPLE
    .\ScanState_GC0.ps1
    Captures all user profiles on GC0 using current credentials.

.EXAMPLE
    .\ScanState_GC0.ps1 -Credential (Get-Credential)
    Captures all user profiles on GC0 using explicitly supplied credentials.

.NOTES
    ScanState must execute on the source computer itself; this script uses
    PSRemoting to achieve that without requiring a local logon to GC0.

    Capture scope:
    - /localonly                    : local profiles only, no roaming data
    - /vsc                          : Volume Shadow Copy for files locked by running processes
    - /c                            : continue on non-fatal errors
    - /i:ExcludeNonUserFolders.xml  : skips reinstallable, non-user-state folders
                                      at C:\ root (game installs, Python, portable
                                      apps) that MigDocs.xml would otherwise sweep in

    Note: GC0's secondary Windows disk (D:) and Bazzite btrfs disk (E:) were
    physically removed before capture, so /localonly sees only the C: system
    volume. The exclude XML handles the remaining non-user-state folders that
    live on C: itself.

    To restrict capture to specific users, pass /ui and /ue filters to scanstate
    (see USMT documentation for syntax).
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [System.Management.Automation.PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ComputerName        = 'GC0'
$RemoteUSMTPath      = '\\HL-DC30\IT\USMT'
$NetworkMigStorePath = Join-Path (Join-Path $RemoteUSMTPath 'MigStore') $ComputerName
$LocalBinSource      = Join-Path $PSScriptRoot '..\amd64'

#region Ensure MigStore directory exists on the file server
if (-not (Test-Path $NetworkMigStorePath)) {
    Write-Verbose "Creating MigStore directory: $NetworkMigStorePath"
    New-Item -Path $NetworkMigStorePath -ItemType Directory | Out-Null
}
#endregion

if (-not $PSCmdlet.ShouldProcess($ComputerName, 'Run USMT ScanState for all user profiles')) {
    return
}

#region Open PSSession
Write-Host "Connecting to $ComputerName via PSRemoting..."
$sessionParams = @{ ComputerName = $ComputerName }
if ($PSBoundParameters.ContainsKey('Credential')) {
    $sessionParams.Credential = $Credential
}
$session = New-PSSession @sessionParams
#endregion

try {
    #region Push USMT binaries to GC0
    $hasBinaries = Invoke-Command -Session $session -ScriptBlock {
        Test-Path 'C:\USMT\amd64\scanstate.exe'
    }

    if (-not $hasBinaries) {
        Write-Host "Copying USMT binaries to $ComputerName..."
        Invoke-Command -Session $session -ScriptBlock {
            if (-not (Test-Path 'C:\USMT')) {
                New-Item -Path 'C:\USMT' -ItemType Directory | Out-Null
            }
        }
        Copy-Item -Path $LocalBinSource -Destination 'C:\USMT\amd64' -ToSession $session -Recurse -Force
    } else {
        Write-Host "USMT binaries already present on $ComputerName."
    }

    # Always push the custom exclude rule fresh, even when binaries are cached,
    # so script-tracked changes to it take effect on the next run.
    Copy-Item -Path (Join-Path $PSScriptRoot 'ExcludeNonUserFolders.xml') `
              -Destination 'C:\USMT\amd64\ExcludeNonUserFolders.xml' -ToSession $session -Force
    #endregion

    #region Run ScanState locally on GC0
    $localMigStore = 'C:\USMT\MigStore'

    Invoke-Command -Session $session -ScriptBlock {
        param([string]$LocalMigStore)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        if (-not (Test-Path $LocalMigStore)) {
            New-Item -Path $LocalMigStore -ItemType Directory | Out-Null
        }

        $LogFilePath  = Join-Path $LocalMigStore 'scan_all.log'
        $ProgFilePath = Join-Path $LocalMigStore 'prog_all.log'
        $ListFilePath = Join-Path $LocalMigStore 'list_all.log'

        Write-Host "Starting ScanState on $env:COMPUTERNAME (all user profiles)..."
        Write-Host "  MigStore : $LocalMigStore"
        Write-Host "  Log      : $LogFilePath"

        Push-Location 'C:\USMT\amd64'
        try {
            .\scanstate.exe "$LocalMigStore" `
                /o `
                /vsc `
                /i:MigDocs.xml `
                /i:MigApp.xml `
                /i:MigAppData.xml `
                /i:ExcludeNonUserFolders.xml `
                /v:13 `
                /localonly `
                /listfiles:"$ListFilePath" `
                /l:"$LogFilePath" `
                /progress:"$ProgFilePath" `
                /c

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "scanstate.exe exited with code $LASTEXITCODE. Review: $LogFilePath"
            } else {
                Write-Host "ScanState completed successfully."
            }
        } finally {
            Pop-Location
        }
    } -ArgumentList $localMigStore
    #endregion

    #region Pull MigStore back to network share
    Write-Host "Copying MigStore from $ComputerName to $NetworkMigStorePath..."
    Copy-Item -Path $localMigStore -Destination $NetworkMigStorePath -FromSession $session -Recurse -Force
    Write-Host "Backup complete. MigStore location: $NetworkMigStorePath"
    #endregion
} finally {
    Remove-PSSession $session
}
