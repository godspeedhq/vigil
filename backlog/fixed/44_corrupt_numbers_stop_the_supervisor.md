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

## Built (2026-11-11)

As proposed, with these choices:

- **One rule for a number, on both platforms:** digits, no leading zero, at
  most 18 of them (9 for a pid), so it fits 64 bits (`[int]` for a pid). The
  same rule as everything Vigil writes. `_vigil_sup_isnum` (bash) and
  `Test-VigilNumber` (PowerShell).
- **A state file** with a number that is not one is unreadable, like one
  that is empty or has no header: none of its numbers is used, and it goes
  through §11.3 (quarantined once concluded, `state_corrupt`).
- **The other numbers read back** are each treated as absent when damaged,
  never put into arithmetic: a launch's `launch_epoch` (past its grace, so
  the run id is looked for and the job held while anything carries it), the
  timeout marker's `term_epoch` (Linux and macOS: the grace before KILL
  starts again rather than never ending), `fetch.next` (due), the log
  forwarder's state (due), a source's `ok_epoch` (not reported), and the
  pids `vigil uninstall` reads.
- **Specification:** §11.3, "Damaged numbers".
- **Tests:** `supervise.sh` and `Supervise.ps1`, a "damaged" section: a
  launch with `launch_epoch = 17x`, a state file with `started_epoch = abc`,
  `job_pid = 08` and an 11-digit `worker_pid`, and an empty state file, next
  to a healthy job. The tick carries on, the healthy job runs, the launch is
  abandoned, both files are quarantined, `state_corrupt` and
  `abandoned_launches` are delivered.
  - On 0.6.5 (main): bash stops with `17x: value too great for base`
    (9 failed); Windows logs `tick failed: Cannot convert value "17x"` on
    every tick (8 failed).
  - Fixed: Fedora 45/45 (bash 5.3), the Mac 45/45 (bash 3.2), Windows 11
    PowerShell 5.1 49/49. Also unchanged: Fedora uncertain 24, max-runtime
    13, run-job 42, init-uninstall 38; Windows Uncertain 28, Max-Runtime 10,
    Run-Job 52, Init-Uninstall 38.
