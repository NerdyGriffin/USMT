#Requires -Version 5.1
<#
.SYNOPSIS
    Core USMT operations: sessions, binary staging, the store transfer
    abstraction, XML validation, and scanstate/loadstate invocation.

.DESCRIPTION
    Every capture/restore is executed ON the subject machine - locally when no
    computer name is supplied, or over a single reused PSSession when one is.
    This module hides that split behind functions that accept an optional
    -Session ($null = local) and behave identically either way.

    The store transfer abstraction (Copy-MigStore) never uses
    Copy-Item -To/-FromSession for the store itself: that trips a PowerShell bug
    ("the property 'Length' cannot be found") on large trees. robocopy is used
    throughout - it is resumable and reports success as an exit code < 8.

    See DESIGN.md ("Transfer abstraction", "Lessons encoded in the design") for
    the reasoning baked into these functions.
#>

Set-StrictMode -Version Latest

#region Machine / session helpers

function Test-UsmtLocalComputer {
    <#
    .SYNOPSIS
        Returns $true when a computer name refers to the local machine.
    .DESCRIPTION
        Blank, 'localhost', '.', '127.0.0.1', the local COMPUTERNAME, or an FQDN
        whose first label is the local COMPUTERNAME all count as local.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [string]$ComputerName
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return $true }
    if ($ComputerName -eq '.' -or $ComputerName -eq 'localhost' -or $ComputerName -eq '127.0.0.1') { return $true }
    if ($ComputerName -ieq $env:COMPUTERNAME) { return $true }
    if ($ComputerName -like "$env:COMPUTERNAME.*") { return $true }
    return $false
}

function New-UsmtSession {
    <#
    .SYNOPSIS
        Opens a PSSession to a remote machine, or returns $null for local runs.
    .PARAMETER ComputerName
        Target machine. Blank/local names return $null (run locally).
    .PARAMETER Credential
        Optional credential; defaults to the caller's Kerberos token.
    #>
    [CmdletBinding()]
    param (
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential
    )

    if (Test-UsmtLocalComputer -ComputerName $ComputerName) {
        return $null
    }

    # Fail closed: a failed New-PSSession must never fall through as $null, which
    # the entry points treat as local mode - that would silently run USMT on the
    # caller instead of the requested remote machine. Force New-PSSession itself to
    # throw (ErrorAction Stop in the splat, so it holds even if a caller invokes
    # New-UsmtSession with a laxer -ErrorAction), and reject a null session too.
    $sessionParams = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
    if ($Credential) {
        $sessionParams['Credential'] = $Credential
    }
    $session = New-PSSession @sessionParams
    if (-not $session) {
        throw "Failed to open a PSSession to '$ComputerName' (no session was returned)."
    }
    return $session
}

function ConvertTo-UsmtAdminSharePath {
    <#
    .SYNOPSIS
        Maps a rooted local path to its administrative-share UNC form.
    .EXAMPLE
        ConvertTo-UsmtAdminSharePath -ComputerName GC0 -LocalPath 'C:\USMT\MigStore'
        # -> \\GC0\C$\USMT\MigStore
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$LocalPath
    )

    if ($LocalPath -notmatch '^[A-Za-z]:\\') {
        throw "Path '$LocalPath' is not a rooted local path; cannot map to an admin share."
    }
    $drive = $LocalPath.Substring(0, 1)
    $rest  = $LocalPath.Substring(3)   # strip 'C:\'
    return ('\\{0}\{1}$\{2}' -f $ComputerName, $drive, $rest)
}

#endregion

#region XML validation

function Test-UsmtXmlFile {
    <#
    .SYNOPSIS
        Validates an exclude-rule XML file before it is handed to scanstate.
    .DESCRIPTION
        Loads the file with System.Xml.XmlDocument so a malformed rule set is
        caught here (a clear PowerShell error) instead of costing a full run that
        ends in USMT error 29. Notably catches the "'--' inside an XML comment"
        mistake (lesson 2 in DESIGN.md).
    .PARAMETER Path
        Path to the XML file.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Exclude-rule XML not found: $Path"
    }

    $xml = New-Object System.Xml.XmlDocument
    try {
        $xml.Load($Path)
    } catch {
        throw "Invalid XML in '$Path': $($_.Exception.Message)"
    }
    return $true
}

#endregion

#region Binary staging

function Copy-UsmtBinary {
    <#
    .SYNOPSIS
        Ensures USMT binaries (and exclude-rule XMLs) are present on the subject
        machine, and returns the paths to use for the run.
    .DESCRIPTION
        Local runs are a no-op: the caller-side paths are returned unchanged.
        Remote runs push the amd64 folder into <StagingPath>\amd64 (only when the
        binaries are missing) and always push the exclude-rule XMLs fresh so
        tracked changes take effect on the next run.
    .PARAMETER Session
        Remote session, or $null for local.
    .PARAMETER BinPath
        Caller-side amd64 directory containing scanstate.exe / loadstate.exe.
    .PARAMETER StagingPath
        Remote working root (e.g. C:\USMT). Ignored for local runs.
    .PARAMETER ExcludeXmlPath
        Caller-side full paths to exclude-rule XMLs to make available.
    .OUTPUTS
        Hashtable with keys BinPath (dir holding scanstate/loadstate on the
        subject machine) and ExcludeXmlPath (full paths valid on the subject
        machine).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [string]$BinPath,

        [string]$StagingPath = 'C:\USMT',

        [string[]]$ExcludeXmlPath = @()
    )

    # Validate the caller-side source before either staging mode. Require BOTH
    # executables: capture uses scanstate.exe and restore uses loadstate.exe, so
    # a set missing either is unusable. Doing this ahead of the local/remote
    # branch means a remote run with an incomplete cache fails here, pointing at
    # the real cause, instead of copying a partial source and failing later at
    # the post-staging re-verification.
    foreach ($exe in 'scanstate.exe', 'loadstate.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $BinPath $exe))) {
            throw "$exe not found under '$BinPath'. Run Setup.ps1 to acquire the USMT binaries."
        }
    }

    # --- Local: nothing to copy ---
    if (-not $Session) {
        return @{
            BinPath        = $BinPath
            ExcludeXmlPath = @($ExcludeXmlPath)
        }
    }

    # --- Remote: stage binaries + exclude XMLs ---
    $remoteBin = Join-Path $StagingPath 'amd64'

    $hasBinaries = Invoke-Command -Session $Session -ScriptBlock {
        param($RemoteBin)
        # Require BOTH executables: a partial prior copy could leave scanstate.exe
        # without loadstate.exe, and skipping staging would then break restore.
        (Test-Path -LiteralPath (Join-Path $RemoteBin 'scanstate.exe')) -and
        (Test-Path -LiteralPath (Join-Path $RemoteBin 'loadstate.exe'))
    } -ArgumentList $remoteBin

    if (-not $hasBinaries) {
        Invoke-Command -Session $Session -ScriptBlock {
            param($RemoteBin)
            if (-not (Test-Path -LiteralPath $RemoteBin)) {
                New-Item -Path $RemoteBin -ItemType Directory -Force | Out-Null
            }
        } -ArgumentList $remoteBin

        # Copy-Item -ToSession is fine for the small binary payload (the store is
        # deliberately transferred with robocopy instead - see Copy-MigStore).
        # Copy the *contents* of amd64 into $remoteBin: copying the folder itself
        # nests it (C:\USMT\amd64\amd64) whenever the destination already exists
        # from a prior or interrupted run, which hides scanstate.exe.
        Copy-Item -Path (Join-Path $BinPath '*') -Destination $remoteBin -ToSession $Session -Recurse -Force -ErrorAction Stop
    }

    # Always refresh exclude-rule XMLs so edits take effect on re-run.
    $remoteExclude = @()
    foreach ($xml in @($ExcludeXmlPath)) {
        if (-not $xml) { continue }
        $leaf = Split-Path -Path $xml -Leaf
        $dest = Join-Path $remoteBin $leaf
        Copy-Item -Path $xml -Destination $dest -ToSession $Session -Force -ErrorAction Stop
        $remoteExclude += $dest
    }

    # Re-verify the staged binaries landed before handing back remote paths: a
    # copy can partially fail, and returning paths to a broken set would surface
    # as a confusing scanstate/loadstate error mid-run instead of here.
    $staged = Invoke-Command -Session $Session -ScriptBlock {
        param($RemoteBin)
        (Test-Path -LiteralPath (Join-Path $RemoteBin 'scanstate.exe')) -and
        (Test-Path -LiteralPath (Join-Path $RemoteBin 'loadstate.exe'))
    } -ArgumentList $remoteBin
    if (-not $staged) {
        throw "USMT binaries missing under '$remoteBin' on the remote after staging. The copy may have failed."
    }

    return @{
        BinPath        = $remoteBin
        ExcludeXmlPath = $remoteExclude
    }
}

#endregion

#region Store transfer abstraction

# Shared robocopy runner. Returns the robocopy exit code (< 8 = success).
$script:UsmtRobocopyScript = {
    param($Source, $Destination, $Files, $Options)

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    }

    $rcArgs = @($Source, $Destination)
    foreach ($f in @($Files)) { if ($f) { $rcArgs += $f } }
    foreach ($o in @($Options)) { if ($o) { $rcArgs += $o } }

    robocopy @rcArgs | Out-Host
    return $LASTEXITCODE
}

function Test-UsmtRobocopyOk {
    <#
    .SYNOPSIS
        True when a robocopy exit code indicates success (< 8).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [int]$ExitCode
    )
    return ($ExitCode -lt 8)
}

function Get-UsmtExitDisposition {
    <#
    .SYNOPSIS
        Classifies a scanstate/loadstate exit code as Success, CompletedWithSkips,
        or Failure.

    .DESCRIPTION
        The toolkit always runs USMT with /c, so non-fatal errors (locked files,
        ACL-protected paths, Defender data, etc.) are skipped rather than aborting
        the run. USMT signals this with return code 3 (USMT_WOULD_HAVE_FAILED,
        "at least one error was skipped as a result of /c"). That is a completed,
        usable migration - not a failure - so it maps to 'CompletedWithSkips' and
        the caller should surface a WARN pointing at the log, not throw.

        Only exit code 0 is a clean success. Every other code (invalid command
        line, setup/init errors, non-fatal I/O stop, fatal errors) is a genuine
        failure the caller must treat as fatal.

        See https://learn.microsoft.com/windows/deployment/usmt/usmt-return-codes.

    .PARAMETER ExitCode
        The scanstate or loadstate process exit code.

    .OUTPUTS
        [string] 'Success', 'CompletedWithSkips', or 'Failure'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    if ($ExitCode -eq 0) { return 'Success' }
    if ($ExitCode -eq 3) { return 'CompletedWithSkips' }
    return 'Failure'
}

function Test-UsmtRemoteWrite {
    <#
    .SYNOPSIS
        Throwaway test write used to probe the remote's second hop to the store.
    .DESCRIPTION
        Attempts to create the store directory and write/delete a tiny temp file
        from INSIDE the session, i.e. as the remote machine. Success means the
        SessionPushPull transfer method can reach the store; failure (typically a
        double-hop/auth error) means it cannot.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Invoke-Command -Session $Session -ScriptBlock {
        param($StorePath)
        try {
            if (-not (Test-Path -LiteralPath $StorePath)) {
                New-Item -Path $StorePath -ItemType Directory -Force | Out-Null
            }
            $probe = Join-Path $StorePath ('.usmt_probe_' + $PID + '.tmp')
            Set-Content -LiteralPath $probe -Value 'probe' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return $true
        } catch {
            return $false
        }
    } -ArgumentList $Path)
}

function Resolve-UsmtTransferMethod {
    <#
    .SYNOPSIS
        Chooses a concrete transfer method for a remote store copy.
    .DESCRIPTION
        For 'Auto', probes in the order defined in DESIGN.md:
          1. AdminShare      - can the caller reach \\<computer>\C$ ?
          2. SessionPushPull - can the remote itself write to the store (2nd hop)?
        Throws a structured diagnostic if neither works. An explicit method is
        returned as-is.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Auto', 'AdminShare', 'SessionPushPull')]
        [string]$TransferMethod,

        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$StorePath
    )

    if ($TransferMethod -ne 'Auto') {
        return $TransferMethod
    }

    # Probe 1: inbound SMB to the remote's admin share, from the caller.
    $adminShareRoot = ('\\{0}\C$' -f $ComputerName)
    $adminShareOk = Test-Path -LiteralPath $adminShareRoot -ErrorAction SilentlyContinue
    if ($adminShareOk) {
        return 'AdminShare'
    }

    # Probe 2: the remote's own second hop to the store (throwaway test write).
    $secondHopOk = Test-UsmtRemoteWrite -Session $Session -Path $StorePath
    if ($secondHopOk) {
        return 'SessionPushPull'
    }

    throw @"
Cannot transfer the migration store to/from '$ComputerName': no viable method.
  - AdminShare probe FAILED: '$adminShareRoot' is unreachable from this machine
    (inbound SMB to the remote is likely blocked by its firewall).
  - SessionPushPull probe FAILED: the remote could not write to the store
    '$StorePath' from within the session (the second hop to the file share
    failed - a Kerberos double-hop / delegation issue).
Resolve one of the two, or set TransferMethod explicitly. See the double-hop
guidance in README.md (RBCD, constrained delegation, CredSSP, or a store design
that avoids the second hop).
"@
}

function Copy-MigStore {
    <#
    .SYNOPSIS
        Transfers a migration store between the subject machine's working path and
        the durable store, using the configured/probed transfer method.
    .DESCRIPTION
        Local runs (no -Session) robocopy directly between WorkPath and StorePath
        under the caller's identity (a single hop). Remote runs use either the
        caller-side admin share (AdminShare) or robocopy run inside the session
        (SessionPushPull); 'Auto' probes for a working method.

        Returns the robocopy exit code (see Test-UsmtRobocopyOk). Throws only for
        configuration/probe failures, never for a non-zero robocopy code - the
        caller decides whether a given copy is fatal (the store) or a warning
        (log push-back).
    .PARAMETER Direction
        'Upload'   - move data from WorkPath into StorePath (backup / log push).
        'Download' - move data from StorePath into WorkPath (restore).
    .PARAMETER Session
        Remote session, or $null for local.
    .PARAMETER ComputerName
        Remote machine name (required for remote runs).
    .PARAMETER WorkPath
        Store path local to the subject machine (where scanstate/loadstate runs).
    .PARAMETER StorePath
        Durable store path (local to the caller, or a UNC share).
    .PARAMETER TransferMethod
        'Auto', 'AdminShare', or 'SessionPushPull' (remote only).
    .PARAMETER File
        Optional list of specific file names to copy (no recursion). Used for log
        push-back; omit to mirror the whole store tree.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Upload', 'Download')]
        [string]$Direction,

        [System.Management.Automation.Runspaces.PSSession]$Session,

        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$WorkPath,

        [Parameter(Mandatory)]
        [string]$StorePath,

        [ValidateSet('Auto', 'AdminShare', 'SessionPushPull')]
        [string]$TransferMethod = 'Auto',

        [string[]]$File = @()
    )

    # robocopy options. A specific file list copies just those files (no
    # recursion). A full-tree copy uses /E when publishing to the durable store
    # (Upload - never purge the destination) and /MIR when staging a store for
    # restore (Download - mirror so a prior restore's leftovers in the work path
    # cannot mix with this store and feed stale content to loadstate).
    $options = @('/R:2', '/W:5', '/NP', '/NFL', '/NDL')
    if (-not ($File -and @($File).Count -gt 0)) {
        if ($Direction -eq 'Download') {
            $options = @('/MIR') + $options
        } else {
            $options = @('/E') + $options
        }
    }

    # --- Local: single-hop copy under the caller's identity ---
    if (-not $Session) {
        if ($WorkPath -eq $StorePath) {
            # Store and working copy are the same location; nothing to move.
            return 0
        }
        if ($Direction -eq 'Upload') {
            $src = $WorkPath; $dst = $StorePath
        } else {
            $src = $StorePath; $dst = $WorkPath
        }
        return (& $script:UsmtRobocopyScript $src $dst $File $options)
    }

    # --- Remote: pick a method ---
    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        throw 'Copy-MigStore requires -ComputerName for remote (session) transfers.'
    }
    $method = Resolve-UsmtTransferMethod -TransferMethod $TransferMethod `
        -Session $Session -ComputerName $ComputerName -StorePath $StorePath

    if ($method -eq 'AdminShare') {
        # Caller-side robocopy over the remote's C$ admin share.
        $workUnc = ConvertTo-UsmtAdminSharePath -ComputerName $ComputerName -LocalPath $WorkPath
        if ($Direction -eq 'Upload') {
            $src = $workUnc; $dst = $StorePath
        } else {
            $src = $StorePath; $dst = $workUnc
        }
        return (& $script:UsmtRobocopyScript $src $dst $File $options)
    }

    # SessionPushPull: robocopy executed inside the session (the remote reaches
    # the store itself via its own second hop).
    if ($Direction -eq 'Upload') {
        $src = $WorkPath; $dst = $StorePath
    } else {
        $src = $StorePath; $dst = $WorkPath
    }
    # Fail closed: a dropped session must not return $null here - that would coerce
    # to robocopy exit 0 and read as a successful copy. Force the remote call to
    # throw, and map a lost session or a missing result to robocopy's "serious
    # error" code (16, >= 8) so the caller's Test-UsmtRobocopyOk treats it as a
    # failed copy (fatal for a store transfer, a WARN for a best-effort log push).
    try {
        $rc = Invoke-Command -Session $Session -ScriptBlock $script:UsmtRobocopyScript `
            -ArgumentList $src, $dst, $File, $options -ErrorAction Stop
    } catch {
        # Preserve the cause so the fail-closed mapping stays diagnosable - an
        # opaque exit 16 alone reads the same as a genuine robocopy failure.
        Write-Warning "robocopy did not complete on the remote machine - the session was lost or the command was aborted ($($_.Exception.Message)). Mapping to robocopy failure code 16."
        return 16
    }
    if ($null -eq $rc) { return 16 }
    return $rc
}

#endregion

#region scanstate / loadstate

# Core scanstate runner (executes on the subject machine, local or in-session).
$script:UsmtScanStateScript = {
    param($BinPath, $StorePath, $IncludeXml, $ExcludeXmlPath, $Verbosity, $IncludeUser, $SkipStaleProfileDays)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $StorePath)) {
        New-Item -Path $StorePath -ItemType Directory -Force | Out-Null
    }
    $exe = Join-Path $BinPath 'scanstate.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "scanstate.exe not found at '$exe'."
    }

    $listLog = Join-Path $StorePath 'list_all.log'
    $scanLog = Join-Path $StorePath 'scan_all.log'
    $progLog = Join-Path $StorePath 'prog_all.log'

    $a = @($StorePath, '/o', '/vsc', '/localonly')
    foreach ($x in @($IncludeXml))     { if ($x) { $a += "/i:$x" } }
    foreach ($x in @($ExcludeXmlPath)) { if ($x) { $a += "/i:$x" } }
    $a += "/v:$Verbosity"
    if (@($IncludeUser).Count -gt 0) {
        # Exclude everyone, then re-include only the named users.
        $a += '/ue:*\*'
        foreach ($u in @($IncludeUser)) { if ($u) { $a += "/ui:$u" } }
    }
    if ($SkipStaleProfileDays -gt 0) {
        $a += "/uel:$SkipStaleProfileDays"
    }
    $a += @("/listfiles:$listLog", "/l:$scanLog", "/progress:$progLog", '/c')

    Write-Host "Running scanstate on $env:COMPUTERNAME -> $StorePath"
    Push-Location $BinPath
    try {
        # Pipe the native output to the host so it is shown/transcribed but does
        # NOT pollute the return value - only the exit code must flow back.
        & $exe @a | Out-Host
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

# Core loadstate runner (executes on the subject machine, local or in-session).
$script:UsmtLoadStateScript = {
    param($BinPath, $StorePath, $IncludeXml, $Verbosity, $IncludeUser, $CreateLocalAccount, $EnableLocalAccount)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $exe = Join-Path $BinPath 'loadstate.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "loadstate.exe not found at '$exe'."
    }

    $loadLog = Join-Path $StorePath 'load_all.log'
    $progLog = Join-Path $StorePath 'prog_load_all.log'

    $a = @($StorePath)
    foreach ($x in @($IncludeXml)) { if ($x) { $a += "/i:$x" } }
    $a += "/v:$Verbosity"
    # SECURITY: when a local account in the store does not exist on the target,
    # /lac recreates it with a BLANK PASSWORD and /lae enables it - i.e. an
    # unsecured, immediately logon-able account. That blank-password exposure (not
    # the recreation itself) is why both are opt-in and OFF by default, added only
    # on explicit request. Domain accounts are never created by /lac. /lae requires
    # /lac; the caller (Restore-UserState) enforces that invariant before we get here.
    if ($CreateLocalAccount) { $a += '/lac' }
    if ($EnableLocalAccount) { $a += '/lae' }
    if (@($IncludeUser).Count -gt 0) {
        $a += '/ue:*\*'
        foreach ($u in @($IncludeUser)) { if ($u) { $a += "/ui:$u" } }
    }
    $a += @("/progress:$progLog", "/l:$loadLog", '/c')

    Write-Host "Running loadstate on $env:COMPUTERNAME <- $StorePath"
    Push-Location $BinPath
    try {
        # Pipe the native output to the host so it is shown/transcribed but does
        # NOT pollute the return value - only the exit code must flow back.
        & $exe @a | Out-Host
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

function Get-UsmtRemoteExitCode {
    <#
    .SYNOPSIS
        Runs a scanstate/loadstate scriptblock (local or in a remote session) and
        returns its integer exit code, treating a lost or aborted run as a failure
        rather than a spurious success.

    .DESCRIPTION
        Each runner scriptblock ends with `return $LASTEXITCODE` - a single integer.
        When a remote session drops mid-run (target reboot, network loss, crash),
        Invoke-Command either throws or returns nothing, and a $null result silently
        coerces to 0 - which the caller would otherwise report as a clean success on
        a store or restore that never actually finished. This wrapper converts both
        cases (a thrown remoting error, or a missing/non-numeric result) into a clear
        terminating error so the caller fails loudly.

    .PARAMETER Operation
        'scanstate' or 'loadstate', used only in error messages.

    .PARAMETER Session
        Remote session, or $null to run locally.

    .PARAMETER ScriptBlock
        The runner scriptblock to execute.

    .PARAMETER ArgumentList
        Positional arguments for the scriptblock.

    .OUTPUTS
        [int] The validated process exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param (
        [Parameter(Mandatory)]
        [string]$Operation,

        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @()
    )

    if ($Session) {
        try {
            $result = Invoke-Command -Session $Session -ScriptBlock $ScriptBlock `
                -ArgumentList $ArgumentList -ErrorAction Stop
        } catch {
            throw "$Operation did not complete on the remote machine - the session was lost or the command was aborted ($($_.Exception.Message)). No trustworthy exit code was returned; treating this as a failure."
        }
    } else {
        $result = & $ScriptBlock @ArgumentList
    }

    # A finished run yields exactly one integer (the process exit code). $null, an
    # empty result, or a non-integer means the run did not complete - never let that
    # coerce to 0 and masquerade as success.
    $codes = @($result | Where-Object { $null -ne $_ })
    if ($codes.Count -eq 0) {
        throw "$Operation returned no exit code (the session may have dropped mid-run). Treating this as a failure rather than a success."
    }
    $last = $codes[-1]
    $parsed = 0
    if (-not [int]::TryParse([string]$last, [ref]$parsed)) {
        throw "$Operation returned a non-numeric result '$last' instead of an exit code. Treating this as a failure."
    }
    return $parsed
}

function Invoke-UsmtScanState {
    <#
    .SYNOPSIS
        Runs scanstate on the subject machine (local or over a session).
    .DESCRIPTION
        Always captures with /o (overwrite), /vsc (shadow copy for locked files),
        /localonly, and /c (continue on non-fatal errors) - the settings the
        lessons in DESIGN.md require. Returns the scanstate exit code.
    .PARAMETER Session
        Remote session, or $null for local.
    .PARAMETER BinPath
        Directory containing scanstate.exe on the subject machine.
    .PARAMETER StorePath
        Working store path on the subject machine (logs are written beside it).
    .PARAMETER IncludeXml
        Built-in migration XML names (resolved relative to BinPath).
    .PARAMETER ExcludeXmlPath
        Full paths to exclude-rule XMLs on the subject machine.
    .PARAMETER Verbosity
        scanstate /v level.
    .PARAMETER IncludeUser
        Explicit users to capture; empty = all local profiles.
    .PARAMETER SkipStaleProfileDays
        Opt-in /uel:N; 0 = capture all users including dormant ones.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param (
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [string]$BinPath,

        [Parameter(Mandatory)]
        [string]$StorePath,

        [string[]]$IncludeXml = @('MigDocs.xml', 'MigApp.xml', 'MigAppData.xml'),

        [string[]]$ExcludeXmlPath = @(),

        [int]$Verbosity = 13,

        [string[]]$IncludeUser = @(),

        [int]$SkipStaleProfileDays = 0
    )

    return (Get-UsmtRemoteExitCode -Operation 'scanstate' -Session $Session `
        -ScriptBlock $script:UsmtScanStateScript `
        -ArgumentList @($BinPath, $StorePath, $IncludeXml, $ExcludeXmlPath, $Verbosity, $IncludeUser, $SkipStaleProfileDays))
}

function Invoke-UsmtLoadState {
    <#
    .SYNOPSIS
        Runs loadstate on the subject machine (local or over a session).
    .DESCRIPTION
        Restores with /c (continue on non-fatal errors). Local-account creation
        (/lac) and enabling (/lae) are opt-in - off unless the caller requests
        them - because /lac creates accounts with a blank password. Exclude rules
        are intentionally NOT applied at restore - the store already excludes that
        content at capture. Returns the loadstate exit code.
    .PARAMETER Session
        Remote session, or $null for local.
    .PARAMETER BinPath
        Directory containing loadstate.exe on the subject machine.
    .PARAMETER StorePath
        Working store path on the subject machine (logs are written beside it).
    .PARAMETER IncludeXml
        Built-in migration XML names (resolved relative to BinPath).
    .PARAMETER Verbosity
        loadstate /v level.
    .PARAMETER IncludeUser
        Explicit users to restore; empty = all profiles in the store.
    .PARAMETER CreateLocalAccount
        Add /lac to create missing local accounts (blank password). Default $false.
    .PARAMETER EnableLocalAccount
        Add /lae to enable /lac-created accounts. Requires CreateLocalAccount
        (enforced by the caller). Default $false.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param (
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory)]
        [string]$BinPath,

        [Parameter(Mandatory)]
        [string]$StorePath,

        [string[]]$IncludeXml = @('MigDocs.xml', 'MigApp.xml', 'MigAppData.xml'),

        [int]$Verbosity = 13,

        [string[]]$IncludeUser = @(),

        [bool]$CreateLocalAccount = $false,

        [bool]$EnableLocalAccount = $false
    )

    # USMT: /lae is only valid with /lac. Enforce it here too (not just in
    # Restore-UserState) since this function is exported and callable directly.
    if ($EnableLocalAccount -and -not $CreateLocalAccount) {
        throw "EnableLocalAccount requires CreateLocalAccount (USMT /lae requires /lac)."
    }

    return (Get-UsmtRemoteExitCode -Operation 'loadstate' -Session $Session `
        -ScriptBlock $script:UsmtLoadStateScript `
        -ArgumentList @($BinPath, $StorePath, $IncludeXml, $Verbosity, $IncludeUser, $CreateLocalAccount, $EnableLocalAccount))
}

#endregion

Export-ModuleMember -Function `
    Test-UsmtLocalComputer, `
    New-UsmtSession, `
    ConvertTo-UsmtAdminSharePath, `
    Test-UsmtXmlFile, `
    Copy-UsmtBinary, `
    Test-UsmtRobocopyOk, `
    Get-UsmtExitDisposition, `
    Test-UsmtRemoteWrite, `
    Resolve-UsmtTransferMethod, `
    Copy-MigStore, `
    Invoke-UsmtScanState, `
    Invoke-UsmtLoadState
