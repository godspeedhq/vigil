# 56. What the specification promises and the code does not do

Found on 2026-11-17 by the documentation audit (#178): seven places where
SPECIFICATION.md describes behaviour the code does not have. Changing the
specification to match would have quietly dropped a promise, so the owner
decided each one (2026-11-17).

## Decided

**Build:**

1. **Crash points (§22.4.1).** The specification says the code carries named
   crash points, reached when `VIGIL_FAULT` names one, and that they drive
   the launch and fan-out tests of §22.4. None exists: `VIGIL_FAULT` only
   makes pre-flight fail. One of the v1 acceptance criteria (§25) depends on
   them: "The crash points of §22.4.1 drive the launch and fan-out tests on
   every platform."
2. **The sender's 5-minute `max_runtime` (§4.5).** Vigil's own workers write
   no deadline, so a hung sender is never ended, and with at most one sender
   at a time, nothing more is delivered until it ends by itself.

**Change the specification to match the code:**

3. **Pre-flight on start (§16.4, §21).** Only `vigil service install` and the
   installers run pre-flight; `vigil start` does not, and a missing
   `require_env` variable fails the job's runs, not the start.
4. **No spool flush on stop (§10.4).** Stopping the supervisor leaves the
   spool as it is; the next sender delivers it.
5. **Quarantine is kept (§11.3).** Quarantined state files are kept until
   removed by hand; log retention does not cover them.
6. **Leftover temporary files (§12.3, §4.5).** Only the supervisor's own are
   deleted, when it starts. A worker's or the sender's are left behind and
   never sent or read. Test 26 of §22.4 changes to match: "never sent".
7. **No tag-cap warning (§15.x).** Validation does not check a backend's
   cap on tags; the backend's documentation is the reference.

## Proposed

**Crash points.** One function per platform, `vigil_fault <point>`
(`Invoke-VigilFault` on Windows), called at each point named in §22.4.1.
When `VIGIL_FAULT` names the point it exits with code 99; `name:N` exits on
the Nth time the point is reached in that process. Unset, it returns at
once and costs nothing. With `VIGIL_FAULT_SLEEP=<seconds>` the point waits
that long instead of exiting, for test 22 (a worker held past the launch
grace before it claims). The supervisor logs a warning at startup when
`VIGIL_FAULT` is set; pre-flight already fails.

Points, as §22.4.1 names them: `launch.after_record`, `launch.after_spawn`,
`worker.before_claim`, `worker.after_claim`, `worker.after_spool`,
`worker.after_state`, `fanout.after_claim`, `fanout.after_targets`,
`fanout.after_place:N`, `fanout.before_retire`, `sender.after_send`,
`state.after_temp`.

Tests, in `tests/integration/crash.sh` and `Crash.ps1`: §22.4's 20, 21, 22
(launch window: exactly one run per launch, or none), 25 and 26 (fan-out:
every event reaches every target at least once; no partial file is sent),
and 29 (a randomised loop over every launch and fan-out point, checked
against both invariants, a bounded number of rounds in CI). Test 23 (claim
against abandonment, 1,000 times) uses the same function.

**The sender's limit.** Vigil's own workers write `deadline_epoch` as the
job runs do: the sender's start plus 300 seconds. The supervisor already
ends any run past its deadline (§10.3); it then accounts for the sender as
it does for a job. Only the sender gets one: `vigil_fetch`, `vigil_logs`
and `vigil_update` keep their own timeouts.

## Drawbacks, and how each is contained

1. **Code that exists only for tests, in the paths that matter most.** A
   crash point sits inside the launch and fan-out code.
   **Contained by** each point being one call that does nothing unless
   `VIGIL_FAULT` names it, pre-flight failing when it is set, and the
   supervisor warning about it at every start.
2. **A sender ended mid-delivery.** A batch in flight when the limit ends
   it is not retired, so it is sent again by the next sender: at least once,
   never lost (§4.5).

## Done when

- The crash points exist on both platforms, and the tests above pass on
  Linux, macOS and Windows in CI.
- A sender past 5 minutes is ended and recorded `timed_out`, on both
  platforms, with a test.
- §4.5, §10.4, §11.3, §12.3, §15, §16.4, §21 and §22.4 say what the code
  does.

## Built (2026-11-17)

**The sender's limit** (#180): the sender's state records its deadline and
the sender as its own job process, so the supervisor ends it past 5 minutes
as it ends a job, recorded `timed_out`; a later sender delivers what it was
sending. `VIGIL_TEST_SENDER_LIMIT` (§22.4.7) shortens it for the tests.
`backends.sh` and `Backends.ps1` hang the mock backend and check all of it.

**Crash points:** `vigil_fault` (`config.sh`) and `Invoke-VigilFault`
(`Config.ps1`), called at the twelve points of §22.4.1 on both platforms.
`name:N` exits the Nth time; `VIGIL_FAULT_SLEEP` waits instead of exiting.
An exit is abrupt: `exit 99` with no trap on the paths concerned, and on
Windows `[Environment]::Exit(99)`, which runs no `finally` block. The
supervisor warns at startup while `VIGIL_FAULT` is set.

**Tests:** `tests/integration/crash.sh` and `Crash.ps1`, in CI on Linux,
macOS and Windows (PowerShell 5.1 and 7): §22.4's 20, 21, 22, 23, 25, 26
and 29. Two departures from §22.4 as it was written, both now in it:
- **22.** A worker held before its claim carries the run id, so the
  supervisor keeps holding it past the grace, as §11.3 says, rather than
  abandoning it; the late worker then runs the job once. The invariant
  holds either way: one run per launch, or none.
- **23.** Not 1,000 rounds on every platform: `CRASH_RACE_ROUNDS`, 50 on
  Linux and macOS and 10 on Windows by default, where each round starts
  PowerShell. More can be run by hand.

**The specification** now says what the code does for items 3 to 7, and
§22.4.1 describes the crash points as built.

Found on the way, in the tests only: a launch crash point fires at the
first launch of a tick, so each launch test first lets the job's runs end
(a tick launches its jobs before the sender); and a sender still running
takes an event first, so each fan-out test waits for none to be running.

Tested before merging: `crash.sh` 35 of 35 on Fedora (bash 5.3) and the Mac
(bash 3.2), with 50 races; `Crash.ps1` 35 of 35 on this laptop, PowerShell
5.1 and 7; `backends` and `supervise` passing on Fedora and the Mac with
both changes in.
