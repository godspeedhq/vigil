# 44. A corrupt number in a launch or state file stops every job

Found in the engineering-challenges review of 2026-11-10 (challenge 3.1,
[the review](reviews/2026-11-10_engineering_challenges.md)).

## The problem

Reproduced on both platforms: a launch file
`state/locks/a.X1.launch` with `launch_epoch = abc` (or `17x`), next to a
healthy job `b`.

- Linux and macOS: `supervisor.sh: line 303: abc: unbound variable` (with
  `17x`, `value too great for base`), and the supervisor exits 1 under
  `set -u`. Job `b` never starts, no `jobs.log` is written, and under
  systemd or launchd it crash-loops.
- Windows: `ERROR supervisor tick failed: Cannot convert value "abc" to type
  "System.Int64"` at `Supervisor.ps1:424`, on every tick while the file
  exists. Job `b` is never started.

The same pattern, a field cast or used in arithmetic without a check, is in
`[long]$st.Deadline`, `[long]$acc.State.Started`, `[long]$next` (fetch.next)
in `Supervisor.ps1`, and `started_epoch` and the timeout marker's `term` in
`supervisor.sh`.

These files are written atomically, so this needs disk corruption or a hand
edit. But SPECIFICATION.md §11 promises damaged state is quarantined and
reported (`state_corrupt`), never that one file stops the rest; a bad
spool line was already fixed for the same reason.

## Proposed

- A non-numeric value where a number is expected makes the record
  unreadable, and it goes the way of any unreadable record: quarantined,
  reported, the job concluded per §11.3. Unrelated jobs run.

## Done when

- An integration test on both platforms plants an unreadable launch file and
  an unreadable state file (non-numeric fields, and empty) next to a healthy
  job, and checks that the healthy job runs, the file is quarantined and
  `state_corrupt` is reported. No test plants a corrupt state file today.
