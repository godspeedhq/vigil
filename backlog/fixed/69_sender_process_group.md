# A stopped sender's children kept its run

Found by the fleet test (bug B6 in `tests/integration/backends/reports/runs/2026-11-26/fleet-run2/BUGS.md`) on 2026-11-26, while checking the fix of backlog 68 in a container: a sender stopped at its 5-minute limit was concluded 96 seconds after the TERM, not the usual 10, and meanwhile `vigil status` reported `ORPHANED: vigil_sender: run …, its worker (pid 390253) is gone; its job (pid 390253) still runs`.

## What was wrong

A worker starts its job in a process group of its own (`set -m`), so that past `max_runtime` the supervisor's TERM, and KILL after `grace`, reach everything the job started (§11.6). The sender is its own job, but the supervisor started it with a plain `&`, in the supervisor's own group. So:

- the TERM to the sender's group found no such group and went to the sender alone; the `curl` or subshell it was waiting on was never signalled, kept the run token it had inherited, and so kept the run alive until it ended by itself;
- the KILL after `grace` for what lives on is sent by the job's worker, and the sender's worker was the process that had just gone, so nothing would have sent it;
- the report said the same pid was both gone and running.

Windows ends a job's whole process tree at once, and its sender starts no processes, so it was not affected.

## The fix

- The supervisor starts the sender in its own process group (`set -m` in the subshell that starts it). The TERM now ends the sender and what it started together.
- When a worker that is its own job is gone and its run is still held, the supervisor sends the KILL itself once `grace` has passed: to the group only, never to the bare process id, which may have been reused. A group's id is not reused while the group has a member, so the group is still the run's.
- The ORPHANED report for such a run says that processes it started still hold it. The PowerShell twin words it the same way.

`tests/integration/backends.sh` now lets each request of the hung-sender test wait 30 seconds for the mock, which answers after 60, and checks that the run is over within 20 seconds of being started with a 3-second limit. Before the fix it failed (the run lasted until `curl` gave up); after, it passes on Fedora 44 (bash 5.3) and macOS 12 (bash 3.2). With the fix, these suites pass whole: `backends` (43), `max-runtime` (19), `supervise` (104), `crash` (72), `uncertain` (35) and `run-accounting` (21) on Fedora; `backends`, `max-runtime` and `supervise` on macOS; `Supervise.ps1` (113) on Windows 11.

`Crash.ps1` on Windows 11, run over SSH, fails 6 to 9 of its 72 checks on `main` and on this branch alike, a different set each time (twice each): it waits for crashed workers with `Get-CimInstance`, which Windows denies over SSH, so it can go on before a worker has ended. Its orphan checks pass.

## Closed

2026-11-27.
