# When a job fails

Scheduling a script is the easy part. The hard part comes later, when a job goes wrong at 3 AM and someone has to work out what happened. This page is about that part: what Vigil does when a run fails, hangs, crashes or never starts, what it keeps for you to look at, and how you get the job back on its feet.

It starts with one failed job, followed from the failure to the rerun. Then it goes through every other way a run can go wrong, and ends with what Vigil does by itself, what it leaves to you, and what it doesn't do at all.

**Everything below is real.** Each console capture was taken on a Fedora 44 machine on 20 November 2026, running Vigil from a clone with a scratch root (`--root /home/vigil-test/docfail/root`, so that's the path you'll see). The story says 3 AM, but the jobs ran every minute so the failures didn't take all night: the times in the captures are the real ones, in UTC, around 17:00. The scripts fail on purpose, and each one is shown, so you can [try it yourself](#try-it-yourself). Commands are shown as `vigil`, as on an installed Vigil; they ran as `app/vigil --root /home/vigil-test/docfail/root`, and the files they name are under that root.

## Contents

- [What Vigil keeps about every run](#what-vigil-keeps-about-every-run)
- [The words Vigil uses](#the-words-vigil-uses)
- [A failed job, from 3 AM to the rerun](#a-failed-job-from-3-am-to-the-rerun)
- [When the run succeeds but the thing it checks is down](#when-the-run-succeeds-but-the-thing-it-checks-is-down)
- [Every other way a run can go wrong](#every-other-way-a-run-can-go-wrong)
- [What Vigil does by itself, and what needs you](#what-vigil-does-by-itself-and-what-needs-you)
- [What Vigil doesn't do](#what-vigil-doesnt-do)
- [Vigil beside cron, Task Scheduler and your monitoring](#vigil-beside-cron-task-scheduler-and-your-monitoring)
- [Try it yourself](#try-it-yourself)

---

## What Vigil keeps about every run

Every run gets a **run id** when it is launched, such as `20261120T170008Z-1009026-15`. The same id is on every line and file the run leaves behind, so you can follow one run from end to end with `grep`.

| Where | What it tells you | Kept |
| --- | --- | --- |
| `vigil status` (`logs/supervisor/jobs.log`) | Every job right now: running, waiting, held, crashed, and how each one's last run ended | Rewritten every tick |
| `logs/supervisor/<date>.log` | What the supervisor did: runs started, slots missed or skipped, runs stopped, crashed, abandoned or held | One file a day |
| `logs/jobs/<job>/<date>.log` | Each run: when it started, everything it printed (stdout and stderr), and how it ended, with its CPU time | One file a day, per job |
| `state/jobs/<job>.state` | The job's latest run: status, reason, exit code, start and end times, duration, process ids | The latest run only |
| Metrics (your backend, or `metrics/vigil.prom`) | Counts of runs by outcome, durations, and whatever the script printed as `metric` lines | However long your backend keeps them |

How long logs are kept is up to you: `[log] retain_days` for every log, or `log_retain_days` for one job's (7 days by default). The state file holds only the latest run, so the job log is the history.

## The words Vigil uses

A run that has ended has one of these outcomes, and it's the `status` in the state file:

| Outcome | What it means |
| --- | --- |
| `succeeded` | The script exited with a success code: `0`, unless `exit_codes` says otherwise. |
| `warning` | A Nagios plugin exited `1` (`exit_codes = nagios`). |
| `failed` | The script exited with a failure code, or couldn't start at all (its file is missing, its runner isn't there, a required variable isn't set). `reason` says which. |
| `unknown` | A Nagios plugin exited `3`, or with a code Nagios doesn't define. |
| `timed_out` | It ran past `max_runtime`, and Vigil stopped it. |
| `crashed` | Its worker vanished without recording how the run ended. |

A run that's still going is `running`. And a few things are reported that are **not** runs, because no run happened, or none could be judged:

| Reported as | What happened |
| --- | --- |
| `skipped` | The time came, but the job's previous run was still going (`overlap = skip`, the default). |
| `missed` | The supervisor wasn't running at the time (or the machine was asleep, or the clock jumped), and came back after `late_start_window` had passed. |
| abandoned launch | The supervisor launched a run, but its worker never started. |
| `UNCERTAIN` (in `jobs.log`) | Vigil can't prove whether the run is still alive, or that a process is the run's. The job is held. |

**There is no `not_run` state.** A run that didn't happen has no outcome, and the job's state file still shows its previous run: it shows up as one of the reports above, in the supervisor log and the metrics. The words "not run" appear in one place only: `vigil run` exits `4` when it refuses to start a run (because one is already in progress, the job is unknown or invalid, or the configuration has errors).

**`failed` is about the script, not the thing it checks.** A health check that runs to the end and finds the database down has `succeeded`: the check worked, and its answer is in its metrics. [That case](#when-the-run-succeeds-but-the-thing-it-checks-is-down) has a section of its own below.

---

## A failed job, from 3 AM to the rerun

`orders_export` writes the day's orders to an export share every night. Its configuration:

```ini
[job.orders_export]
metric_name = shop.orders_export
file        = scripts/orders_export.sh
run_every   = 1m
max_runtime = 10m
env         = EXPORT_DIR=/home/vigil-test/docfail/share
```

In real life it would be `run_at = 03:00`; here it runs every minute. And the script:

```sh
#!/usr/bin/env bash
# orders_export.sh: writes the day's orders to the export share.
share=${EXPORT_DIR:?}
out=$share/orders-$(date -u +%F).csv
echo "exporting orders to $out"
if ! printf 'id,total\n1001,25.00\n1002,14.50\n' > "$out" 2> /dev/null; then
    echo "cannot write $out: is the export share mounted?" >&2
    echo "metric rows_exported 0"
    exit 2
fi
echo "metric rows_exported 2"
```

Tonight the share isn't there. `vigil precheck` passed when the job was added: it checks the script, the runner and the folders Vigil needs, but it can't know the share will be missing at 3 AM.

### Before: the run starts

At its time, the supervisor launches the run and logs it:

```text
2026-11-20T17:00:08Z INFO supervisor job orders_export: run 20261120T170008Z-1009026-15 started
```

Before the worker even starts, the supervisor writes a launch record for the run. Every run is accounted for from that moment on, so a supervisor that crashes mid-launch never starts the same run twice ([how that works](README.md#the-life-of-a-run)).

### During: the script fails

The script can't write its file, says why on stderr, and exits `2`. The worker records everything in the job log, `logs/jobs/orders_export/2026-11-20.log`:

```text
2026-11-20T17:00:09Z 20261120T170008Z-1009026-15 run start
2026-11-20T17:00:09Z 20261120T170008Z-1009026-15 out exporting orders to /home/vigil-test/docfail/share/orders-2026-11-20.csv
2026-11-20T17:00:09Z 20261120T170008Z-1009026-15 out metric rows_exported 0
2026-11-20T17:00:09Z 20261120T170008Z-1009026-15 err /home/vigil-test/docfail/root/scripts/orders_export.sh: line 6: /home/vigil-test/docfail/share/orders-2026-11-20.csv: No such file or directory
2026-11-20T17:00:09Z 20261120T170008Z-1009026-15 err cannot write /home/vigil-test/docfail/share/orders-2026-11-20.csv: is the export share mounted?
2026-11-20T17:00:09Z 20261120T170008Z-1009026-15 run end failed (exit code 2) in 0s, cpu 0.24s
```

`out` lines are stdout and `err` lines are stderr, exactly as the script printed them. The output reaches this file when the run ends, all with the end time, stdout first. While a run is still going, its output so far is in a file of its own beside the log, named after the run id: `<run id>.out` and `<run id>.err` (on Windows, `.out.raw` and `.err.raw`).

### After: what Vigil recorded

The job's state file, `state/jobs/orders_export.state`, holds the whole run summary:

```ini
[state]
schema_version   = 1
job              = orders_export
run_id           = 20261120T170008Z-1009026-15
instance         = db-01
status           = failed
reason           = exit code 2
boot_id          = f4d0989a-632d-4986-bf54-590720c04f03
started_epoch    = 1795194009
started_at       = 2026-11-20T17:00:09Z
deadline_epoch   = 1795194609
worker_pid       = 1025290
worker_name      = bash
worker_start     = 1795194007
job_pid          = 1025480
job_name         = bash
job_start        = 1795194008
ended_epoch      = 1795194009
ended_at         = 2026-11-20T17:00:09Z
duration_seconds = 0
cpu_seconds      = 0.24
exit_code        = 2
metric_lines     = 1
invalid_lines    = 0
dropped_lines    = 0
spool_file       = 1795194009-orders_export-20261120T170008Z-1009026-15.events
```

`vigil status` shows it under `LAST RUN`, beside the other jobs:

```console
$ vigil status
service: not registered

Vigil db-01 at 2026-11-20T17:00:58Z

WAITING
  orders_export: next 2026-11-20T17:01:00Z
  api_health: next 2026-11-20T17:01:00Z
  report_build: next 2026-11-20T17:01:00Z

LAST RUN
  orders_export: failed at 2026-11-20T17:00:09Z, took 0s
  api_health: succeeded at 2026-11-20T17:00:09Z, took 0s
  report_build: timed_out at 2026-11-20T17:00:38Z, took 29s
(exit code 0)
```

(`service: not registered` because this supervisor ran from a terminal. On an installed Vigil this line says whether the service is running.)

And the run's metrics went to the backend. With the `file` backend, they are in `metrics/vigil.prom`, ready for node_exporter's textfile collector. After three failed runs:

```text
shop_orders_export_failures_total{exit_code="2",host="fedora",instance="db-01",job="orders_export",os="linux"} 3
shop_orders_export_rows_exported{host="fedora",instance="db-01",job="orders_export",os="linux"} 0
shop_orders_export_runs_total{host="fedora",instance="db-01",job="orders_export",os="linux"} 3
```

`rows_exported` is the script's own `metric` line, and `failures` carries the exit code as a tag. Every other backend gets the same metrics, with dots (`shop.orders_export.failures`) instead of underscores.

### Who gets woken up

Not Vigil's job. **Vigil doesn't send alerts, emails or pages.** It records the failure and forwards the evidence, and your monitoring decides who to wake. With Prometheus, for example, rules on the metrics above could be:

- `increase(shop_orders_export_failures_total[1h]) > 0`: a run failed in the last hour.
- `increase(shop_orders_export_succeeded_total[25h]) == 0`: no run of the nightly job has succeeded in a day, whatever the reason: it failed, timed out, crashed, was missed or never started. This one catches the runs that didn't happen, which a failure count can't.

### In the morning: finding out what happened

Start with `vigil status`: it names the job and when its last run ended. Then the state file, for the reason and the exit code, and the run id. With the run id, `grep` finds the run everywhere it left a trace:

```console
$ grep 20261120T170008Z-1009026-15 logs/supervisor/2026-11-20.log
2026-11-20T17:00:08Z INFO supervisor job orders_export: run 20261120T170008Z-1009026-15 started
```

The job log has its output, as above. And the job log is also its history: one `run end` line per run, so you can see whether this is the first failure or the tenth:

```console
$ grep 'run end' logs/jobs/orders_export/2026-11-20.log | head -n 3
2026-11-20T16:59:09Z 20261120T165909Z-1009026-6 run end failed (exit code 2) in 0s, cpu 0.22s
2026-11-20T17:00:09Z 20261120T170008Z-1009026-15 run end failed (exit code 2) in 0s, cpu 0.24s
2026-11-20T17:01:09Z 20261120T170108Z-1009026-24 run end failed (exit code 2) in 0s, cpu 0.24s
```

To check how the job is set up, `vigil precheck <job>` prints its effective settings and where each one came from, and checks its file, runner and folders, without running anything:

```console
$ vigil precheck orders_export
Configuration /home/vigil-test/docfail/root/config/vigil.config
  no problems

job.orders_export
  file              = scripts/orders_export.sh (job)
  runner            = sh                     (runners)
  metric_name       = shop.orders_export     (job)
  run_every         = 1m                     (job)
  max_runtime       = 10m                    (job)
  grace             = 30s                    (built-in)
  overlap           = skip                   (built-in)
  exit_codes        = standard               (built-in)
  enabled           = true                   (built-in)
  on_uncertain      = wait                   (built-in)
  backends          = file                   (built-in)
  late_start_window = 15m                    (built-in)
  log_retain_days   = 7                      (built-in)
  working_dir       = .                      (built-in)
  env               = EXPORT_DIR=/home/vigil-test/docfail/share (job)

Checks
  ok    data format: 1
  ok    job.orders_export
  ok    state directory: /home/vigil-test/docfail/root/state
  ok    log directory: /home/vigil-test/docfail/root/logs
  ok    spool directory: /home/vigil-test/docfail/root/spool

precheck passed
(exit code 0)
```

Here the stderr line says it all: the share wasn't mounted.

### Recovery: fix it, then run it again

**Vigil doesn't retry a failed run.** It runs the job again at its next scheduled time, which for a nightly job is the next night. If the export can't wait, fix the cause, then run the job yourself:

```console
$ mkdir -p /home/vigil-test/docfail/share
$ vigil run orders_export
orders_export: succeeded in 0s, run 20261120T170154Z-1042611
(exit code 0)
```

`vigil run` runs the job once, now, in the foreground. It's launched, claimed and recorded exactly as a scheduled run: it gets a run id, the job log and state file show it, and its metrics count it. Its exit code is the outcome (0 succeeded, 1 warning, 2 failed, 3 unknown, 4 not run), so you know at once whether the fix worked. When it didn't:

```console
$ vigil run orders_export
orders_export: failed (exit code 2) in 0s, run 20261120T171517Z-1180701
(exit code 2)
```

What to know before you rerun:

- **It's a new run, not a replay.** It runs the script and configuration as they are now, with the time, data and secrets of now. Nothing from the failed run is restored. Whether a second run is safe (an export that might write the file twice, a load that might insert rows twice) is up to the script: Vigil doesn't guarantee that a job's external effects happen exactly once.
- **It won't start beside a run in progress.** If a run of the job is still going, it refuses, and says why:

  ```console
  $ vigil run report_build
  vigil: a run of report_build may be in progress (/home/vigil-test/docfail/root/state/locks/report_build.20261120T170008Z-1009026-17.token); not starting
  (exit code 4)
  ```
- **Run it as the account the service runs as,** as with `vigil precheck`: `sudo -u vigil vigil run orders_export` on Linux, `sudo` on macOS, an elevated prompt on Windows. The job then has the permissions, secrets and files its scheduled runs have.

The job log now ends with the rerun:

```text
2026-11-20T17:01:54Z 20261120T170154Z-1042611 run start
2026-11-20T17:01:54Z 20261120T170154Z-1042611 out exporting orders to /home/vigil-test/docfail/share/orders-2026-11-20.csv
2026-11-20T17:01:54Z 20261120T170154Z-1042611 out metric rows_exported 2
2026-11-20T17:01:54Z 20261120T170154Z-1042611 run end succeeded in 0s, cpu 0.18s
```

and the metrics show the recovery: `rows_exported` is back to 2, and `succeeded` is counting (the scheduled runs every minute after it succeeded too):

```text
shop_orders_export_failures_total{exit_code="2",host="fedora",instance="db-01",job="orders_export",os="linux"} 3
shop_orders_export_rows_exported{host="fedora",instance="db-01",job="orders_export",os="linux"} 2
shop_orders_export_runs_total{host="fedora",instance="db-01",job="orders_export",os="linux"} 10
shop_orders_export_succeeded_total{host="fedora",instance="db-01",job="orders_export",os="linux"} 7
```

Nothing needs resetting or acknowledging in Vigil. A failed run holds nothing up: the job was never blocked, and the next scheduled run would have run anyway.

---

## When the run succeeds but the thing it checks is down

`api_health` checks whether the orders API answers:

```sh
#!/usr/bin/env bash
# api_health.sh: is the orders API answering? The check succeeds either
# way: its answer is the "up" metric.
if err=$(curl -fsS -m 5 -o /dev/null http://127.0.0.1:8099/health 2>&1); then
    echo "orders API is up"
    echo "metric up 1 target=orders_api"
else
    echo "orders API is down: $err"
    echo "metric up 0 target=orders_api"
fi
```

The API is down, and the run **succeeded**:

```text
2026-11-20T17:00:09Z 20261120T170008Z-1009026-16 run start
2026-11-20T17:00:09Z 20261120T170008Z-1009026-16 out orders API is down: curl: (7) Failed to connect to 127.0.0.1 port 8099 after 0 ms: Could not connect to server
2026-11-20T17:00:09Z 20261120T170008Z-1009026-16 out metric up 0 target=orders_api
2026-11-20T17:00:09Z 20261120T170008Z-1009026-16 run end succeeded in 0s, cpu 0.25s
```

```text
shop_api_health_succeeded_total{host="fedora",instance="db-01",job="api_health",os="linux"} 3
shop_api_health_up{host="fedora",instance="db-01",job="api_health",os="linux",target="orders_api"} 0
```

That's the right answer: the check did its job, and found the API down. The two are different questions, for different people:

- **Is the check working?** The run's outcome: `succeeded`, or `failed` if the check itself broke (curl missing, the script gone).
- **Is the API up?** The check's own metric, `up`. That's the one to alert on: `shop_api_health_up == 0`.

If you'd rather a down target fail the run, make the script exit non-zero when it finds one. A Nagios plugin already works that way: with `exit_codes = nagios`, exit `2` (CRITICAL) is `failed`, `1` (WARNING) is `warning`.

---

## Every other way a run can go wrong

### A script that hangs: `timed_out`

`report_build` waits on a lock that never comes free:

```sh
#!/usr/bin/env bash
# report_build.sh: hangs, waiting on a lock that never comes free.
echo "building the monthly report"
sleep 600
```

```ini
[job.report_build]
metric_name = shop.report_build
file        = scripts/report_build.sh
run_every   = 1m
max_runtime = 20s
grace       = 5s
```

Once the run is past `max_runtime`, the supervisor proves the process is the run's own, then stops it:

```text
2026-11-20T17:00:08Z INFO supervisor job report_build: run 20261120T170008Z-1009026-17 started
2026-11-20T17:00:38Z WARN supervisor job report_build: run 20261120T170008Z-1009026-17 passed max_runtime; sent TERM to its job
```

```text
2026-11-20T17:00:09Z 20261120T170008Z-1009026-17 run start
2026-11-20T17:00:38Z 20261120T170008Z-1009026-17 out building the monthly report
2026-11-20T17:00:38Z 20261120T170008Z-1009026-17 run end timed_out (stopped after max_runtime 20s) in 29s, cpu 0.24s
```

The state file says `status = timed_out`, `reason = stopped after max_runtime 20s`, `exit_code = 143` (the TERM), and `<metric>.timeouts` counts it: `shop_report_build_timeouts_total` in the file. A timeout isn't counted as a failure.

- **It's accurate to one tick.** The supervisor checks deadlines once a tick (10 seconds here, 60 by default), so this 20-second limit stopped the run at 29 seconds.
- **TERM, then KILL.** On Linux and macOS the job's whole process group gets TERM, then KILL once `grace` has passed if anything is left. Windows has no TERM for console programs, so the process tree is ended at once.
- **No `max_runtime`, no limit.** A job without one runs as long as it runs. Its `<metric>.running` gauge, the seconds it has been running, climbs every tick: that's the signal to alert on.

### The worker is killed: `crashed`

Each run has a worker: Vigil's own process, which starts the script and records the outcome. Here the worker and the script were both killed with `kill -9`, as an out-of-memory kill might. Nothing was left to record an outcome, so at its next tick the supervisor concluded the run had crashed:

```text
2026-11-20T17:05:05Z INFO supervisor job warehouse_load: run 20261120T170505Z-1068780-7 started
2026-11-20T17:05:15Z WARN supervisor job warehouse_load: run 20261120T170505Z-1068780-7 crashed: worker vanished without an outcome
```

```text
Vigil db-01 at 2026-11-20T17:05:15Z

CRASHED
  warehouse_load

WAITING
  orders_export: next 2026-11-20T17:06:00Z
  api_health: next 2026-11-20T17:06:00Z
  warehouse_load: next 2026-11-20T17:06:00Z

LAST RUN
  orders_export: succeeded at 2026-11-20T17:05:05Z, took 0s
  api_health: succeeded at 2026-11-20T17:05:06Z, took 1s
```

The supervisor writes the state file itself, since the worker can't:

```ini
[state]
schema_version   = 1
job              = warehouse_load
run_id           = 20261120T170505Z-1068780-7
instance         = db-01
status           = crashed
reason           = worker vanished
boot_id          = f4d0989a-632d-4986-bf54-590720c04f03
started_epoch    = 1795194305
ended_epoch      = 1795194315
```

It's a shorter record: no exit code or duration, because nobody saw the run end. `<metric>.crashes` counts it. A crashed run is never treated as a success, and the job is **not** restarted straight away: it runs again at its next scheduled time, so a job that keeps crashing can't turn into a tight restart loop.

**The output is still there.** The job log has only `run start` for a crashed run, because the worker died before it could copy the output in. What the script printed is in the run's own file, beside the job log:

```console
$ cat logs/jobs/warehouse_load/20261120T170505Z-1068780-7.out
loading orders into the warehouse
```

### The worker dies, the script lives on: orphaned

This time only the worker was killed. The script kept running, and it still holds the run's token, so Vigil knows the run is alive. It is **not** started again beside itself:

```text
Vigil db-01 at 2026-11-20T17:06:15Z

ORPHANED
  warehouse_load: run 20261120T170605Z-1068780-16, its worker (pid 1081270) is gone; its job (pid 1081421) still runs, so it is not started again until it ends

RUNNING
  warehouse_load: pid 1081421, running for 10s, max_runtime in 290s

WAITING
  orders_export: next 2026-11-20T17:07:00Z
  api_health: next 2026-11-20T17:07:00Z
  warehouse_load: next 2026-11-20T17:07:00Z

LAST RUN
  orders_export: succeeded at 2026-11-20T17:06:05Z, took 0s
  api_health: succeeded at 2026-11-20T17:06:05Z, took 0s
```

When the script ended, nobody was left to see its exit code, so the run was recorded as crashed:

```text
2026-11-20T17:06:55Z WARN supervisor job warehouse_load: run 20261120T170605Z-1068780-16 crashed: worker vanished without an outcome
```

But the script had finished its work. Its output file shows it:

```console
$ cat logs/jobs/warehouse_load/20261120T170605Z-1068780-16.out
loading orders into the warehouse
loaded
metric rows_loaded 1200
```

So **a crashed run is one whose outcome nobody saw, not necessarily one that did nothing.** Before you rerun a crashed job, read its `.out` and `.err` files, and check what it was supposed to change.

### The supervisor stops or restarts

The supervisor is the scheduler. Stopping it (a service restart, an upgrade, a crash) **never stops a running job**: each worker carries on and records its own outcome.

Here the supervisor was stopped ten seconds into a 45-second `warehouse_load` run, and started again 85 seconds later:

```text
2026-11-20T17:03:09Z INFO supervisor job warehouse_load: run 20261120T170309Z-1009026-44 started
2026-11-20T17:03:19Z INFO supervisor supervisor stopped; running workers continue
2026-11-20T17:04:45Z INFO supervisor configuration loaded
2026-11-20T17:04:45Z INFO supervisor supervisor started, pid 1068780
2026-11-20T17:04:45Z INFO supervisor job warehouse_load: slot 2026-11-20T17:04:00Z missed
2026-11-20T17:04:45Z INFO supervisor job orders_export: run 20261120T170445Z-1068780-1 started
```

What happened to each job:

- **The run in progress finished**, with no supervisor at all, and recorded itself:

  ```text
  2026-11-20T17:03:54Z 20261120T170309Z-1009026-44 run end succeeded in 45s, cpu 0.24s
  ```
- **`orders_export` ran late.** Its 17:04 slot passed while the supervisor was down. It came back 45 seconds later, well inside the job's `late_start_window` (15 minutes by default), so the run started at once.
- **`warehouse_load` missed its slot.** Its `late_start_window` is 30 seconds, and 45 had passed, so the slot was recorded as `missed` and counted in `<metric>.missed`, and the job waited for its next one. Only the latest slot ever counts: a supervisor that was down for a day doesn't come back to a backlog of runs.

While the supervisor is down:

- **`max_runtime` isn't enforced.** The first tick after it returns enforces it.
- **`jobs.log` stops changing.** `vigil status` on a machine without the service shows the last one written, so check the time on its first line. An installed Vigil's `vigil status` says first whether the service is running.
- **Metrics stop being delivered.** Runs that end meanwhile leave their events in `spool/incoming/`, and they're sent when the supervisor returns. The `vigil.supervisor.up` heartbeat stops, which is how a backend sees that Vigil itself is down. One catch with the `file` backend: the file keeps every gauge's last value, so it still said `vigil_supervisor_up ... 1` here after the supervisor had stopped. Watch the file's age instead: node_exporter's textfile collector reports it as `node_textfile_mtime_seconds`. (The same goes for a job's `.running` and `.uncertain` gauges: in the file they keep their last value after the run, or the hold, is over.)

### The machine reboots

Not shown here. Each run records the boot it started in. After a reboot, every run recorded as `running` is over, since its processes died with the machine: the supervisor records its outcome from the events the worker wrote, if it got that far, and `crashed` if not. Then the jobs run on their schedule.

### Vigil can't tell: `UNCERTAIN`

Vigil stops or replaces a run only when it can prove what the run is doing. When the evidence doesn't settle it, the run is **uncertain**: Vigil holds the job, reports it every tick, and kills nothing.

`db_dump` closes the run token it inherited, as some programs that turn themselves into daemons do. So when it passed `max_runtime`, Vigil couldn't prove its process was the run's, and wouldn't stop it:

```sh
#!/usr/bin/env bash
# db_dump.sh: dumps the orders database. It closes the descriptors it
# inherited, as some self-daemonising tools do, so Vigil cannot prove that
# its process belongs to the run.
exec 9>&-
echo "dumping the orders database"
sleep 50
echo "dump complete"
```

```ini
[job.db_dump]
metric_name  = shop.db_dump
file         = scripts/db_dump.sh
run_at       = 17:09
max_runtime  = 15s
on_uncertain = manual
```

```text
2026-11-20T17:09:25Z WARN supervisor job db_dump: run 20261120T170905Z-1068780-44 is uncertain (past max_runtime, but its job process cannot be proven to be the run's); holding it, killing nothing (on_uncertain = manual)
```

```console
$ vigil status
service: not registered

Vigil db-01 at 2026-11-20T17:09:25Z

UNCERTAIN
  db_dump: past max_runtime, but its job process cannot be proven to be the run's

RUNNING
  warehouse_load: pid 1119741, running for 20s, max_runtime in 280s
  db_dump: pid 1119730, running for 20s, past max_runtime

WAITING
  orders_export: next 2026-11-20T17:10:00Z
  api_health: next 2026-11-20T17:10:00Z
  warehouse_load: next 2026-11-20T17:10:00Z
  db_dump: next 2026-11-21T17:09:00

LAST RUN
  orders_export: succeeded at 2026-11-20T17:09:05Z, took 0s
  api_health: succeeded at 2026-11-20T17:09:05Z, took 0s
(exit code 0)
```

The reason is kept in a recovery record, `state/recovery/db_dump.recovery`, which survives a supervisor restart:

```ini
[recovery]
job          = db_dump
run_id       = 20261120T170905Z-1068780-44
conclusion   = uncertain
reason       = past max_runtime, but its job process cannot be proven to be the run's
first_seen   = 1795194565
last_checked = 1795194565
policy       = manual
resolved_by  = 
resolved_at  = 
```

and `<metric>.uncertain` is posted as `1` every tick while it lasts.

What happens next is the job's `on_uncertain`:

- **`wait`** (the default): the job is held until the evidence settles, here when the dump ends, and then it's released by itself.
- **`replace`**: new runs start anyway, each one counted in `<metric>.possible_duplicates`. For cheap checks that are safe to run twice.
- **`manual`**: held until a person says the run is over, even once the evidence has settled. For dumps, loads and transfers, whose half-finished work someone should look at first.

This dump finished on its own at 17:09:55 (`status = succeeded` in its state file). Under `manual`, the job stayed held:

```text
UNCERTAIN
  db_dump: run 20261120T170905Z-1068780-44 idle; held until vigil resolve (on_uncertain = manual)
```

(`idle` means no process of the run is left. In the same `jobs.log`, `db_dump` was also listed under `RUNNING` as `starting`, though nothing started: that's how a held job is listed, and the supervisor log, which shows no new run, is the one to trust.)

Once you've checked the dump, release the job:

```console
$ vigil resolve db_dump
db_dump: run 20261120T170905Z-1068780-44 marked as over by vigil-test; the supervisor concludes it and releases the job at its next tick
(exit code 0)
```

```text
2026-11-20T17:10:15Z INFO supervisor job db_dump: hold on run 20261120T170905Z-1068780-44 released, resolved by vigil-test
```

`vigil resolve` records who confirmed the run was over, and when. It never kills anything: if the run were still going, it would go on. On a job that isn't held, it changes nothing:

```console
$ vigil resolve db_dump
vigil: db_dump is not held: there is no uncertain run to resolve
(exit code 1)
```

### Runs that never happen

These leave no run behind, so look for them in the supervisor log and the metrics.

**Skipped: the last run was still going.** `warehouse_load` made to take 75 seconds, on a one-minute schedule:

```text
2026-11-20T17:13:06Z INFO supervisor job warehouse_load: slot 2026-11-20T17:13:00Z skipped: a run is still active
```

counted in `<metric>.skipped`. A skip isn't a failure. With `overlap = queue_one`, one run waits instead and starts when the active one ends.

**Missed: the supervisor was down.** As [above](#the-supervisor-stops-or-restarts): `slot ... missed`, counted in `<metric>.missed`.

**Abandoned: the worker never started.** The supervisor writes a launch record, then starts the worker. If the worker never claims the record, the supervisor waits 30 seconds, then abandons the launch. The job didn't run, and it runs again at its next slot. Here a supervisor was made to crash right after writing a launch record, with a crash point Vigil has for its own tests (`VIGIL_FAULT`, never for production), and a normal one started after it:

```text
2026-11-20T17:14:00Z INFO supervisor supervisor started, pid 1167063
2026-11-20T17:14:00Z WARN supervisor VIGIL_FAULT is set (launch.after_record): crash points are for tests only
2026-11-20T17:14:01Z INFO supervisor configuration loaded
2026-11-20T17:14:01Z INFO supervisor supervisor started, pid 1167118
2026-11-20T17:14:31Z WARN supervisor job orders_export: launch 20261120T171401Z-1167063-1 abandoned: its worker never claimed it
2026-11-20T17:15:01Z INFO supervisor job orders_export: run 20261120T171502Z-1167118-7 started
```

```text
shop_orders_export_abandoned_launches_total{host="fedora",instance="db-01",job="orders_export",os="linux"} 1
```

**A script that isn't there: `failed`, with the reason.** `invoice_sync` was added to the configuration before its script was copied in. Each run fails without starting anything, until the file arrives:

```text
2026-11-20T17:13:07Z 20261120T171306Z-1068780-81 run start
2026-11-20T17:13:07Z 20261120T171306Z-1068780-81 run end failed (file not found: /home/vigil-test/docfail/root/scripts/invoice_sync.sh) in 0s, cpu 0.24s
2026-11-20T17:15:02Z 20261120T171502Z-1167118-10 run start
2026-11-20T17:15:02Z 20261120T171502Z-1167118-10 out 3 invoices synced
2026-11-20T17:15:02Z 20261120T171502Z-1167118-10 out metric invoices_synced 3
2026-11-20T17:15:02Z 20261120T171502Z-1167118-10 run end succeeded in 0s, cpu 0.24s
```

The failure has no exit code, since nothing ran, so `failures` has no `exit_code` tag. `vigil precheck` reports a missing file before the first run does. (A script fetched from a [source](README.md#sources) is different: until it's fetched, the job is listed under `FILE MISSING` and doesn't run at all.)

**A job that isn't valid.** A mistake in one job's section sets that job aside: it's listed under `INVALID` with the reason, `<metric>.invalid_config` is `1`, and it doesn't run until the section is fixed. The other jobs carry on. A mistake outside any job rejects the whole edit, and the last good configuration keeps running.

---

## What Vigil does by itself, and what needs you

| When | Vigil, by itself | You |
| --- | --- | --- |
| A script fails | Records `failed`, the exit code and the output; counts it; runs the job again at its next time | Read the job log, fix the cause, `vigil run <job>` if it can't wait |
| A script hangs | Stops it at `max_runtime` (once it's proven to be the run's), records `timed_out` | Find out why it hung. Set `max_runtime` on jobs that have none |
| A worker is killed | Records `crashed`; runs the job again at its next time, not at once | Read the run's `.out` and `.err`, check what it changed, rerun if needed |
| A worker dies, its script lives on | Starts nothing beside it; records `crashed` when it ends | As for a crash |
| The supervisor stops | Running jobs finish and record themselves; on its return, late runs start within `late_start_window`, older ones are recorded `missed` | Restart it (the service manager does, in system mode) |
| The machine reboots | Concludes every run from before the boot; schedules as normal | Nothing, usually |
| A run is uncertain | Holds the job, reports it every tick, kills nothing; under `wait` releases it when the evidence settles | Under `manual`, check the run's work, then `vigil resolve <job>` |
| A slot is skipped, missed or abandoned | Logs it and counts it | Nothing, unless it keeps happening |
| A metrics backend is down | Keeps the events in the spool and retries, backing off; drops events only once the spool reaches `[spool] max_mb`, and counts every drop | Fix the backend |

---

## What Vigil doesn't do

Plainly, so nobody is surprised at 3 AM:

- **No retries.** A failed run isn't retried. The job runs again at its next scheduled time, or when you run `vigil run`. If you want a retry, put it in the script.
- **No alerts.** Vigil doesn't send email, pages or chat messages. It sends metrics (and, if you ask, its own logs) to your monitoring, and the alert rules live there.
- **No replay.** `vigil run` starts a new run of the job as it is now. It doesn't restore the failed run's time, data or environment.
- **No run history command.** The state file has the latest run. The history is the job log (grep it for `run end`) and your backend's metrics.
- **No exactly-once guarantee for what a script does.** Vigil never starts a run twice by accident, but a run that crashed halfway may have done half its work. Scripts that need stronger guarantees make themselves safe to rerun.
- **No killing on suspicion.** If Vigil can't prove a process belongs to a run, it doesn't touch it, even past `max_runtime`. It holds the job and tells you instead.
- **No live output in the job log.** A run's output is copied into the job log when it ends. Until then it's in `logs/jobs/<job>/<run id>.out` and `.err`.

---

## Vigil beside cron, Task Scheduler and your monitoring

cron starts a command at a time. What happens after that is up to the command: whether its exit code is kept, where its output goes (by default, mailed to the job's owner, if the machine can send mail), what stops it if it hangs, and what stops a second copy starting beside it. Task Scheduler does more: it keeps a task's last result and, with history turned on, an event log, and it can stop a task that runs too long and restart one that fails.

Vigil starts the command too, on its own schedule (it doesn't hand jobs to cron or Task Scheduler). What it adds is the part after the start, the same on Windows, Linux and macOS:

- **Every run remembered:** a run id, the outcome and reason, the exit code, times, duration and CPU, and everything it printed, on disk, through supervisor restarts.
- **Supervision:** one run of a job at a time, `max_runtime` enforced only on processes proven to be the run's, and runs that outlive a supervisor restart accounted for.
- **Failures reported, not hidden:** crashed, timed-out, skipped, missed and abandoned runs are each logged and counted, never silently dropped.
- **Telemetry to what you already run:** metrics to Prometheus (through node_exporter's textfile collector), OTLP, Datadog or Splunk, so failures land on the dashboards and alert rules you already have.

It doesn't have to replace anything. Keep cron or Task Scheduler for what they already do well, move the jobs you need to watch closely to Vigil, and keep your monitoring where it is. [Why Vigil?](WHY.md) says more about where it fits.

---

## Try it yourself

From a clone on Linux or macOS (on Windows, `app\vigil.ps1` with `-Root`, and PowerShell scripts):

```sh
app/vigil --root ~/vigil-fail init --instance db-01 --backend file --no-pack
mkdir -p ~/vigil-fail/scripts
# Copy the scripts above into ~/vigil-fail/scripts, and add their [job.*]
# sections to ~/vigil-fail/config/vigil.config.
app/vigil --root ~/vigil-fail precheck
app/vigil --root ~/vigil-fail supervise     # Ctrl+C stops it; running jobs carry on
```

Then, from another terminal, watch it with `app/vigil --root ~/vigil-fail status --watch`, and read `logs/`, `state/jobs/` and `metrics/vigil.prom` under the root. To make a crash or an orphan, `kill -9` a run's worker (its pid is `worker_pid` in the state file) with or without its job; to see a missed slot, stop the supervisor across a job's time.

[SPECIFICATION.md](SPECIFICATION.md) has the full rules: outcomes (§10), recovery (§11), state (§12), logs and `jobs.log` (§13), metrics (§14) and failure behaviour (§21).
