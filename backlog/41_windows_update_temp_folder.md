# 41. Windows: what SYSTEM verifies and runs stays where only it can write

Found in the engineering-challenges review of 2026-11-10 (challenge 2.2,
[the review](reviews/2026-11-10_engineering_challenges.md)).

## The problem

**The config-driven update runs as SYSTEM in the machine's temporary folder.**
On a Windows system install, the supervisor's `vigil_update` worker
(`Invoke-VigilUpdate`, `app/lib/windows/SelfUpdate.ps1`) starts
`vigil self update --from-config` with the service's environment, so as
LocalSystem with `TEMP` = `C:\Windows\Temp`. Then:

- `Invoke-VigilSelfUpdate` downloads `install.ps1`, the archive and
  `SHA256SUMS` into `GetTempPath()\vigil-update.$PID`, made with
  `New-Item -Force`, checks them, and runs `install.ps1`;
- `install.ps1` verifies the archive in `GetTempPath()\vigil-install.$PID`,
  also made with `-Force`, expands it to `x\` and copies from there.

Any account can create folders in `C:\Windows\Temp`. One that creates
`vigil-install.<n>` first, with an inheritable Everyone:FullControl entry,
keeps write access to everything Vigil puts in it. `-Force` reuses the folder
without complaint. Between verification and the copy it can swap files, and
they run as SYSTEM: a local privilege escalation through a race. The reviewer
showed that an unelevated account can create folders there and that
`New-Item -Force` silently reuses one, with planted files intact; the full
race as SYSTEM was not run.

The scheduled task behind `-UpdateBy` already avoids this
(`Invoke-VigilSelfUpdateTask` points `TEMP`/`TMP` at `update\work` under the
locked root), and SPECIFICATION.md §18.7 says why: "not the machine's
temporary folder, where any account can create files". The supervisor's path
was missed. Under PowerShell 7 (`-ShellHost pwsh`), .NET gives SYSTEM its own
`C:\Windows\SystemTemp`, so it is the Windows PowerShell 5.1 host, the
default, that is exposed. Linux and macOS use `mktemp -d` and are not
affected.

**Related: the root is locked only with a service.** `Set-VigilRootAcl`
(SYSTEM and Administrators only) is called when the service is registered
and for `-UpdateBy`. `install.ps1 -System -NoService`, or an install whose
pre-flight fails, leaves `C:\ProgramData\Vigil` with ProgramData's own
permissions, where Users may create files and folders, and what they create
stays theirs after a later lock.

## Proposed

- `Invoke-VigilUpdate` sets the child's `TEMP` and `TMP` to a folder under
  the root, made fresh each time (as the task does), and both temporary
  folders are created without `-Force`, failing if one already exists.
- `install.ps1 -System` locks the root as soon as it creates it, with or
  without a service.

## Done when

- An integration test shows the config-driven update's work folders are
  under the root, not `TEMP`.
- `install.ps1 -System -NoService` leaves the root SYSTEM and Administrators
  only.
- SPECIFICATION.md §18.7 / §18.11 say so for both paths.
