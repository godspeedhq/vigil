# Intermittent test failures

Each has failed once or twice and passed on rerun. Any of them may be a real
race in Vigil, not only a slow runner, so none should be written off as noise.
The tests print what they know when these fail.

## Open

- `tests/integration/Format.ps1`, PowerShell 7: `a failed migration keeps the
  supervisor`, and the five checks after it, on main on 2026-11-03. The
  hot-reload supervisor had exited before the checks, and never logged the
  refused update. Cause unknown; one guess is that it never started (the test
  did not check). The test now checks that it starts, and on a failure prints
  its log, stdout and stderr.

## Fixed, cause known (2026-11-04)

- `tests/integration/Supervise.ps1`, PowerShell 5.1: `no locks left`, on main
  (b9c19a6) on 2026-11-04. **The test's:** it stops its supervisor with
  `Stop-Process -Force`, which landed between writing `vigil_sender`'s launch
  record and its worker claiming it. Vigil abandons such a launch only once it
  is older than the 120-second grace (11.3), and the next supervisor did, 133
  seconds after the launch; the test looked after 7. The test now ages a launch
  the stop left behind, and the next tick must abandon it; checked locally with
  one planted. `supervise.sh` stops its supervisor with `TERM`, which it
  handles, and has never failed this way.

- `tests/integration/Service.ps1`, PowerShell 5.1: `system/pwsh: the worker
  runs on the chosen host`, then `outlives stop` and `outlives remove`, on #67,
  `tests/secrets` and main. **The test's:** the powershell and pwsh lifecycles
  share a root, so the second read the first's last run from the state file,
  whose worker the test had already ended (or whose pid Windows had given to
  another `powershell.exe`). Found by eight runs on GitHub's runners with new
  diagnostics; the test now waits for a run id it has not seen.
- `tests/integration/Max-Runtime.ps1`, PowerShell 5.1, no WMI: `long's process
  did not survive`, on main on 2026-11-03. **Vigil's:** where `taskkill` is
  refused, Vigil ended a process tree from the leaves up, so a timed-out
  `cmd.exe` job ran its script's next line once its `ping` was killed, and a
  tick later looked uncertain. Now from the root down.
- `tests/integration/fetch.sh`, macOS: `unreachable: still runs`, on main on
  2026-11-03. **bash's:** with `set -m`, bash sets a job's process group from
  both sides of the fork, and on macOS the child's call can fail once the
  parent's has succeeded; bash then printed `child setpgid ...: Operation not
  permitted` on the worker's stderr. The worker now sends that, at the fork
  only, to `/dev/null`.
- `tests/integration/Fetch.ps1`, PowerShell 5.1: `jobs.log shows the revision`,
  on the merge of #45. The test's timing: it now waits for `config.active`.
  Not seen since.
- `tests/integration/Max-Runtime.ps1`, PowerShell 7: `long recorded as
  timed_out` and four more, on #51. A worker's state write failed while the
  supervisor was reading the file; `Write-VigilFileAtomic` now waits for the
  reader, and `Uncertain.ps1` reproduces the collision. Not seen since.

## Not seen since, with diagnostics on

None of these has come back in the last 100 CI runs (2026-11-02 to 2026-11-04),
nor in 24 macOS upgrades and self updates and 12 Windows service runs before.

- `tests/integration/upgrade.sh`, macOS: `scheduled jobs carry on`, on the
  merge of #41. A job did not run three more times within 60 seconds of the
  update.
- `tests/integration/Service.ps1`, PowerShell 7: `user/pwsh: start succeeds`,
  on #43. `vigil start` exited 1 and the service stayed inactive. The user
  lifecycles share a root too, but this check comes after the run, so the
  stale state above does not explain it.
- `tests/integration/self-update.sh`, macOS: `reload: it says so`.
- `tests/integration/Self-Update.ps1`, Windows, run locally:
  `reload: the supervisor is running`.

## Not a test

- **macOS jobs cancelled at 15 minutes with no steps** (six in the last 100
  runs): GitHub gave the job no runner (`runner_name` empty). A job's
  `timeout-minutes` counts from when it is queued. Rerun it.
- `tests/integration/supervise.sh`, macOS, on the `fix/task-21` branch on
  2026-11-03: work in progress there, not on main.

## Done when
- Each has a known cause and is fixed, or is shown to be the test's timing.
