# 58. v1 acceptance: what is not yet proven

Found on 2026-11-18 by an audit of the 40 criteria of SPECIFICATION.md §25
against the tests and CI (run 44256289451 on main, green on Linux, macOS
bash 3.2 and Windows PowerShell 5.1 and 7). A criterion counted as met only
where a test that runs on the platforms it names checks it, or a recorded
real-machine test does.

**18 met, 21 partly, 1 not met (28).** Almost every gap is a missing test,
not missing behaviour; four are bugs (the third and fourth found while
writing tests). Nothing in §25 is ticked until its gaps here are closed.

Met: 1, 2, 3, 6, 9, 10, 12, 13, 15, 16, 19, 26, 30, 31, 33, 35, 38, 40.

## Bugs

1. **A queued run can run twice (§9, criterion 21), both platforms.** A
   `queue_one` job's held slot is saved as `queued=<job>` in `state/pending`.
   When the active run ends, the tick starts it, and only after that saves
   `state/pending` (`supervisor.sh` `_vigil_sup_queue_save` after the
   admission loop; `Supervisor.ps1` the same). A crash after the launch
   (`launch.after_spawn`) leaves the slot queued, and the next supervisor
   runs it again once the first run ends. Fix: save the queue before
   starting, so a crash loses the slot rather than runs it twice: one run or
   none, never two. Test: a crash test that drives exactly this window.
2. **Windows: an empty `job_start` weakens the identity check (§11.5,
   criterion 27).** `$timeout` takes a missing start time as a match, and
   once the worker has gone the parent is not checked either, so only the
   PID and name prove the run's process. A worker can almost always read its
   own job's start time, but a missing one must count as unproven.
3. **A failed fan-out copy (§4.5, §22.4 test 28, criterion 22).** Found
   while writing test 28, which has a copy fail by putting a file where a
   backend's queue directory should be (a full disk fails the same copy).
   - Linux and macOS lose the event for that backend. `_vigil_send_place`
     leaves no done marker for the failed copy, then retires the fan-out
     anyway. Seen on Fedora: b fixed, the event never reached it, nothing
     logged.
   - Windows loses nothing (the fan-out is kept and b gets the event once
     fixed), but the failed copy stops the sender, so a's copy, already
     placed, is not delivered while b's fails.

   Fix, both platforms alike: a failed copy removes its temporary file and
   leaves the fan-out unretired; the sender carries on with the other
   targets and files, and the next sender tries again.
4. **Linux and macOS: a descendant ignoring TERM outlives `max_runtime`
   (§10.3, §11.6, criterion 29).** Found while making the test check
   descendants. The supervisor sends TERM to the job's process group and
   means to send KILL a grace later if the group is still running. But when
   the job's own process exits on TERM, its worker records `timed_out` and
   releases the token at once, so the run looks over and the KILL never
   comes: a child in the same group that ignores TERM lives on. Seen on
   Fedora and macOS: the child finished its sleep and left its marker.
   Children that exit on TERM, and a job that ignores TERM itself, are
   stopped. Windows ends the whole tree at once and passes the same test.

   Fix: the worker, holding the token, waits while the job's group still
   has a member, up to the grace from the TERM, then sends KILL to the
   group, and only then records the run and releases the token. While the
   group has a member its id cannot be reused, so the group is still the
   run's.

## The specification and README, to say what is true

Decided 2026-11-18:

1. **§18.8:** drop "Uninstall is idempotent: running it on a clean machine
   succeeds and changes nothing". It contradicts the paragraph above it (a
   folder with no `app/vigil` is refused), and after an uninstall there is
   no `vigil` left to run. Criterion 4 loses "and is idempotent".
2. **Criterion 7:** "a script version changes on a host only when its
   configuration changes" holds for pinned sources only; a branch ref moves
   by design (§24). Say "for pinned sources".
3. **Criterion 9:** every example configuration validates, except
   `tests/mocks/advanced/10-rejected.config`, which is invalid on purpose.
4. **README status table:** the spool size cap is tested by hand on Fedora
   (`tests/integration/backends`), not by "the suites", until CI tests it.

## Tests to add

By §22.4 test number where there is one.

**§22.4 tests with no test on any platform (criterion 28):**
- 1 and 2: corrupt, then delete, the state of a live run: neither killed
  nor run twice, and found by its token and run id (criteria 17, 18).
- 13 and 24: a state file and a launch record from another boot (a
  different `boot_id`): concluded, and every prior run with them (20).
- 17: the state file of a live run is unchanged, byte for byte, through
  ticks, until the token is released (25).
- 27: a backend removed with events queued for it: dropped and counted as
  `backend_removed` (22).
- 28: the disk fills during a fan-out (22). Hard to do portably; at least
  the failed copy leaves the event queued.

**Partly covered:**
- 7: `state.after_temp` runs only by chance in the random loop; give it its
  own case. 16: drive `worker.after_spool` and `worker.after_state` rather
  than plant files. `worker.after_claim` is never used (23).
- `spool_full`: the spool cap in CI on all platforms, with the drop counted
  (22, 36).
- `max_runtime` kills the whole tree: the tests' marker is written by the
  job's shell, so a surviving child would pass. Check a descendant (29).
- Windows PID reuse: the start-time and parent checks are never reached;
  the test's process differs by name already (27).
- `queue_one` end to end: the held run starts when the active one ends, and
  `state/pending` survives a restart (14).
- A job added to a running supervisor's configuration is scheduled without
  a restart (5).
- A run in progress across a configuration activation finishes, untouched
  (7).
- bash and PowerShell compute the same revision for the same content (8).
- Direct execution (`#!` and executable bit) and `{file}` run end to end on
  Linux and macOS, and a file that is not executable fails as it should (11).
- `jobs.log` sections no test reads: CRASHED, INVALID, WAITING, LAST RUN,
  VERSION and the CONFIGURATION REJECTED header (32, 30).
- Uncertain runs reported on every tick, not one; `vigil resolve` on a run
  still uncertain (24, 26).
- Nagios performance data delivered to a receiver, not only formatted (34).
- A backend outage: jobs still run on time (36). Log forwarding: a killed
  forwarder, a hung destination, jobs unaffected (39).
- Windows: the sftp source test can SKIP silently, its setup step is
  `continue-on-error`; make a skip fail CI (6). The `irm | iex` installer
  form, and a fresh `-Archive -Key` install (3).
- `vigil uninstall` in system mode on Linux and macOS: the unit is gone (4).

## Order

1. The two bugs, each with its test.
2. The wording fixes above.
3. The tests, §22.4's first, in a few pull requests, each on every
   platform.
4. Then tick §25, criterion by criterion.

## Seen while fixing the bugs

- 2026-11-18, Fedora: one round of test 29 (6 random crashes) did not see
  its event in both backends within 20 ticks. My output filter hid the
  `lost after <point>` line, so the crash point is unknown. 24 more rounds
  there, and every round on the Mac and on Windows, delivered everything.
  If CI or a machine shows it again, the point it names is the lead.
- Explained 2026-11-18 by CI on macOS (run 44342725737), where it happened
  again: the test lost the event, not Vigil. crash.sh's `event` read the
  time three times, for the file and for its rename; when the second
  turned between them, `mv` found no file and the event never reached the
  spool. Now it reads the time once; Crash.ps1 did already. A second
  test bug showed once the loss printed where the event got to: when the
  job was still running, the crashing tick's first launch was the
  sender's, and `launch.after_record` left the sender's launch record. The
  test aged only the job's, so Vigil rightly started no sender until the
  30-second grace passed, past the test's 20 ticks. Both twins now age
  every launch left. Fedora: 2 of 75 rounds lost an event before, 0 of 75
  after.
