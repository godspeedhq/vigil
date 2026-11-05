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
- `tests/integration/Max-Runtime.ps1`, PowerShell 7: `long's process did not
  survive`, on main (the merge of #95) on 2026-11-05. Some run's `cmd.exe`
  lived on to write its marker after the supervisor ended its tree. The fix
  below for PowerShell 5.1 orders Vigil's own kill from the root down, but
  with WMI the kill is `taskkill /T /F`, and 30 tries locally never let
  `cmd.exe` run its next line. Each kill was followed a tick later by
  "uncertain", which only says the worker was still waiting for its job's
  output. The marker now names the run and the time, and a failure prints
  the job log, so the next one shows which run lived on and when.
- `tests/integration/version-config.sh`, macOS: `a release that will not
  install is logged as an error` (expected 1 ERROR line, got 0), on #101 on
  2026-11-05. The same run before it failed on a GitHub 504 downloading
  0.2.2, which is not this. It passed on the next CI run and twice in a row
  on the Mac (48 of 48). Cause unknown. A failure now prints
  `update.reported` and every supervisor line about the update (asks,
  could not be, reloading, staying on, started, stopped), so the next one
  shows whether the supervisor saw the failed install at all.

## Fixed, cause known (2026-11-05)

- `tests/integration/upgrade.sh`, Linux: `scheduled jobs carry on`, on #94
  on 2026-11-05 (and on macOS on the merge of #41, below). **Vigil's:** the
  installer swaps `app/` with two renames, and for that instant there is no
  `app/`. A worker started then cannot run, so it never claims its launch,
  and the supervisor held the job for the 120-second launch grace (11.3).
  The test waited 60. Reproduced on Fedora: with `app/` swapped 80 times
  while a job launched every second, one launch was never claimed. The
  grace only has to cover starting a process, since a started worker
  carries its run id however slow it is to claim, so it is now 30 seconds;
  the same repro then abandoned both stranded launches (`beat` and
  `vigil_sender`) after 30 seconds and the jobs carried on. On a failure,
  both upgrade tests now list the lock files and the supervisor log without
  the skipped slots.
- `tests/integration/Supervise.ps1`, PowerShell 5.1, run locally: `jobs run
  together: no ceiling`, twice on 2026-11-05. **The test's:** `fast`'s job
  (`ping -n 1`) ended at once, so on a slow machine it could start and end
  before `slow` took the in-flight marker. Both start on the same slots, so
  `fast` now lasts 2 seconds (1 in `supervise.sh`) and the two are in flight
  together however long each takes to start.

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
  update. Most likely the stranded launch fixed above (2026-11-05).
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
