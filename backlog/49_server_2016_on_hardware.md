# 49. Server 2016 on real hardware: `secret set`, a timed test, the floor

Found on 2026-11-12, running Vigil 0.7.0 on Server 2016 installed on a
physical machine (Datacenter Evaluation 1607, build 14393.693, 4 CPUs,
7.8 GB), as an ordinary account over SSH. The machine is run as locked down:
nothing installed beyond Windows and the OpenSSH server, updates by zip. So
the suites that need Python or Git Bash were not run there.

| Suite | Result |
| --- | --- |
| Conformance | 145/145 |
| Config-Edit, Format, Init-Uninstall, Max-Runtime, Packaged, Run-Job, Service, Service-Packs, Uncertain | all pass (231 checks) |
| Supervise | 46/49: the orphan section (2 below) |
| Base-Pack | 11/12: `base_services`, the service manager refused over SSH |
| Precheck | 26/34: the jobs that use the test's stored secret, which its set-up could not store (DPAPI refused over SSH, as backlog 48 found) |
| Secrets | 0/1: DPAPI refused over SSH (`secret set` gives 0.7.0's message) |
| Unreadable | 23/25: its set-up `secret set`, DPAPI refused over SSH |
| Backends, Fetch, Install, Logs, Pack, Self-Update, Stores, Upgrade, Version-Config | not run: they need Python or Git Bash |

The over-SSH failures are those of backlog 48, as expected. Two things are
new.

## 1. `secret set` against a store it cannot read gives raw errors

Backlog 45 made `secret list`, `secret delete` and a `secret:` reference say
`cannot read <folder> from this account: secrets are set and read as the
account Vigil runs as`. `secret set` was missed, in both twins. Run as an
ordinary account against a system install (`C:\ProgramData\Vigil`, closed to
it):

```
> 'v' | vigil secret set FOO --stdin
New-Item : Access to the path 'secrets' is denied.
vigil: Exception calling "SetAccessControl" with "1" argument(s): ...
```

and the exit code is -1. On Linux and macOS, from reading: `mkdir -p` prints
its own `Permission denied`, exit 1. Nothing is damaged; the message is the
wrong one, after 0.7.0's notes said this class was fixed.

**Proposed:** the same check as `secret delete`, before anything is written:
`Get-VigilDenied` / `vigil_denied` on the store folder, and the same message,
exit 1.

## 2. Supervise's orphan section depends on the machine's speed

The section kills a run's worker while its job still runs, then checks the
job holds the run. Its job is `ping -n 31` (30 s; bash: `sleep 15`). On this
machine the run started only after the first ticks, and the job had ended
before the test's checks, so three checks failed: no Vigil fault. Rerun with
a 120 s job, the section passed 7/7, and `jobs.log` said:

```
ORPHANED
  long: run 20261112T175631Z-408-1, its worker (pid 948) is gone; its job (pid 1588) still runs, so it is not started again until it ends
```

**Proposed:** not a longer job (which makes every run slower, and is still a
guess), but a job that runs until the test lets it end: it waits for a file
the test writes after its checks, with a cap so it never outlives a failed
run. Both twins.

## 3. Records and the floor

- `windows-compatibility.md`: record this run beside the VM's.
- Windows Server 2016 is the floor (decided 2026-11-12): it is the first with
  PowerShell 5.1 built in. 2008 R2 was tried on the same machine and given up
  (PowerShell 2.0, no service pack: too much to install first); 2012 R2 needs
  WMF 5.1 and is past every support date. README, SPECIFICATION.md §5.1 and
  §22.5, the compatibility record and backlog 26 say 2012, 2012 R2 and
  2008 R2 are **not supported**, rather than "intended, not tested".
- `tests/windows-server/Setup-Vm.ps1` misses two things Server 2025 needed:
  its built-in OpenSSH lets in only Administrators and the `OpenSSH Users`
  group, and a Hyper-V Default Switch network is Public, so the port 22 rule
  must cover every profile.

## Done when

- `secret set` against a store it cannot read refuses with the message, exit
  1, on both shells; a test in `Unreadable.ps1` and `unreadable.sh` fails on
  0.7.0 and passes after.
- The orphan section no longer depends on timing, on both shells.
- The 2016 hardware run is recorded; the docs state 2016 as the floor;
  `Setup-Vm.ps1` has both fixes.
