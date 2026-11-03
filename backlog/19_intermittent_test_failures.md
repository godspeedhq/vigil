# Intermittent test failures

Each has failed once or twice and passed on rerun. Any of them may be a real
race in Vigil, not only a slow runner, so none should be written off as noise.
The tests now print what they know when these fail.

- `tests/integration/upgrade.sh`, macOS: `scheduled jobs carry on`, on the
  merge of #41. A job did not run three more times within 60 seconds of the
  update.
- `tests/integration/Service.ps1`, PowerShell 7: `user/pwsh: start succeeds`,
  on #43. `vigil start` exited 1 and the service stayed inactive.
- `tests/integration/self-update.sh`, macOS: `reload: it says so`.
- `tests/integration/Self-Update.ps1`, Windows, run locally:
  `reload: the supervisor is running`.

- `tests/integration/Fetch.ps1`, PowerShell 5.1: `jobs.log shows the revision`,
  on the merge of #45. Probably the test's timing: the fetch is detached, so
  `Invoke-Tick` can return before the fetch takes its lock, and the next tick
  can write `jobs.log` before the fetch activates. The test now waits for
  `config.active`. Close this entry if it does not come back.

- `tests/integration/Max-Runtime.ps1`, PowerShell 7: `long recorded as timed_out`
  and four more, on #51. Cause found and fixed: a worker's state write failed
  while the supervisor was reading the file, so the run never recorded its
  job process, could not be proven to own it, and was never stopped (as
  designed when ownership is unproven). `Write-VigilFileAtomic` now waits for
  the reader; `Uncertain.ps1` reproduces the collision. Close this entry if it
  does not come back.

None came back in 24 macOS upgrades and self updates, or 12 Windows service
runs, with diagnostics on.

## Done when
- Each has a known cause and is fixed, or is shown to be the test's timing.
