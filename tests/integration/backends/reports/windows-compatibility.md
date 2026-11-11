# Windows compatibility

What each Windows version showed when Vigil ran on it ([backlog 26](../../../../backlog/26_windows_server_versions.md); how: [`tests/windows-server`](../../../windows-server/README.md)). A result changes only with a run: the version, the date and what failed, if anything. A test that didn't run is never marked Passed.

**Results:** Supported (everything passed), Works with caveats (named), Not supported (why), or Not tested.

## Summary

| Version | Prerequisites | Install | Conformance | Integration | Backends | WMI refused | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Windows 11 Pro 23H2 | PowerShell 5.1 and 7, .NET 4.8.1 | Passed | Passed | Passed | Passed (LGTM) | Passed (backlog/fixed/23) | **Supported** |
| GitHub `windows-latest` (Server 2025) | PowerShell 5.1 and 7 | Passed (CI) | Passed (CI) | Passed (CI) | Not tested | Not tested | **Supported** |
| Server 2025, Desktop Experience | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Server 2016 Datacenter Evaluation (1607, 14393.693), Desktop Experience | PowerShell 5.1, .NET 4.6.2; TLS 1.2 off by default (Vigil turns it on) | Passed: the README's one-liner, system mode, the service runs | Passed (145) | Partly: 9 suites pass, 6 fail, 9 not run ([below](#server-2016-2026-11-11)) | Not tested | Partly: as an ordinary account over SSH | **Works with caveats** (backlog 48) |
| Server 2019, 2022 | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Server 2012 R2, 2012 (WMF 5.1) | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Server 2008 R2 SP1 (WMF 5.1) | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |

## Runs

Each version's run, newest first: `Probe.ps1`'s table, then each step's result and anything that failed, with its output.

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

What is Vigil's to follow up is in [backlog 48](../../../../backlog/48_windows_over_ssh_and_server_2016.md): a clear message when DPAPI is refused, and the 50-second tick.
