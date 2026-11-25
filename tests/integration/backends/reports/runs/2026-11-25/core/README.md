# Eight core defects, before and after

Vigil's core (the supervisor, the worker, and the files they share) was read against `SPECIFICATION.md` by a reviewer whose only job was to break it. Every suspicion had to be reproduced on a real machine, in a throwaway root, with a control beside it, or it did not count. Eight counted. #266 fixed them; these are the reproductions, run on 1.5.0 and run again on the fix.

- **Before:** 2026-11-24, on the engine 1.5.0 shipped (commit `5413ac5`).
- **After:** 2026-11-25, on `main` at `db5f157`, which becomes 1.5.1. The same scripts, unchanged.
- **Where:** Fedora (bash 5.3; the full-disk test in a `debian:13-slim` container, bash 5.2), and Windows 11 (Windows PowerShell 5.1, with two of the "before" runs repeated on PowerShell 7).

| # | Defect | Engine | Script | Output (in `before-1.5.0/` and `after-1.5.1/`) |
| --- | --- | --- | --- | --- |
| V-01 | A run concluded from its spool file took a metric the job printed as its outcome | both | `lead01-spool-outcome.sh`, `Lead01-SpoolOutcome.ps1` | `fedora-lead01.out`, `lead01-ps51.out` (before, also `lead01-ps7.out`) |
| V-02 | A launch that threw made the jobs started before it start again, every tick | PowerShell | `Lead02-DoubleRun.ps1` | `lead02-ps51.out` (before, also `lead02-ps7.out` and the control, `lead02-ps51-control.out`) |
| V-03 | `tick = 08m` passed precheck and ended the supervisor | bash | `lead05-octal.sh` | `fedora-lead05.out`; section (a) of `stage2-windows-ps51.out` shows the PowerShell engine never had it |
| V-04 | While waiting for a first fetch, a run in progress was not held to `max_runtime` | both | `lead04-waiting.sh`, `Stage2-Windows.ps1` (b) | `fedora-lead04.out` (before, also the control), `stage2-windows-ps51.out` (b) |
| V-05 | On a full disk, an empty state file was published over a good one | bash | `lead06-fulldisk.sh` | `fedora-lead06.out` |
| V-06 | A spool that could not be written ended the worker before its final state | PowerShell | `Stage2-Windows.ps1` (c) | `stage2-windows-ps51.out` (c) |
| V-07 | `state_dir`, changed while Vigil ran, started a second run beside the first | both | `lead08-15.sh statedir` | `fedora-lead08.out` |
| V-08 | A run held by `queue_one` started after its job was disabled | both | `lead08-15.sh queued` | `fedora-lead15.out` |

The scripts call each defect by the number of the lead it began as (lead 1, lead 2, and so on); the table is the key.

## What to look for

| # | On 1.5.0 | On the fix |
| --- | --- | --- |
| V-01 | `status = succeeded` for a job that exited 2; `status = failed` for one that exited 0 | `failed`, and `succeeded` |
| V-02 | `workers of a alive: 4` (PowerShell 5.1), `6` (PowerShell 7); `tick failed` every tick | `workers of a alive: 1`; `job b: could not be launched` |
| V-03 | `supervise --once exit 1`; `08: value too great for base`; a running supervisor gone 15 s after the edit | `exit 0`; `alive: yes` |
| V-04 | 95 s into a run limited to 20 s: `status = running` | `passed max_runtime` logged 20 s after the start; `status = timed_out` |
| V-05 | `0 bytes  /st/jobs/j.state`; then `status = crashed`, `run_id =` (empty), the file quarantined | `725 bytes`: the last good state kept; `final state not written (a full disk?)` in the job's log; nothing quarantined |
| V-06 | `vigil run exit 1`; `status = running` left behind; then `crashed`, `worker vanished` | `vigil run exit 0`; `status = succeeded`; `events not written to the spool: this run's metrics are lost` |
| V-07 | `processes running the job's script: 2`; a token in each of `state/locks` and `state2/locks` | `1`; `state_dir is now <root>/state2 in the configuration: it takes effect when Vigil is next started` |
| V-08 | The job under `DISABLED` and under `RUNNING` at once: `run … started` 15 s after it was disabled | `the run held for it is dropped: the job is disabled`; `processes running the job's script: 0` |

## How they are run

Each script makes a root of its own, from a scratch copy of `app/` and `vendor/`, and ends only what it started there.

```console
$ mkdir -p ~/vv/src && cp -R app vendor ~/vv/src/        # bash: the copy the roots are made from
$ bash repro/lead01-spool-outcome.sh
$ bash repro/lead04-waiting.sh source                    # or: control
$ bash repro/lead08-15.sh statedir                       # or: queued
$ docker run --rm --tmpfs /st:size=256k -v ~/vv/src:/src:ro -v "$PWD/repro":/repro:ro debian:13-slim bash /repro/lead06-fulldisk.sh
```

```console
PS> powershell -NoProfile -ExecutionPolicy Bypass -File repro\Lead02-DoubleRun.ps1          # or: -Control
PS> powershell -NoProfile -ExecutionPolicy Bypass -File repro\Stage2-Windows.ps1            # or: -Only waiting
```

The crash points some of them use (`VIGIL_FAULT=worker.after_spool`) are the engine's own, the ones `tests/integration/crash.sh` uses.

## What was changed in these files

Nothing in what Vigil printed. In the Windows outputs, the path of the account's temporary folder is written `%TEMP%` and the laptop's host name `win11-dev`. One timing measurement the Windows script also took, which belongs to none of these eight, is left out of the script and its outputs. The scripts gained the licence header, and find the repository from where they are.

## The regression tests

Each defect also has a test in the suites, in both engines, so CI holds the line from here: `crash` (V-01), `supervise` (V-02 on Windows, V-03, V-04, V-07, V-08) and `run-job` (V-05, V-06).

| Where | Result on the fix |
| --- | --- |
| CI: Linux, macOS, Windows PowerShell 5.1 and 7 | 33 jobs passed, none failed |
| Fedora, bash 5.3 | supervise 98, crash 68, run-job 64, fetch 61, uncertain 35, run-accounting 21, max-runtime 19; none failed |
| macOS 12, bash 3.2 | supervise 98, crash 68, run-job 64; none failed |
| Windows 11, Windows PowerShell 5.1 | Supervise 107, Crash 68; none failed |
