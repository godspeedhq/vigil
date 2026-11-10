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

## Built (2026-11-10)

As proposed, with one change: the message names the first folder or file
this account cannot read, from the root down, rather than always the root.
On both Windows test machines that is `logs`:

```
service: unknown (NSSM, system mode)
vigil: cannot read C:\ProgramData\Vigil\logs from this account: run vigil status from an elevated prompt for a system install
```

(This branch's `app`, run as `vigil-test` against the 0.6.4 system install
on the Windows 11 test machine and on the Server 2016 VM; exit code 1.
`service: unknown` is because SSH sessions there may not ask the Service
Control Manager; from a local prompt it shows the state.)

- **The parser:** `Test-Path` on the configuration runs with
  `-ErrorAction Stop`, and "Access is denied" becomes `E_FILE_UNREADABLE`.
  That quiets every command that reads the configuration from such an
  account, not only `status`.
- **`status`:** checks the root, the log folder, `logs/supervisor` and
  `jobs.log` (Windows: lists each folder, since .NET calls what is inside a
  closed folder missing), and stops with the message on stderr, exit 1.
- **Tests:** `Supervise.ps1` denies read on `logs\supervisor`, then on
  `config` (precheck says `config file not readable`, status still shows
  `jobs.log`, no PowerShell error); `supervise.sh` makes `logs/supervisor`
  `chmod 000` (skipped as root). The six new Windows checks fail on 0.6.4
  and pass here. `supervise.sh` 30/30 on Fedora 44 (bash 5.3) and macOS 12
  (bash 3.2 and 5.2); `Supervise.ps1` 34/34, `Precheck.ps1` 34/34,
  `Config-Edit.ps1` 40/40 and `Service.ps1` 33/33 in Windows PowerShell 5.1.
