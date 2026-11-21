# 66. Six gaps in how the supervisor accounts for runs

Found on 2026-11-20, writing `FAILURES.md` (PR #228) from real runs: the
supervisor did not always answer for a run, or did not say so truly.

## The gaps, and the fixes

1. **A job removed from the configuration mid-run escaped it.** Each tick
   accounted only for the jobs the configuration named, and skipped invalid
   ones before accounting. A run of a job removed, or made invalid, while it
   ran was never checked again: no `max_runtime`, no crash noticed, no
   outcome recorded by the supervisor.
   **Fix:** each tick also accounts for the jobs that still have a run Vigil
   answers for (a launch record, a token, a recovery record, or a state that
   says `running`) but which it did not account for, until the run ends.
   They are never started again. `jobs.log` lists them under `RUNNING` with
   `(no longer in the configuration, or invalid in it)`.

2. **The `file` backend kept a job's state gauges forever.** `.running`,
   `.uncertain`, `.file_missing` and `.invalid_config` were posted only
   while their condition held, and the file keeps every gauge's last value,
   so a `1` stayed after the file came back or the job was fixed.
   **Fix:** a state gauge raised last tick and not this one is posted once as
   `0`. The raised ones are kept in `state/gauges.raised`, so a supervisor
   that restarts still lowers them; without that file, the first tick lowers
   every configured job's. `vigil.supervisor.up` still keeps its last value
   in the file: nothing is left running to lower it, so the file's age is the
   signal (`FAILURES.md`).

3. **Crashed runs were not counted in `runs`.** Only the worker counted a
   run, when it ended. One whose worker died never was.
   **Fix:** the supervisor counts `runs` when it records the outcome itself
   (`crashed`, or `timed_out` after the worker went).

4. **`jobs.log` listed a held job as `starting`.** A job held for `vigil
   resolve` after its run had ended was listed under `RUNNING` as
   `starting`, and counted in `vigil.supervisor.workers`.
   **Fix:** it is listed under `UNCERTAIN` only, and not counted.

5. **A missing local script was not `FILE MISSING`.** Only scripts fetched
   from a source were checked, against SPECIFICATION 16.3: a missing local
   file was launched, and every run failed.
   **Fix:** the supervisor checks the local file too, resolved as the worker
   resolves it: `FILE MISSING`, `file_missing`, no run, and it resumes by
   itself.

6. **A crashed run's `.out` and `.err` were undocumented, and never
   deleted.** Retention deleted only dated `.log` files.
   **Fix:** SPECIFICATION 13.1 describes them; retention deletes them with
   the job's log, by the date their run id starts with, never while the run
   still holds its token.

## Done

- `tests/integration/run-accounting.sh` and `Run-Accounting.ps1`, new, one
  scenario per gap but 2's restart: 21 checks each. 21 passed, 0 failed on
  Fedora 44; on Windows 11 (the HP) under Windows PowerShell 5.1 and
  PowerShell 7; and on Windows Server 2025 under 5.1 (2026-11-21).
- Unchanged and still passing on Fedora: `supervise.sh` (85), `crash.sh`
  (66), `max-runtime.sh` (19), `uncertain.sh` (35), `logs.sh` (80),
  `fetch.sh` (61); the conformance suite, 145 on each platform.
- Found by these tests on the way: the first version of gap 2's fix kept the
  raised gauges in memory only, so a supervisor that restarted (every
  `supervise --once`) never lowered a removed job's; hence
  `state/gauges.raised`. And under PowerShell 7, `String.Split` with an array
  of separators chose another overload than under 5.1: `-split` instead.
- `FAILURES.md`'s missing-script example is now a capture of the new
  behaviour, on Fedora.
