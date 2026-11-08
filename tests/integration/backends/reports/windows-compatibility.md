# Windows compatibility

What each Windows version showed when Vigil ran on it ([backlog 26](../../../../backlog/26_windows_server_versions.md); how: [`tests/windows-server`](../../../windows-server/README.md)). A result changes only with a run: the version, the date and what failed, if anything. A test that didn't run is never marked Passed.

**Results:** Supported (everything passed), Works with caveats (named), Not supported (why), or Not tested.

## Summary

| Version | Prerequisites | Install | Conformance | Integration | Backends | WMI refused | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Windows 11 Pro 23H2 | PowerShell 5.1 and 7, .NET 4.8.1 | Passed | Passed | Passed | Passed (LGTM) | Passed (backlog/fixed/23) | **Supported** |
| GitHub `windows-latest` (Server 2025) | PowerShell 5.1 and 7 | Passed (CI) | Passed (CI) | Passed (CI) | Not tested | Not tested | **Supported** |
| Server 2025, Desktop Experience | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Server 2016, Desktop Experience | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Server 2019, 2022 | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Server 2012 R2, 2012 (WMF 5.1) | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Server 2008 R2 SP1 (WMF 5.1) | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |

## Runs

Each version's run, newest first: `Probe.ps1`'s table, then each step's result and anything that failed, with its output.
