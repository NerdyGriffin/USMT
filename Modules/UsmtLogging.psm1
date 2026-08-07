#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained logging for the USMT toolkit.

.DESCRIPTION
    Provides a PowerShell transcript wrapper for each entry-point run plus a
    timestamped Write-Log that mirrors to the console (and is therefore captured
    in the transcript). No dependency on any external module.

    Log filename convention (per DESIGN.md):
        <script>.<COMPUTERNAME>.<FileDateTime>.log
    written under the configured LogRoot. A simple retention helper prunes old
    logs by age.

    USMT's own logs (scan_*.log, list_*.log, prog_*.log, load_*.log) are written
    beside the migration store by UsmtCore, not here.
#>

Set-StrictMode -Version Latest

# Module-scoped state for the currently-open transcript.
$script:UsmtTranscriptPath = $null

#region Transcript lifecycle

function Start-UsmtLog {
    <#
    .SYNOPSIS
        Starts a transcript for an entry-point run and returns its path.

    .DESCRIPTION
        Ensures LogRoot exists, computes a log filename following the
        <script>.<COMPUTERNAME>.<FileDateTime>.log convention, and starts a
        PowerShell transcript there. Console output (including Write-Log) is
        captured for the life of the run.

    .PARAMETER ScriptName
        Short name of the calling script (e.g. 'Backup-UserState'), used as the
        first filename segment.

    .PARAMETER LogRoot
        Directory to write the transcript into.

    .PARAMETER ComputerName
        Machine name segment for the filename. Defaults to the local computer.

    .OUTPUTS
        [string] The full path of the started transcript.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$ScriptName,

        [Parameter(Mandatory)]
        [string]$LogRoot,

        [string]$ComputerName = $env:COMPUTERNAME
    )

    if (-not (Test-Path -LiteralPath $LogRoot)) {
        New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
    }

    $stamp    = Get-Date -Format FileDateTime
    $fileName = "$ScriptName.$ComputerName.$stamp.log"
    $logPath  = Join-Path $LogRoot $fileName

    try {
        Start-Transcript -Path $logPath -Force | Out-Null
        $script:UsmtTranscriptPath = $logPath
    } catch {
        # A transcript is a convenience, not a hard requirement; if one is already
        # running (or transcription is disabled) keep going without failing the run.
        Write-Warning "Could not start transcript at '$logPath': $($_.Exception.Message)"
        $script:UsmtTranscriptPath = $null
    }

    return $logPath
}

function Stop-UsmtLog {
    <#
    .SYNOPSIS
        Stops the transcript started by Start-UsmtLog, if any.
    #>
    [CmdletBinding()]
    param()

    if ($script:UsmtTranscriptPath) {
        try {
            Stop-Transcript | Out-Null
        } catch {
            # No active transcript (or transcription disabled) - nothing to do.
            Write-Verbose "Stop-UsmtLog: no active transcript to stop."
        }
        $script:UsmtTranscriptPath = $null
    }
}

#endregion

#region Write-Log

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped, level-tagged message to the console.

    .DESCRIPTION
        Emits '<ISO-8601 timestamp> [LEVEL] <message>'. The message is written to
        the console (and thus captured by any active transcript). INFO/SUCCESS/ERROR
        use Write-Host (ERROR in red); WARN uses Write-Warning. Write-Log only
        reports - it never alters control flow, so an ERROR line cannot terminate
        the caller (that is the job of an explicit throw).

    .PARAMETER Message
        The text to log.

    .PARAMETER Level
        One of INFO, SUCCESS, WARN, ERROR. Defaults to INFO.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    # ISO-8601 via the 's' format specifier, e.g. 2026-07-03T14:22:05.
    $timestamp = Get-Date -Format 's'
    $line      = "$timestamp [$Level] $Message"

    switch ($Level) {
        'WARN'    { Write-Warning $line }
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
}

#endregion

#region Retention

function Remove-UsmtOldLog {
    <#
    .SYNOPSIS
        Prunes toolkit transcripts older than a retention window.

    .DESCRIPTION
        Deletes '*.log' files under LogRoot whose LastWriteTime is older than
        KeepDays. Only the top level of LogRoot is considered; USMT's own logs
        (kept beside the store) are untouched.

    .PARAMETER LogRoot
        Directory to prune.

    .PARAMETER KeepDays
        Age threshold in days. Files older than this are removed. Must be >= 1.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$LogRoot,

        [ValidateRange(1, 3650)]
        [int]$KeepDays = 30
    )

    if (-not (Test-Path -LiteralPath $LogRoot)) {
        return
    }

    $cutoff = (Get-Date).AddDays(-$KeepDays)
    $old = Get-ChildItem -LiteralPath $LogRoot -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }

    foreach ($file in $old) {
        if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove old log')) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

Export-ModuleMember -Function `
    Start-UsmtLog, `
    Stop-UsmtLog, `
    Write-Log, `
    Remove-UsmtOldLog
