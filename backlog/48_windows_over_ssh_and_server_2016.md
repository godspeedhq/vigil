# 48. Windows over SSH, and Server 2016's first run

Found on 2026-11-11, recording Server 2016 for backlog 47: every Windows
suite run as an ordinary account over SSH, on the Server 2016 VM and, to
tell the version from the session, on the Windows 11 machine. The VM's
whole run is in `tests/integration/backends/reports/windows-compatibility.md`.

## 1. A secret cannot be set over SSH, and Vigil only says "Access is denied"

`vigil secret set` encrypts with DPAPI, for the account. Windows refuses
DPAPI to a logon that carries no password: an SSH key, a scheduled task
without a stored password. Over SSH with a key, on Windows 11 and on Server
2016 alike:

```
> 'v' | vigil secret set FOO --stdin
vigil: Access is denied.
```

`ConvertFrom-SecureString` is what is refused (`Set-Acl` on the store is
not). Reading a secret over SSH fails the same way, so a run or `vigil
precheck` started from SSH says `cannot be decrypted by this account on this
machine`, which sends you to set it again. That is also why `Precheck.ps1`
fails 7 or 8 checks over SSH on both machines, and `Secrets.ps1` stops at
its first `secret set`. A service running as LocalSystem, or anyone at the
console, is not affected.

**Proposed:** say why. `cannot use Windows' data protection from this
logon: it has no password (an SSH key, a task without a stored password).
Set the secret from a console or remote desktop session as this account, or
use env: or store:`. The same reason for a secret that cannot be read in
such a logon. Documented beside the secret store (§6.5.2) and in the README.

## 2. Server 2016: a tick that stalls, and the timing it breaks

Not seen on Windows 11 over SSH; seen on the VM (2 vCPUs, Server 2016
1607, build 14393.693, as installed, without updates):

- **Max-Runtime: 5 of 10 failed.** A run with `max_runtime = 3s` ran to its
  own end, 56 s later. The supervisor's log shows its ticks at 10:08:58,
  09:00, 09:04, 09:06, then nothing until 10:09:57: one tick took about 50
  seconds, and the worker took 8 seconds to start. Windows 11 over SSH:
  10/10.
- **Supervise: 40 of 41.** `fast ran more than once` failed: too few ticks
  in the time given.
- **Service: 16 of 17.** In user mode, `vigil restart` exited 1, though the
  service was active afterwards.

**To find out first:** what the 50-second tick was doing. Time each tick on
the VM (the supervisor log has the start; add the end), with nothing else
running there, and see whether it is one call (the process scan without
WMI, `Get-Process`, starting PowerShell) or the machine. A tick that can
stall for 50 seconds makes `max_runtime` 50 seconds late, which matters on
any slow machine, not only 2016. Then decide whether it is Vigil's to fix or
a documented floor ("Server 2016 needs its updates" or similar).

## 3. Also seen, not yet understood

- **The base pack's `base_services` fails over SSH** (exit 1), on Windows 11
  and 2016 alike: `Base-Pack.ps1` 11 of 12 on both. It runs as the service,
  LocalSystem, in a real install; whether it works there on 2016 is to be
  checked from the VM's own metrics.

## Not Vigil's

Several suites could not run on the VM at all, for want of the test tools:
Backends, Fetch, Logs, Pack, Self-Update and Stores need Python (the local
mock servers); Install needs Git Bash. These are test prerequisites, not
Vigil's; installing them on the VM is the owner's call.

## Done when

- `vigil secret set`, a run and `vigil precheck` in a logon without a
  password say why, on both Windows versions, and the docs say so.
- The 2016 tick stall is explained, and either fixed (Max-Runtime and
  Supervise pass on the VM) or documented as a floor with its reason.
