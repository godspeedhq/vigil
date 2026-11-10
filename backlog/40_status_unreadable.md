# 40. status: say when the install cannot be read

Found on 2026-11-10 while installing Vigil on a Windows Server 2016 test VM;
the owner asked for this backlog and the fix.

## The problem

Run as an ordinary account against a system install on Windows (both the
Server 2016 VM and the Windows 11 test machine, Vigil 0.6.4), `vigil status`
prints:

```
Test-Path : Access is denied
At C:\ProgramData\Vigil\app\lib\windows\Config.ps1:63 char:15
+     if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
...
service: unknown (NSSM, system mode)

Test-Path : Access is denied
...
no jobs.log yet: the supervisor writes it every tick
```

Two things are wrong:

- **Raw PowerShell errors.** A system install's root is closed to all but
  SYSTEM and Administrators, and `Test-Path` on the configuration throws
  "Access is denied" instead of answering. The configuration parser lets
  that through, so any command that reads the configuration from such an
  account shows it.
- **"no jobs.log yet" is untrue.** The supervisor writes `jobs.log` every
  tick; this account just cannot see it. It is the same kind of mistake as
  backlog 39's "none is here".

On Linux and macOS the usual system install leaves `config/` and `logs/`
readable, so `vigil status` works from any account. A `logs/` the account
cannot read would give the same untrue line there.

## Proposed

- **The configuration parser** (Windows) reports a configuration it is not
  allowed to look at as `E_FILE_UNREADABLE` (`config file not readable`),
  as Linux and macOS already do, never as a PowerShell error.
- **`vigil status`** first prints the service line as now. Then, when this
  account cannot read the install (the root on Windows; the log folders and
  `jobs.log` on all three), it says so instead of showing `jobs.log`:
  `cannot read <root> from this account: run vigil status from an elevated
  prompt for a system install` on Windows, and `... run it as the account
  that installed Vigil (sudo for a system install)` on Linux and macOS. It
  exits 1, since it could not show what was asked.
- `no jobs.log yet` stays for a root that can be read and has no `jobs.log`.

## Done when

- The message above, with no PowerShell error, on the Windows test machine
  and the Server 2016 VM, as `vigil-test`.
- Integration tests on both shells cover a log folder the account cannot
  read.
- Specification §16 (the `status` row) says so.
