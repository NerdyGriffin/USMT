# USMT Toolkit — Design

Design for generalizing this repo's ad-hoc USMT scripts into a polished, reusable,
community-friendly toolkit. Captures all decisions made 2026-07-03; intended as the
handoff artifact for implementation.

## Goals

- **Clone → `Setup.ps1` → migrate.** A fresh user on a fresh deployment can clone the
  repo, run one setup script, answer a few prompts, and start backing up / restoring
  user state.
- **Config-driven with inline override.** Behavior comes from PSD1 config files;
  any script parameter overrides its config value for that run.
- **Local-first, remote-capable.** Every operation runs against the local machine by
  default; supplying a computer name activates the remote (PSRemoting) path.
- **Domain-agnostic and self-contained.** No dependency on any private repo or
  environment-specific module. All environment identity (share paths, hostnames)
  lives in gitignored config, never in tracked files.
- **Bake in the hard-won lessons** (see [Lessons encoded in the design](#lessons-encoded-in-the-design)).

## Non-goals

- Redistributing USMT binaries (not licensable — `Setup.ps1` acquires them).
- Wrapping every USMT feature. This is a pragmatic pipeline for the common cases:
  full-machine backup, full-machine restore, and (v2) same-machine user rename.
- Prescribing a double-hop/delegation strategy (see [Transfer abstraction](#transfer-abstraction)).

## Repository layout

```
USMT/
  Setup.ps1                       # acquire amd64 binaries + interactive config creation
  Backup-UserState.ps1            # scanstate pipeline (local or -SourceComputer)
  Restore-UserState.ps1           # loadstate pipeline (local or -TargetComputer)
  DESIGN.md                       # this file
  Modules/
    UsmtConfig.psm1               # PSD1 load/merge, param>job>global>default resolution
    UsmtLogging.psm1              # transcripts + timestamped Write-Log, log rotation
    UsmtCore.psm1                 # sessions, transfer abstraction, scanstate/loadstate invocation
  Config/
    Example.Settings.psd1         # committed template — global settings
    Example.Migration.psd1        # committed template — per-job settings
    Settings.psd1                 # real global config   (gitignored)
    *.Migration.psd1              # real job configs      (gitignored)
  ExcludeRules/
    ExcludeBulkData.xml           # committed, generic exclude rule sets
    ...
  Legacy/
    (pre-toolkit scripts: Migrate_*.ps1, ScanState_*.ps1, LoadState_*.ps1,
     CloneUSMT.ps1, LocalUserMigration.ps1 — kept as working reference for the
     v2 user-rename feature; delete once v2 ships)
  amd64/                          # USMT binaries (gitignored; populated by Setup.ps1)
  MigStore/                       # default local store root (gitignored)
  Logs/                           # transcripts + logs (gitignored)
```

Naming follows PowerShell conventions: `Modules/` (not `lib/`), approved verbs
(`Backup-`, `Restore-` are approved), Verb-Noun script names.

## Configuration

Two tiers of PSD1 files. **Resolution order: command-line parameter > job config >
global config > built-in default.** `Setup.ps1` creates the global file; job files are
optional (all job settings can be given as parameters).

PSD1 chosen over JSON: idiomatic for a pure-PowerShell public tool, supports comments,
parses natively on 5.1 (`Import-PowerShellDataFile`).

### Global — `Config/Settings.psd1`

| Key | Purpose | Default when blank/absent |
| --- | --- | --- |
| `MigStoreMode` | `Local` or `Network` | `Local` |
| `MigStoreLocalPath` | local store root | `<repo>\MigStore` |
| `MigStoreNetworkPath` | UNC store root (e.g. `\\fileserver\share\USMT\MigStore`) | *(blank = Local only)* |
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
| `Users` | `All` (default) or explicit list → `/ui` + `/ue:*\*` |
| `OldUser` / `NewUser` | v2 — same-machine rename via `/mu` |
| `ExcludeRules` | job-specific rule XMLs (extends `DefaultExcludeRules`) |
| `SkipStaleProfileDays` | opt-in `/uel:N`; **absent/0 = capture all users** |
| `MigStoreName` | store subfolder; default = source computer name |

No credentials in config files, ever. `-Credential` is an optional runtime parameter
passed through to all PSSessions; default is the caller's Kerberos token.

## Entry points and parameter design

**Local is the default.** Remote tooling activates only when a computer parameter is
supplied — no `-Local` switch exists:

```powershell
# Local backup of all users into the configured store:
.\Backup-UserState.ps1

# Remote backup (PSRemoting) of a named machine:
.\Backup-UserState.ps1 -SourceComputer PC-OLD

# Restore that store onto a remote machine, overriding the store root inline:
.\Restore-UserState.ps1 -TargetComputer PC-NEW -MigStoreName PC-OLD `
    -MigStoreNetworkPath \\fileserver\share\USMT\MigStore

# Run a saved job definition:
.\Backup-UserState.ps1 -JobConfig .\Config\pc-old.Migration.psd1
```

Both scripts: `[CmdletBinding(SupportsShouldProcess)]`, comment-based help, parameters
mirroring every job-config key (parameter wins). Remote path: one `New-PSSession`
reused for all steps; binaries pushed with `Copy-Item -ToSession` (small payload only);
scanstate/loadstate always execute **on** the machine being captured/restored, writing
to `RemoteStagingPath`, with the store transferred per the abstraction below.

## Transfer abstraction

`UsmtCore.psm1` exposes `Copy-MigStore` (and a mirror for logs). With
`TransferMethod = Auto` it probes, in order:

1. **AdminShare** — caller-side `robocopy \\<computer>\C$\... <store>` (or reverse).
   Works when the remote allows inbound SMB. Cheap probe: `Test-Path` on the share.
2. **SessionPushPull** — `robocopy` executed *inside* the PSSession, so the remote
   machine pushes (backup) or pulls (restore) against the network store itself.
   Requires the remote's second hop to the file share to succeed — probed with a
   **throwaway test write** to the store before committing to a 100+ GB transfer.
3. **Fail with diagnostics** — a structured error stating exactly which probes failed
   and why (inbound SMB blocked; second-hop auth failed), pointing at the double-hop
   documentation below.

Never `Copy-Item -FromSession/-ToSession` for the store: it fails on large trees with
"The property 'Length' cannot be found on this object", and robocopy is resumable.

**Double-hop stance:** method 2 requires the remote machine to authenticate to the
file share from within a remote session. Environments solve this differently — RBCD,
classic constrained delegation, CredSSP, or storage designs that avoid the hop — and
the right choice is a security-policy decision. The toolkit therefore *detects and
reports* (test write) but does **not** configure or recommend a specific mechanism;
docs link to Microsoft's "second hop in PowerShell Remoting" article and enumerate
the options neutrally.

`robocopy` success = exit code `< 8`; treat `>= 8` as failure and surface the code.

## Setup.ps1

1. **Acquire binaries.** If `amd64\scanstate.exe` is missing: download the Windows ADK
   (winget or the official bootstrapper URL), install only the USMT feature, copy
   `amd64` into the repo, optionally uninstall the ADK afterward. `-AdkOffline <path>`
   accepts a pre-installed ADK or pre-copied folder for air-gapped hosts. If binaries
   already exist: report the found version (`scanstate.exe` file version), report the
   latest available where detectable (best-effort — ADK versioning is not reliably
   queryable without downloading; skip gracefully), and **ask before overwriting**.
2. **Interactive config.** If `Config\Settings.psd1` exists: `"Existing config
   detected. Reconfigure? (y/N)"`. During prompting, print one explainer line first —
   `"Press Enter to accept the value shown in parentheses."` — then each prompt uses
   the CLI-standard form `Prompt text (current_or_default_value): `. Blank-able keys
   (e.g. `MigStoreNetworkPath`) accept empty to skip the feature. Writes
   `Config\Settings.psd1` (gitignored).
3. **Idempotent.** Re-runnable at any time; only fills gaps unless the user opts to
   overwrite/reconfigure.

## Logging

`UsmtLogging.psm1`, self-contained (no external module deps):

- `Start-Transcript` wrapper for each entry-point run.
- `Write-Log` with ISO-8601 timestamps (`Get-Date -Format s`) mirroring to console.
- Log filename convention: `<script>.<COMPUTERNAME>.<FileDateTime>.log` under
  `LogRoot`; simple retention/rotation helper.
- USMT's own logs (`scan_*.log`, `list_*.log`, `prog_*.log`, `load_*.log`) are kept
  beside the store in the MigStore subfolder, as today.

## Compatibility

- **Windows PowerShell 5.1 and PowerShell 7+.** 5.1 is what ships in-box on Windows
  and is the default runtime for many built-in tools, so it is a hard floor: no `??`,
  `?.`, ternary, or other 7+-only syntax; two-argument `Join-Path` nesting.
- Lint with PSScriptAnalyzer; 4-space indent; no aliases; `#region` organization.

## Lessons encoded in the design

Findings from the 2026-07 GC0→WIN-GC4 migration that the toolkit must institutionalize:

1. **Per-user exclude rules must use CSIDL variables in a `context="User"` component**
   (`%CSIDL_LOCAL_APPDATA%`, `%CSIDL_PROFILE%`). Literal `C:\Users\*\...` patterns
   silently match nothing. Shipped `ExcludeRules/*.xml` follow this; docs call it out.
2. **XML comments cannot contain `--`.** All shipped rule files are validated; the
   pipeline pre-validates any custom rule XML with `System.Xml.XmlDocument` *before*
   launching scanstate (a parse error otherwise costs a full run → USMT error 29).
3. **`MigDocs.xml` scans every fixed drive** (all non-`%ProgramFiles%` locations) —
   it is not profile-scoped, and `/localonly` means "not network," not "local users."
   Docs warn to unmount/detach foreign data drives or exclude their content.
4. **Exclude Defender's ProgramData tree.** `C:\ProgramData\Microsoft\Windows
   Defender\*` is tamper-protected and unwritable at restore (hundreds of would-be
   fatal errors absorbed by `/c`); a shipped System-context rule excludes it at capture.
5. **`/uel` silently drops dormant users.** Off by default (`SkipStaleProfileDays`
   opt-in) so "back up all users" means all users.
6. **LoadState applies settings even for apps not installed on the target** (they lie
   dormant); warnings are usually LNK-resolution and 8.3-short-name noise, not data
   loss. The restore summary should classify warning clusters rather than alarm on
   raw counts.
7. Always run scanstate/loadstate **on** the subject machine (PSRemoting), never
   against a UNC store directly from the controller — and always `/vsc` for
   locked-file capture, `/c` with post-run error-summary review.

## Scope

### v1
- `Setup.ps1` (binaries + interactive global config, re-run UX as specified)
- `Modules/` (UsmtConfig, UsmtLogging, UsmtCore with transfer abstraction)
- `Backup-UserState.ps1`, `Restore-UserState.ps1` — local + remote
- Committed `Config/Example.*.psd1` templates and generic `ExcludeRules/*.xml`
- Existing scripts moved to `Legacy/`
- README rewrite: quick start, config reference, double-hop guidance (neutral)

### v2
- Same-machine user rename (`OldUser`/`NewUser` → `/mu`), replacing
  `Legacy/LocalUserMigration.ps1` and friends (then delete `Legacy/`)
- Setup.ps1 binary up-to-date detection improvements
- Restore-summary warning classifier (lesson 6)

### Deferred (post-v2)
- **Modular exclude-rule profiles** users can mix and match (e.g. `gaming`,
  `minimal`, `cloud-synced`). Requires a design pass over rule granularity first.
- Pre-commit name-policy hooks: the candidate hook engine lives in a **private**
  repo today, so it cannot be a subtree here. Options: make that repo public first,
  or skip hooks and rely on review. **Open question.**

## Git / branching

- Default branch `main`; active development on `dev-latest`; implementation happens
  on a feature branch off `dev-latest` (e.g. `feature/usmt-toolkit`).
- Existing public history keeps its old environment-specific names (accepted;
  long-since public). All **new** tracked content is generic — real values go only
  in gitignored config. This file uses placeholder names for that reason.

## Open questions

1. Name-policy hook adoption (blocked on making the hook engine repo public).
2. Best-effort "is the ADK/USMT version current?" check in Setup.ps1 — investigate
   winget manifest metadata as a version oracle during v1; degrade gracefully.
3. v2 rename entry point name — candidate: `Move-UserProfile.ps1` (approved verb)
   vs. a `-Rename` mode on the existing scripts. Decide at v2 kickoff.
