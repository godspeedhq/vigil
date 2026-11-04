# Updates on real machines

`vigil self update` from a published release to the latest, on real machines, with no test overrides (spec 18.7): the release's own installer from GitHub, the real release server and the real release key. Each run kept its console output, Vigil's logs and state: see [Real systems](https://godspeedhq.github.io/vigil/real/) on the site, or [`runs/`](runs). CI tests every change the same way against a build of its own (`tests/integration/upgrade.sh`, `Upgrade.ps1`); these runs are the published releases themselves.

**What each run checks:**
- the old release installs from GitHub, and its jobs and supervisor run
- `vigil self update --check` names the latest release
- `vigil self update` moves it there: the files, then the running supervisor, as the same process
- the configuration is untouched, a job running across the update finishes once, scheduled jobs carry on, nothing crashed or was quarantined, and metrics still flow
- from 0.2.1: the latest release is signed by the key the old release has (0.2.1 checks that silently; the run checks it too)
- a second update finds nothing newer

## Runs

| Date | Machine | From | To | Signature | Result | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-04 | Fedora 44, bash 5.3 | 0.2.0 | 0.2.2 | Not checked: 0.2.0 predates signing (SHA-256 only) | **Passed**, 18 of 18 | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#update-from-020) |
| 2026-11-04 | Fedora 44, bash 5.3 | 0.2.1 | 0.2.2 | **Verified** with 0.2.1's key | **Passed**, 19 of 19 | [Fedora](https://godspeedhq.github.io/vigil/real/fedora/#update-from-021) |
| 2026-11-04 | macOS 12.7.6, bash 3.2 | 0.2.0 | 0.2.2 | Not checked: 0.2.0 predates signing (SHA-256 only) | **Passed**, 18 of 18 | [macOS](https://godspeedhq.github.io/vigil/real/macos/#update-from-020) |
| 2026-11-04 | macOS 12.7.6, bash 3.2 | 0.2.1 | 0.2.2 | **Verified** with 0.2.1's key | **Passed**, 19 of 19 | [macOS](https://godspeedhq.github.io/vigil/real/macos/#update-from-021) |
| 2026-11-04 | Windows 11 Pro 23H2, PowerShell 5.1 | 0.2.0 | 0.2.2 | Not checked: 0.2.0 predates signing (SHA-256 only) | **Passed**, 18 of 18 | [Windows](https://godspeedhq.github.io/vigil/real/windows/#update-from-020) |
| 2026-11-04 | Windows 11 Pro 23H2, PowerShell 5.1 | 0.2.1 | 0.2.2 | **Verified** with 0.2.1's key | **Passed**, 19 of 19 | [Windows](https://godspeedhq.github.io/vigil/real/windows/#update-from-021) |

All six ran over SSH as a standard user (`vigil-test`), in a user install with no service, the supervisor in the foreground, with the test scripts at commit `4df6070`.
