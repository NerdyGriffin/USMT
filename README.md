# USMT Toolkit

A config-driven PowerShell wrapper around Microsoft's User State Migration Tool
(USMT) for full-machine user-state backup and restore. Local by default,
remote-capable over PSRemoting, domain-agnostic, and self-contained.

Clone → `Setup.ps1` → migrate. See [DESIGN.md](DESIGN.md) for the full rationale.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ (both supported).
- Administrator rights on the machine being captured/restored.
- For remote runs: WinRM/PSRemoting enabled on the target, and local-admin rights
  on it. See [Remote runs and the double hop](#remote-runs-and-the-double-hop).

## Quick start

```powershell
# 1. Acquire the USMT binaries and create your config (interactive, re-runnable):
.\Setup.ps1

# 2. Back up all local user profiles into the configured store:
.\Backup-UserState.ps1

# 3. Restore that store (e.g. onto a freshly imaged machine):
.\Restore-UserState.ps1 -MigStoreName <StoreName>
```

USMT binaries are not redistributable, so `Setup.ps1` acquires them (from the
Windows ADK, or from a pre-staged copy via `-AdkOffline <path>`).

## Usage

Local is the default. Supplying a computer name activates the remote path;
scanstate/loadstate always run **on** the subject machine either way.

```powershell
# Remote backup of a named machine (PSRemoting):
.\Backup-UserState.ps1 -SourceComputer PC-OLD

# Restore a store onto a remote machine, overriding the store root inline:
.\Restore-UserState.ps1 -TargetComputer PC-NEW -MigStoreName PC-OLD `
    -MigStoreNetworkPath \\fileserver\share\USMT\MigStore

# Run a saved job definition:
.\Backup-UserState.ps1 -JobConfig .\Config\pc-old.Migration.psd1

# Capture specific users only:
.\Backup-UserState.ps1 -Users 'CONTOSO\jsmith','CONTOSO\ajones'
```

Every entry point supports `-WhatIf`, `-Verbose`, and comment-based help
(`Get-Help .\Backup-UserState.ps1 -Full`).

## Configuration

Behavior comes from PSD1 config files; **any command-line parameter overrides its
configured value for that run**. Resolution order:

> command-line parameter **>** job config **>** global config **>** built-in default

Copy the committed templates and edit (Setup.ps1 creates the global file for you).
Real config files are gitignored — environment identity never lands in tracked
files. **Never put credentials in a config file**; pass `-Credential` at runtime.

### Global — `Config/Settings.psd1`

| Key | Purpose | Default |
| --- | --- | --- |
| `MigStoreMode` | `Local` or `Network` | `Local` |
| `MigStoreLocalPath` | local store root | `<repo>\MigStore` |
| `MigStoreNetworkPath` | UNC store root | *(blank = Local only)* |
| `UsmtBinPath` | where the amd64 binaries live | `<repo>\amd64` |
| `LogRoot` | transcript/log directory | `<repo>\Logs` |
| `RemoteStagingPath` | working dir created on remote machines | `C:\USMT` |
| `TransferMethod` | `Auto`, `AdminShare`, `SessionPushPull` | `Auto` |
| `DefaultExcludeRules` | exclude-rule XML names always applied | `@()` |
| `Verbosity` | scanstate/loadstate `/v` level | `13` |

### Per-job — `Config/<name>.Migration.psd1`

| Key | Purpose |
| --- | --- |
| `SourceComputer` / `TargetComputer` | remote machine(s); absent = localhost |
| `Users` | `All` (default) or an explicit list → `/ui` + `/ue:*\*` |
| `ExcludeRules` | job-specific rule XMLs (extends `DefaultExcludeRules`) |
| `SkipStaleProfileDays` | opt-in `/uel:N`; absent/0 = capture **all** users |
| `MigStoreName` | store subfolder; default = source computer name |

## Exclude rules

Shipped `ExcludeRules/*.xml` are generic and safe to apply:

- **`ExcludeDefender.xml`** — drops the tamper-protected Defender ProgramData tree
  (unwritable at restore; recommended in every migration).
- **`ExcludeBulkData.xml`** — drops regenerable per-user caches, with commented
  examples for game libraries and cloud-sync folders you can adapt.

Add them to `DefaultExcludeRules`, or per-job `ExcludeRules`, by file name. Custom
rule XML is **validated before** scanstate launches, so a malformed rule fails fast
instead of costing a full run.

Per-user exclusions must use CSIDL variables (`%CSIDL_PROFILE%`,
`%CSIDL_LOCAL_APPDATA%`) in a `context="User"` component — literal `C:\Users\*\...`
paths silently match nothing. And XML comments must never contain a double hyphen.

## Remote runs and the double hop

Remote runs execute scanstate/loadstate on the subject machine and transfer the
store per `TransferMethod`. `Auto` probes, in order:

1. **AdminShare** — the caller robocopies over the remote's `C$` admin share.
   Works when the remote allows inbound SMB.
2. **SessionPushPull** — robocopy runs inside the remote session, so the remote
   reaches the file share itself. This is a **second hop**: the remote must
   authenticate to the share from within a remote session, which Kerberos does not
   forward by default. It is probed with a throwaway test write before any large
   transfer.
3. **Fail with diagnostics** — a structured error naming exactly which probe failed.

The store is always moved with `robocopy` (resumable; success = exit code `< 8`),
never `Copy-Item -To/-FromSession`, which trips a PowerShell bug on large trees.

**The toolkit detects and reports the second-hop situation but does not configure
it** — that is a security-policy decision. Environments solve it with resource-based
constrained delegation (RBCD), classic constrained delegation, CredSSP, or a
storage design that avoids the hop. See Microsoft's guidance on
[making the second hop in PowerShell Remoting](https://learn.microsoft.com/powershell/scripting/learn/remoting/ps-remoting-second-hop).

## Layout

```
Setup.ps1              acquire binaries + interactive config
Backup-UserState.ps1   scanstate pipeline (local or -SourceComputer)
Restore-UserState.ps1  loadstate pipeline (local or -TargetComputer)
Modules/               UsmtConfig, UsmtLogging, UsmtCore
Config/                Example.*.psd1 templates (real *.psd1 gitignored)
ExcludeRules/          generic exclude-rule XML
Legacy/                pre-toolkit scripts, kept as reference (see DESIGN.md)
amd64/ MigStore/ Logs/  binaries, stores, logs (gitignored)
```

## Notes

- `MigDocs.xml` scans **every fixed drive**, not just profiles; detach or exclude
  foreign data drives before capture.
- LoadState applies settings even for apps not installed on the target (they lie
  dormant); most restore warnings are LNK-resolution / 8.3-name noise, not data loss.
- Reboot the target after a restore so shell/IE/etc. settings take effect.
