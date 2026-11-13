# Windows compatibility

What each Windows version showed when Vigil ran on it ([backlog 26](../../../../backlog/26_windows_server_versions.md); how: [`tests/windows-server`](../../../windows-server/README.md)). A result changes only with a run: the version, the date and what failed, if anything. A test that didn't run is never marked Passed.

**Results:** Supported (everything passed), Works with caveats (named), Not supported (why), or Not tested.

## Summary

| Version | Prerequisites | Install | Conformance | Integration | Backends | WMI refused | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Windows 11 Pro 23H2 | PowerShell 5.1 and 7, .NET 4.8.1 | Passed | Passed | Passed | Passed (LGTM) | Passed (backlog/fixed/23) | **Supported** |
| GitHub `windows-latest` (Server 2025) | PowerShell 5.1 and 7 | Passed (CI) | Passed (CI) | Passed (CI) | Not tested | Not tested | **Supported** |
| Server 2025, Desktop Experience | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Server 2016 Datacenter Evaluation (1607, 14393.693), Desktop Experience: a physical machine | PowerShell 5.1, .NET 4.6.2; TLS 1.2 off by default (Vigil turns it on) | Passed: the README's command, system mode, the service runs (0.7.0) | Passed (145) | Partly: 10 suites pass, 4 fail only where Windows refuses an SSH logon, 9 not run ([below](#server-2016-physical-2026-11-12)) | Not tested | Partly: as an ordinary account over SSH | **Works with caveats** (backlogs 48, 49) |
| Server 2016, the same build: a Hyper-V VM | as above | Passed (0.6.5) | Passed (145) | Partly: 9 suites pass, 6 fail, 9 not run ([below](#server-2016-2026-11-11)) | Not tested | Partly: as an ordinary account over SSH | **Works with caveats** (backlog 48) |
| Server 2019, 2022 | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Server 2012 R2, 2012 | PowerShell 4.0 built in | Not tested | Not tested | Not tested | Not tested | Not tested | **Not supported:** below the Server 2016 floor |
| Server 2008 R2 | PowerShell 2.0 built in; the machine tried had no service pack | Not tried: the prerequisites were given up ([below](#server-2008-r2-2026-11-12)) | Not tested | Not tested | Not tested | Not tested | **Not supported:** below the Server 2016 floor |

## Runs

Each version's run, newest first: `Probe.ps1`'s table, then each step's result and anything that failed, with its output.

### Server 2016, physical, 2026-11-12

The same version as the VM below, installed on a physical machine (4 CPUs, 7.8 GB), as installed (no updates), and run as locked down: nothing installed beyond Windows and the OpenSSH server (Win32-OpenSSH 10.0, from its zip). Reached directly over SSH as `vigil-test`, an ordinary account. Vigil 0.7.0 installed with the README's command (`-System -UpdateBy vigil-test`) from an elevated prompt; the service runs. The suites ran from `main` at `0f9ac0f`, one after another, as `vigil-test` over SSH. `powershell -NoProfile` starts in about 2 seconds here (the VM: 1.3 to 26).

| Item | Value |
| --- | --- |
| Windows | Windows Server 2016 Datacenter Evaluation, Server |
| Build | 14393.693 (1607) |
| Windows PowerShell | 5.1.14393.693 |
| PowerShell 7 (pwsh) | no |
| .NET Framework | 4.6.2 (release 394802) |
| TLS protocols offered by default | Ssl3, Tls |
| TLS 1.2 known to .NET | yes |
| SchUseStrongCrypto, 64-bit and 32-bit .NET | not set |
| HTTPS to github.com, TLS 1.2 on | yes (200) |
| OpenSSH client (ssh) | yes |
| curl.exe, tar.exe, git | no |
| WMI (CIM) from this session | no: Access denied |
| This session elevated | no |

| Suite | Result |
| --- | --- |
| Run-Conformance | 145 passed |
| Config-Edit, Format, Init-Uninstall, Max-Runtime, Packaged, Run-Job, Service, Service-Packs, Uncertain | all passed (40, 30, 38, 10, 22, 52, 17, 2, 28) |
| Supervise | 46 of 49: the orphan section's 30-second job had ended before its checks. With a 120-second job, 7 of 7, and `jobs.log` said `ORPHANED`. The section now waits for the test, not the clock (backlog 49): rerun here with that change, 49 of 49 |
| Base-Pack | 11 of 12: `base_services`, the service manager refused over SSH (backlog 48) |
| Precheck | 26 of 34: the jobs that use the stored secret its set-up could not store, DPAPI refused over SSH (backlog 48) |
| Secrets | stopped at its first `secret set`, with 0.7.0's message: `Windows refuses its data protection to this logon, ...` |
| Unreadable | 23 of 25: its set-up `secret set`, as above. Rerun with backlog 49's checks, 26 of 28: the new `secret set` checks pass |
| Backends, Fetch, Logs, Pack, Self-Update, Stores, Upgrade, Version-Config | not run: they need Python, not installed |
| Install | not run: needs Git Bash |

Found here, in [backlog 49](../../../../backlog/fixed/49_server_2016_on_hardware.md): `vigil secret set` as an ordinary account against the system install printed raw errors (`Access to the path 'secrets' is denied`, then a `SetAccessControl` exception) and exited -1. Fixed: it now says `cannot read C:\ProgramData\Vigil\config from this account: secrets are set and read as the account Vigil runs as`, exit 1, checked on this machine.

### Server 2008 R2, 2026-11-12

Installed on the same physical machine first: Server 2008 R2 without its service pack, with PowerShell 2.0. Vigil needs PowerShell 5.1, which needs SP1, two servicing updates, .NET 4.8 and WMF 5.1 first, and then TLS 1.2 turned on by hand. Given up before Vigil was installed: too much to install for a version out of support since 2020. With 2012 R2 (PowerShell 4.0, past every support date), it is below the floor, Server 2016.

### Server 2016, 2026-11-11

A Hyper-V VM on the Windows 11 machine, 2 vCPUs, as installed (no updates), reached over SSH as `vigil-test`, an ordinary account. Vigil 0.6.5 installed with the README's command (`-System -UpdateBy vigil-test`) from an elevated prompt on the VM; the service runs (NSSM and its SYSTEM PowerShell up), and `vigil status` from the ordinary account says it cannot read the logs, as it should (backlog 40). The suites ran from `main` at `216180f`, one after another, as `vigil-test` over SSH:

| Item | Value |
| --- | --- |
| Windows | Windows Server 2016 Datacenter Evaluation, Server |
| Build | 14393.693 (1607) |
| Windows PowerShell | 5.1.14393.693 |
| PowerShell 7 (pwsh) | no |
| .NET Framework | 4.6.2 (release 394802) |
| TLS protocols offered by default | Ssl3, Tls |
| HTTPS to github.com, TLS 1.2 on | yes (200) |
| curl.exe, tar.exe, git | no |
| WMI (CIM) from this session | no: Access denied |
| This session elevated | no |

| Suite | Result |
| --- | --- |
| Run-Conformance | 145 passed |
| Config-Edit, Format, Init-Uninstall, Packaged, Run-Job, Service-Packs, Uncertain | all passed (40, 30, 38, 22, 52, 2, 28) |
| Supervise | 40 of 41: `fast ran more than once` (timing) |
| Service | 16 of 17: user-mode `restart` exited 1, the service active after; system mode skipped (needs an elevated prompt) |
| Max-Runtime | 5 of 10: one supervisor tick took about 50 s, so a 3 s `max_runtime` run ran to its own end (56 s). Windows 11 over SSH: 10 of 10 |
| Precheck | 26 of 34; Windows 11 over SSH fails the same way (27 of 34): DPAPI refused over SSH |
| Secrets | stopped at its first `secret set`: `Access is denied`, DPAPI refused to a key-based SSH logon; Windows 11 over SSH the same |
| Base-Pack | 11 of 12: `base_services` exit 1; Windows 11 over SSH the same |
| Backends, Fetch, Logs, Pack, Self-Update, Stores, Upgrade, Version-Config | not run: they need Python, not on the VM |
| Install | not run: needs Git Bash |

What followed, in [backlog 48](../../../../backlog/fixed/48_windows_over_ssh_and_server_2016.md):

- **DPAPI over SSH:** Windows refuses it to a logon without a password, on Windows 11 too. Vigil now says so (`Windows refuses its data protection to this logon, ...`), checked over SSH on both. The Secrets and Precheck failures above are that.
- **`base_services` over SSH:** the service manager refuses a standard user's network logon, and the script says so. Not a defect; the service, as LocalSystem, is not refused.
- **The long ticks are the machine:** on this VM, `powershell -NoProfile -Command exit` took 1.3 to 26 seconds (15 tries), and single supervisor ticks 7 to 57 seconds (30 tries); on Windows 11, 0.3 seconds. Idle, Max-Runtime passed 3 of 4 times. Why PowerShell starts so slowly here (no updates, Windows Defender, memory) needs an administrator on the VM to find out. §10.3 now says that `max_runtime` is enforced only as quickly as ticks run.
