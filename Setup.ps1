#Requires -Version 5.1
<#
.SYNOPSIS
    One-time (re-runnable) setup for the USMT toolkit: acquire the USMT binaries
    and create the global configuration interactively.

.DESCRIPTION
    Two idempotent steps, each of which only fills gaps unless you opt to redo it:

    1. Acquire binaries. If amd64\scanstate.exe is missing, this either copies
       them from a pre-installed / pre-copied source (-AdkOffline) or downloads
       the Windows ADK bootstrapper and installs ONLY the USMT feature, then
       copies the amd64 folder into the repo. If the binaries already exist, the
       found version is reported and you are asked before overwriting.

    2. Interactive config. Creates Config\Settings.psd1 (gitignored) by prompting
       for each global setting. Press Enter to accept the value shown in
       parentheses. If a config already exists you are asked whether to reconfigure.

    USMT binaries are not redistributable, which is why they are acquired here
    rather than committed.

.PARAMETER AdkOffline
    Path to a source for the USMT amd64 binaries on an air-gapped or pre-staged
    host. Accepts any of:
      - a folder that directly contains scanstate.exe (an amd64 folder), or
      - an installed ADK root (the "User State Migration Tool\amd64" folder is
        located beneath it).

.PARAMETER AdkUrl
    Override the Windows ADK bootstrapper download URL (defaults to Microsoft's
    stable fwlink for the current ADK). Used only when acquiring binaries online.

.PARAMETER UninstallAdkAfter
    After an online install, uninstall the ADK once the amd64 folder has been
    copied into the repo.

.PARAMETER Force
    Skip confirmation prompts: overwrite existing binaries and reconfigure without
    asking. Config prompts still run (use the shown defaults by pressing Enter).

.EXAMPLE
    .\Setup.ps1
    Acquire binaries if needed, then walk through configuration.

.EXAMPLE
    .\Setup.ps1 -AdkOffline 'D:\ADK\User State Migration Tool\amd64'
    Use pre-staged binaries instead of downloading the ADK.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$AdkOffline,

    [string]$AdkUrl = 'https://go.microsoft.com/fwlink/?linkid=2289980',

    [switch]$UninstallAdkAfter,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot    = $PSScriptRoot
$binPath     = Join-Path $repoRoot 'amd64'
$configDir   = Join-Path $repoRoot 'Config'
$settingsPath = Join-Path $configDir 'Settings.psd1'

#region Prompt helpers

function Confirm-YesNo {
    <#  Returns $true/$false. Default is No unless -DefaultYes.  #>
    param (
        [Parameter(Mandatory)][string]$Question,
        [switch]$DefaultYes
    )
    if ($Force) { return $true }
    $suffix = if ($DefaultYes) { '(Y/n)' } else { '(y/N)' }
    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return [bool]$DefaultYes }
    return ($answer.Trim() -match '^(y|yes)$')
}

function Read-ConfigValue {
    <#
        Prompts for a single config value. Shows "(current: X)" when a value is
        already set, otherwise "(default: Y)". Pressing Enter keeps the current
        value unchanged (blank stays blank).
    #>
    param (
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Current,
        [string]$DisplayDefault,
        [string[]]$ValidValues
    )

    if (-not [string]::IsNullOrWhiteSpace($Current)) {
        $hint = "(current: $Current)"
    } elseif (-not [string]::IsNullOrWhiteSpace($DisplayDefault)) {
        $hint = "(default: $DisplayDefault)"
    } else {
        $hint = "(blank)"
    }

    while ($true) {
        $answer = Read-Host "$Prompt $hint"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Current
        }
        $answer = $answer.Trim()
        if ($ValidValues -and ($ValidValues -notcontains $answer)) {
            Write-Host "  Please enter one of: $($ValidValues -join ', ')" -ForegroundColor Yellow
            continue
        }
        return $answer
    }
}

#endregion

#region PSD1 formatting

function Format-PsdString {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    # Single-quoted PSD1 string; escape embedded single quotes by doubling.
    return "'" + ($Value -replace "'", "''") + "'"
}

function Format-PsdStringArray {
    param([string[]]$Values)
    $items = @()
    foreach ($v in @($Values)) {
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            $items += (Format-PsdString $v.Trim())
        }
    }
    if ($items.Count -eq 0) { return '@()' }
    return '@(' + ($items -join ', ') + ')'
}

function ConvertTo-StringArray {
    <#  Splits a comma/semicolon separated string into a trimmed string array.  #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

#endregion

#region Binary acquisition

function Find-UsmtAmd64 {
    <#  Locate an amd64 folder (one containing scanstate.exe) under a path.  #>
    param([Parameter(Mandatory)][string]$SearchRoot)

    if (-not (Test-Path -LiteralPath $SearchRoot)) {
        throw "AdkOffline path not found: $SearchRoot"
    }
    if (Test-Path -LiteralPath (Join-Path $SearchRoot 'scanstate.exe')) {
        return $SearchRoot
    }
    $hit = Get-ChildItem -LiteralPath $SearchRoot -Recurse -Filter 'scanstate.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($hit) {
        return $hit.DirectoryName
    }
    throw "Could not find scanstate.exe under '$SearchRoot'."
}

function Copy-Amd64Into {
    param(
        [Parameter(Mandatory)][string]$SourceAmd64,
        [Parameter(Mandatory)][string]$Destination
    )
    if ($PSCmdlet.ShouldProcess($Destination, "Copy USMT binaries from $SourceAmd64")) {
        if (-not (Test-Path -LiteralPath $Destination)) {
            New-Item -Path $Destination -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $SourceAmd64 '*') -Destination $Destination -Recurse -Force
        Write-Host "USMT binaries copied to $Destination" -ForegroundColor Green
    }
}

function Install-UsmtFromAdk {
    <#
        Download the ADK bootstrapper and install only the USMT feature, then
        return the path to the installed amd64 folder. Best-effort: raises a
        clear error with manual guidance if any step fails.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [switch]$Uninstall
    )

    $stageDir = Join-Path $repoRoot 'Windows ADK Installers'
    if (-not (Test-Path -LiteralPath $stageDir)) {
        New-Item -Path $stageDir -ItemType Directory -Force | Out-Null
    }
    $bootstrapper = Join-Path $stageDir 'adksetup.exe'

    if ($PSCmdlet.ShouldProcess($Url, 'Download ADK bootstrapper')) {
        Write-Host "Downloading ADK bootstrapper..." -ForegroundColor Cyan
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $bootstrapper -UseBasicParsing
        } catch {
            throw "Failed to download the ADK bootstrapper from '$Url': $($_.Exception.Message). " +
                  "Download the Windows ADK manually and re-run with -AdkOffline <path>."
        }
    }

    $featureId = 'OptionId.UserStateMigrationTool'
    if ($PSCmdlet.ShouldProcess('Windows ADK', "Install feature $featureId")) {
        Write-Host "Installing USMT feature (this can take several minutes)..." -ForegroundColor Cyan
        $proc = Start-Process -FilePath $bootstrapper `
            -ArgumentList @('/quiet', '/features', $featureId) -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "ADK setup exited with code $($proc.ExitCode). Install the USMT feature manually, then re-run with -AdkOffline."
        }
    }

    $adkUsmt = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool'
    $amd64 = Find-UsmtAmd64 -SearchRoot $adkUsmt

    if ($Uninstall -and $PSCmdlet.ShouldProcess('Windows ADK', 'Uninstall after copying binaries')) {
        Write-Host "Uninstalling ADK..." -ForegroundColor Cyan
        Start-Process -FilePath $bootstrapper -ArgumentList @('/uninstall', '/quiet') -Wait | Out-Null
    }

    return $amd64
}

function Invoke-BinaryAcquisition {
    $scanstate = Join-Path $binPath 'scanstate.exe'
    $haveBinaries = Test-Path -LiteralPath $scanstate

    if ($haveBinaries) {
        $version = (Get-Item -LiteralPath $scanstate).VersionInfo.ProductVersion
        Write-Host "USMT binaries already present: $binPath (scanstate $version)" -ForegroundColor Green
        # A reliable "is this the latest ADK?" check is not available without
        # downloading; skip gracefully rather than guess (see DESIGN.md open Q2).
        if (-not (Confirm-YesNo -Question 'Re-acquire / overwrite the USMT binaries?')) {
            Write-Host "Keeping existing binaries." -ForegroundColor Green
            return
        }
    }

    if ($AdkOffline) {
        $src = Find-UsmtAmd64 -SearchRoot $AdkOffline
        Copy-Amd64Into -SourceAmd64 $src -Destination $binPath
        return
    }

    Write-Host "No -AdkOffline supplied; acquiring the Windows ADK online." -ForegroundColor Cyan
    $src = Install-UsmtFromAdk -Url $AdkUrl -Uninstall:$UninstallAdkAfter
    Copy-Amd64Into -SourceAmd64 $src -Destination $binPath
}

#endregion

#region Interactive configuration

function Invoke-Configuration {
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }

    # Seed current values from an existing config when reconfiguring.
    $current = @{
        MigStoreMode         = 'Local'
        MigStoreLocalPath    = ''
        MigStoreNetworkPath  = ''
        UsmtBinPath          = ''
        LogRoot              = ''
        RemoteStagingPath    = 'C:\USMT'
        TransferMethod       = 'Auto'
        DefaultExcludeRules  = @()
        Verbosity            = '13'
    }

    if (Test-Path -LiteralPath $settingsPath) {
        if (-not (Confirm-YesNo -Question 'Existing config detected. Reconfigure?')) {
            Write-Host "Keeping existing configuration." -ForegroundColor Green
            return
        }
        try {
            $existing = Import-PowerShellDataFile -LiteralPath $settingsPath
            foreach ($k in @($current.Keys)) {
                if ($existing.ContainsKey($k) -and $null -ne $existing[$k]) {
                    $current[$k] = $existing[$k]
                }
            }
        } catch {
            Write-Warning "Could not read existing config ($($_.Exception.Message)); starting from defaults."
        }
    }

    Write-Host ''
    Write-Host 'Configuring the USMT toolkit.' -ForegroundColor Cyan
    Write-Host 'Press Enter to accept the value shown in parentheses.' -ForegroundColor Cyan
    Write-Host ''

    $mode = Read-ConfigValue -Prompt 'Store mode [Local/Network]' -Current $current.MigStoreMode -ValidValues @('Local', 'Network')
    $localPath = Read-ConfigValue -Prompt 'Local store root' -Current ([string]$current.MigStoreLocalPath) -DisplayDefault (Join-Path $repoRoot 'MigStore')
    $netPath = Read-ConfigValue -Prompt 'Network store root (UNC; blank = none)' -Current ([string]$current.MigStoreNetworkPath)
    $bin = Read-ConfigValue -Prompt 'USMT binaries path' -Current ([string]$current.UsmtBinPath) -DisplayDefault $binPath
    $logs = Read-ConfigValue -Prompt 'Log directory' -Current ([string]$current.LogRoot) -DisplayDefault (Join-Path $repoRoot 'Logs')
    $staging = Read-ConfigValue -Prompt 'Remote staging path' -Current ([string]$current.RemoteStagingPath) -DisplayDefault 'C:\USMT'
    $transfer = Read-ConfigValue -Prompt 'Transfer method [Auto/AdminShare/SessionPushPull]' -Current ([string]$current.TransferMethod) -ValidValues @('Auto', 'AdminShare', 'SessionPushPull')
    $excludesCsv = Read-ConfigValue -Prompt 'Default exclude rules (comma-separated XML names; blank = none)' -Current (@($current.DefaultExcludeRules) -join ', ')
    $verbosity = Read-ConfigValue -Prompt 'Verbosity /v level (0-13)' -Current ([string]$current.Verbosity) -DisplayDefault '13'

    $excludes = ConvertTo-StringArray -Value $excludesCsv
    $verbInt = 13
    [void][int]::TryParse($verbosity, [ref]$verbInt)

    $content = @"
<#
    Settings.psd1 - global configuration for the USMT toolkit (generated by Setup.ps1).
    Gitignored: this file holds environment identity and is never committed.
    Any value here can be overridden per-run by the matching command-line parameter.
#>
@{
    MigStoreMode        = $(Format-PsdString $mode)
    MigStoreLocalPath   = $(Format-PsdString $localPath)
    MigStoreNetworkPath = $(Format-PsdString $netPath)
    UsmtBinPath         = $(Format-PsdString $bin)
    LogRoot             = $(Format-PsdString $logs)
    RemoteStagingPath   = $(Format-PsdString $staging)
    TransferMethod      = $(Format-PsdString $transfer)
    DefaultExcludeRules = $(Format-PsdStringArray $excludes)
    Verbosity           = $verbInt
}
"@

    if ($PSCmdlet.ShouldProcess($settingsPath, 'Write configuration')) {
        Set-Content -LiteralPath $settingsPath -Value $content -Encoding UTF8
        Write-Host ''
        Write-Host "Configuration written to $settingsPath" -ForegroundColor Green

        # Validate what we just wrote so a bad value is caught immediately.
        try {
            Import-PowerShellDataFile -LiteralPath $settingsPath | Out-Null
            Write-Host "Configuration validated." -ForegroundColor Green
        } catch {
            Write-Warning "The written config did not re-parse: $($_.Exception.Message)"
        }
    }
}

#endregion

Write-Host '=== USMT Toolkit Setup ===' -ForegroundColor Cyan
Invoke-BinaryAcquisition
Write-Host ''
Invoke-Configuration
Write-Host ''
Write-Host 'Setup complete. Next: .\Backup-UserState.ps1  (see README.md)' -ForegroundColor Cyan
