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
      4. Pushes the completed store OUTBOUND from GC0 to the network MigStore via
         robocopy run on GC0 (uses the RBCD delegation for GC0 -> file server).
         GC0 blocks inbound SMB, so pulling from its C$ share does not work; and
         Copy-Item -FromSession trips a PowerShell bug on large store trees.

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
    - /i:ExcludeBulkData.xml        : skips large re-downloadable / regenerable
                                      content - game libraries (GOG, Xbox, Epic,
                                      GOG Galaxy, Google Play Games), the Nextcloud
                                      sync folder, and Temp/NVIDIA caches. Downloads
                                      and small tooling (Python, portable apps) are
                                      intentionally kept. See the XML for the full
                                      list and rationale.

    Note: GC0's secondary Windows disk (D:) and Bazzite btrfs disk (E:) were
    physically removed before capture, so /localonly sees only the C: system
    volume. The exclude XML handles the bulk content that lives on C: itself.

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
    Copy-Item -Path (Join-Path $PSScriptRoot 'ExcludeBulkData.xml') `
              -Destination 'C:\USMT\amd64\ExcludeBulkData.xml' -ToSession $session -Force
    #endregion

    #region Run ScanState locally on GC0
    $localMigStore = 'C:\USMT\MigStore'

    $scanExit = Invoke-Command -Session $session -ScriptBlock {
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
            # Pipe to Out-Host so scanstate's console output streams to the caller
            # without polluting this script block's output (only the exit code below
            # is returned). /c already absorbs non-fatal errors, so a non-zero exit
            # here is a fatal ScanState failure.
            .\scanstate.exe "$LocalMigStore" `
                /o `
                /vsc `
                /i:MigDocs.xml `
                /i:MigApp.xml `
                /i:MigAppData.xml `
                /i:ExcludeBulkData.xml `
                /v:13 `
                /localonly `
                /listfiles:"$ListFilePath" `
                /l:"$LogFilePath" `
                /progress:"$ProgFilePath" `
                /c | Out-Host

            $scanCode = $LASTEXITCODE
            if ($scanCode -ne 0) {
                Write-Warning "scanstate.exe exited with code $scanCode. Review: $LogFilePath"
            } else {
                Write-Host "ScanState completed successfully."
            }
            $scanCode
        } finally {
            Pop-Location
        }
    } -ArgumentList $localMigStore

    # Gate the outbound copy on a successful capture: never publish a failed or
    # partial store over the previous good one.
    if ($scanExit -ne 0) {
        throw "ScanState on $ComputerName failed (exit $scanExit); aborting before copying the store to $NetworkMigStorePath. Review scan_all.log under $localMigStore on $ComputerName."
    }
    #endregion

    #region Push MigStore from GC0 to the network share (GC0-side push via RBCD)
    # Run robocopy ON GC0 (inside the PSSession) pushing the store OUTBOUND to the
    # file server, rather than pulling from GC0's C$ admin share. GC0 blocks inbound
    # SMB (a Public firewall profile is active), so \\GC0\C$ is unreachable from the
    # caller; and Copy-Item -FromSession trips a PowerShell bug ("property 'Length'
    # cannot be found") on large store trees. GC0's outbound reach to the file share
    # works via the Resource-Based Constrained Delegation configured for GC0 -> the
    # file server (see Staging/NETLOGON/Config/KerberosDelegation.json). robocopy is
    # resumable and fast for a multi-hundred-GB store.
    Write-Host "Copying MigStore from $ComputerName to $NetworkMigStorePath (GC0-side push)..."
    $copyExit = Invoke-Command -Session $session -ScriptBlock {
        param([string]$LocalMigStore, [string]$NetworkMigStorePath)
        if (-not (Test-Path $NetworkMigStorePath)) {
            New-Item -Path $NetworkMigStorePath -ItemType Directory -Force | Out-Null
        }
        robocopy $LocalMigStore $NetworkMigStorePath /E /R:2 /W:5 /NP /NFL /NDL | Out-Host
        $LASTEXITCODE
    } -ArgumentList $localMigStore, $NetworkMigStorePath
    # robocopy exit codes < 8 indicate success (files copied / nothing to do).
    if ($copyExit -ge 8) {
        throw "robocopy (on $ComputerName) failed copying MigStore to $NetworkMigStorePath (exit $copyExit)."
    }
    Write-Host "Backup complete. MigStore location: $NetworkMigStorePath"
    #endregion
} finally {
    Remove-PSSession $session
}
