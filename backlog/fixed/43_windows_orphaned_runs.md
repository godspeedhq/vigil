# 43. Windows: an orphaned job is not seen, and runs twice

Found in the engineering-challenges review of 2026-11-10 (challenges 3.1 and
3.2, [the review](../reviews/2026-11-10_engineering_challenges.md)).

## The problem

**A job whose worker dies is started again while it still runs (reproduced,
Windows PowerShell 5.1).** Job `c` (a 90-second sleep, `run_every = 10s`) was
running. Its worker was ended with `Stop-Process -Force`. At the next tick
the supervisor recorded `crashed`, reason `worker vanished`, and wrote a new
launch for `c`, while the first run's job process was still running.

SPECIFICATION.md §11.3 says that case is **Orphaned**: "Worker gone, but a job
process of the run is still alive: As Alive: no replacement while it runs.
Reported as `ORPHANED`", and the v1 acceptance list (§22) has "Crashed,
orphaned and identity-mismatched workers are handled per §11.3" and "Corrupt
or missing state never, by itself, causes ... a duplicate run to start".

Why: on Windows only the worker holds the run token (`Worker.ps1`), and the
other liveness check, `Test-VigilRunProcess` (`Supervisor.ps1`), looks for a
process whose command line carries `--run-id <id>`, which the job's own
process does not. On Linux and macOS the job inherits the token on fd 9
(`worker.sh`), so the run stays alive, but neither platform reports
`ORPHANED`.

**Two smaller faults in the same check:**

- The run id is matched as a substring (`LIKE '%--run-id <id>%'` on Windows,
  a substring match on macOS, `supervisor.sh`), so run `...-1` is held alive
  by a live run `...-10` to `...-19`, launched in the same second.
- A state file that is empty or has no header gives an empty run id, and
  `LIKE '%--run-id %'` then matches every worker on the machine: the job is
  held "running" for as long as any unrelated job runs (reproduced, Windows).

## Proposed

- Windows: the job inherits the run token's handle (or runs in a Job Object
  the token's holder owns), so the existing "token held" rule covers it, as
  on Linux and macOS.
- Both: a run with workers gone and its job alive is reported `ORPHANED` in
  `jobs.log`.
- The run id is matched as a whole argument, and never probed when empty: an
  unreadable state with no run id to go on is quarantined as now.

## Done when

- The §22 orphan test exists on both platforms: kill the worker, the job
  keeps running, no second run starts, `ORPHANED` is shown, and the run is
  concluded once the job exits.
- Tests for the run-id prefix case and the empty state file.

## Built (2026-11-10)

As proposed.

- **Windows: the job holds the run.** The worker opens the run token with
  `FileShare 'None, Inheritable'`, so the job process (started with
  `Process.Start`, which passes inheritable handles on) gets the handle, as
  it gets fd 9 on Linux and macOS. A job whose worker is gone keeps the
  token held, so the run stays alive and nothing is started beside it. A
  process the job leaves running holds it too; the worker's delete of the
  token tolerates that, and the supervisor removes the token once nobody
  holds it.
- **`ORPHANED` in `jobs.log`, both platforms:** a live run whose token is
  held and whose worker's pid no longer exists: `long: run <id>, its worker
  (pid <n>) is gone; its job (pid <n>) still runs, so it is not started again
  until it ends`. When the job ends, the run is concluded as crashed, as
  before.
- **Run ids matched as a whole argument** (Windows: WMI candidates checked
  with a regex, and the native fallback's `AnyCommandLine`; macOS: the `ps`
  match), and **never probed when empty** (both platforms).
- **SPECIFICATION.md** §4.3 and §11.5 say the job inherits the token on
  Windows too.
- **Tests:** the §22 item-14 orphan test, in `Supervise.ps1` and
  `supervise.sh`: kill the worker, the job keeps running, the same run stays,
  no second one starts, `jobs.log` says `ORPHANED`, and once the job ends the
  run is concluded and its token removed.
  - Windows PowerShell 5.1: 41/41. On the code before this fix the same test
    fails: a second run starts beside the first, and no `ORPHANED`.
  - `supervise.sh` 36/36 on Fedora 44 (bash 5.3) and macOS 12 (bash 3.2 and
    5.2).
  - No regressions: `Run-Job.ps1` 52/52, `Uncertain.ps1` 28/28,
    `Max-Runtime.ps1` 10/10; `run-job.sh` 42/42, `uncertain.sh` 24/24,
    `max-runtime.sh` 13/13 on Fedora and the Mac.
- **Not tested:** the run-id prefix case (runs `-1` and `-10` live in the same
  second) and the empty state file next to a live worker are fixed in the
  code but have no test of their own; the reviewer's reproduction of the
  empty-file case was on 0.6.5.
- **Found on the way:** on Windows, the tests' usual tick
  (`& powershell ... supervise --once *> $null`) waits until every holder of
  its output pipe has closed it, and a long job ends up holding it, so each
  tick took as long as the job (80 s with a 60 s job, on 0.6.5 as well). The
  orphan test starts its ticks with `Start-Process` and waits for that
  process alone. How the job comes to hold that pipe is not yet explained.
- **What it changes for operators:** as on Linux and macOS, a process the job
  starts holds the run too, so a run is over only when the job and everything
  it left running have ended. `Service.ps1`'s cleanup stopped the job's
  `cmd.exe` but not its `ping`, which then held the run and kept the next
  lifecycle waiting; it now ends the job's whole tree (CI's install jobs
  caught it; 33/33 locally after).
