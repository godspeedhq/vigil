# 43. Windows: an orphaned job is not seen, and runs twice

Found in the engineering-challenges review of 2026-11-10 (challenges 3.1 and
3.2, [the review](reviews/2026-11-10_engineering_challenges.md)).

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
