#Requires -Version 5.1
<#
.SYNOPSIS
    Captures USMT user state for all profiles on GC0 to the network MigStore.

.DESCRIPTION
    Remotely invokes USMT ScanState on GC0 via PowerShell Remoting. All local user
    profiles are captured in a single ScanState pass. USMT binaries are copied from
    the network share to C:\USMT on GC0 if not already present.

    The resulting migration store is written to:
        \\files.ad.nerdygriffin.net\it\programfiles\USMT\MigStore\GC0\

    Prerequisites:
    - WinRM / PSRemoting must be enabled on GC0
    - The account running this script must have local admin rights on GC0
    - GC0 must be able to reach \\files.ad.nerdygriffin.net\it\ over SMB

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
    - /localonly  : local profiles only, no roaming data
    - /vsc        : Volume Shadow Copy for files locked by running processes
    - /c          : continue on non-fatal errors

    To restrict capture to specific users, pass /ui and /ue filters to scanstate
    (see USMT documentation for syntax).
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [System.Management.Automation.PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ComputerName   = 'GC0'
$RemoteUSMTPath = '\\files.ad.nerdygriffin.net\it\programfiles\USMT'
$MigStorePath   = Join-Path (Join-Path $RemoteUSMTPath 'MigStore') $ComputerName

#region Ensure MigStore directory exists on the file server
if (-not (Test-Path $MigStorePath)) {
    Write-Verbose "Creating MigStore directory: $MigStorePath"
    New-Item -Path $MigStorePath -ItemType Directory | Out-Null
}
#endregion

#region Build Invoke-Command parameters
$invokeParams = @{
    ComputerName = $ComputerName
    ScriptBlock  = {
        param(
            [string]$RemoteUSMTPath,
            [string]$MigStorePath
        )

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $LocalUSMTPath       = 'C:\USMT'
        $LocalExecutablePath = Join-Path $LocalUSMTPath 'amd64'

        #region Copy USMT binaries if not present on GC0
        if (-not (Test-Path (Join-Path $LocalExecutablePath 'scanstate.exe'))) {
            Write-Host "Copying USMT binaries to $env:COMPUTERNAME..."
            if (-not (Test-Path $LocalUSMTPath)) {
                New-Item -Path $LocalUSMTPath -ItemType Directory | Out-Null
            }
            Copy-Item -Path (Join-Path $RemoteUSMTPath 'amd64') `
                      -Destination $LocalUSMTPath -Force -Recurse
        }
        #endregion

        #region Ensure per-computer MigStore directory is accessible from GC0
        if (-not (Test-Path $MigStorePath)) {
            New-Item -Path $MigStorePath -ItemType Directory | Out-Null
        }
        #endregion

        $LogFilePath  = Join-Path $MigStorePath 'scan_all.log'
        $ProgFilePath = Join-Path $MigStorePath 'prog_all.log'
        $ListFilePath = Join-Path $MigStorePath 'list_all.log'

        Write-Host "Starting ScanState on $env:COMPUTERNAME (all user profiles)..."
        Write-Host "  MigStore : $MigStorePath"
        Write-Host "  Log      : $LogFilePath"

        Push-Location $LocalExecutablePath
        try {
            .\scanstate.exe "$MigStorePath" `
                /o `
                /vsc `
                /i:MigDocs.xml `
                /i:MigApp.xml `
                /i:MigAppData.xml `
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
    }
    ArgumentList = $RemoteUSMTPath, $MigStorePath
}

if ($PSBoundParameters.ContainsKey('Credential')) {
    $invokeParams.Credential = $Credential
}
#endregion

#region Run ScanState on GC0
if ($PSCmdlet.ShouldProcess($ComputerName, 'Run USMT ScanState for all user profiles')) {
    Write-Host "Connecting to $ComputerName via PSRemoting..."
    Invoke-Command @invokeParams
    Write-Host "Backup complete. MigStore location: $MigStorePath"
}
#endregion
