# PowerShell 7 only hosts

Windows servers where policy blocks Windows PowerShell 5.1 and allows only
PowerShell 7 are fully supported. One codebase still runs on both; the
host is chosen, never assumed.

## Scope
- Spec: "PowerShell 7 only" as an explicit supported mode.
- CI job with `powershell.exe` blocked, running every Windows test on pwsh,
  so any hidden dependency on 5.1 fails the build.
- Examples and README offer a `pwsh` runner for `.ps1` beside `powershell.exe`.
- PowerShell 7 requirements listed (7.3+ for `ca_file`).

## Done when
- The blocked-5.1 CI job passes; docs updated.
