# Vigil

**A job scheduler, supervisor and metrics forwarder for Windows, Linux and macOS, written only in the shells that ship with each one.**

Vigil runs your scripts on a schedule, watches every run from start to finish, and sends what happened to the monitoring system you already use. There is nothing to compile and no runtime to install: Windows PowerShell 5.1 on Windows, and bash 3.2 or later on Linux and macOS. The only binary in the project is NSSM, used on Windows to register a service.

```text
   your scripts            Vigil                         your observability stack
 +-------------+    +--------------------+          +------------------------------+
 | disk.sh     |    | schedules them     |  metrics | Prometheus / node_exporter   |
 | backup.sql  |--->| runs and supervises|--------->| Datadog, OTLP, Splunk, ...   |
 | check.ps1   |    | records every run  |   logs   | (dashboards, alerts, search) |
 | Report.jar  |    | forwards evidence  |--------->|                              |
 +-------------+    +--------------------+          +------------------------------+
```

Vigil runs the work, records the work, and forwards the evidence. Storage, dashboards and alerting stay with the tools built for them.

> **Status: early pre-release (v0.1.x).** Scheduling, supervision, recovery and the `file` metrics backend work end to end on all three platforms. Other backends, installers, remote fetching and log forwarding are specified but not built yet. See [What works today](#what-works-today).

---

## Contents

- [Why Vigil](#why-vigil)
- [What works today](#what-works-today)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
  - [The big picture](#the-big-picture)
  - [One tick of the supervisor](#one-tick-of-the-supervisor)
  - [The life of a run](#the-life-of-a-run)
  - [Evidence: how Vigil knows a run is alive](#evidence-how-vigil-knows-a-run-is-alive)
  - [Recovery: what the supervisor concludes](#recovery-what-the-supervisor-concludes)
  - [Stopping a run that overruns](#stopping-a-run-that-overruns)
  - [Uncertain runs](#uncertain-runs)
  - [Scheduling: slots and cursors](#scheduling-slots-and-cursors)
  - [The spool and the sender](#the-spool-and-the-sender)
- [Writing jobs](#writing-jobs)
- [Configuration](#configuration)
- [Commands](#commands)
- [Files on disk](#files-on-disk)
- [Repository layout](#repository-layout)
- [Testing](#testing)
- [Design rules](#design-rules)
- [Contributing](#contributing)
- [Licence](#licence)

---

## Why Vigil

Most hosts already have a scheduler (cron, Task Scheduler, launchd). What they lack is supervision: knowing that a job ran, how long it took, how it ended, whether it is stuck, and having that reach a dashboard without a bespoke wrapper around every script.

Vigil's guiding rules:

- **Native and dependency-free.** Only the platform's own shell and tools. A host that can run a script can run Vigil.
- **Never run twice by accident.** A crash, a restart, a reboot or a damaged state file never produces a duplicate run. Every run leaves independent pieces of evidence, and Vigil acts only on what the evidence proves.
- **Never kill what it cannot prove is its own.** A run is stopped only when its process is proven to belong to it. A reused PID can never authorise a kill.
- **Workers outlive the supervisor.** Stopping, upgrading or crashing the supervisor never stops a running job.
- **Same behaviour everywhere.** The bash and PowerShell implementations are twins, held to byte-identical results by a shared test suite.
- **Local first.** Everything works without a network. Remote configuration, scripts, metrics and logs are optional layers on top.

---

## What works today

| Area | Status |
| --- | --- |
| Configuration parsing and validation, with errors by line and code | Done |
| Scheduling: `run_every`, `run_at`, `run_on_days`, missed runs, `late_start_window` | Done |
| Concurrency: `max_concurrent`, pending queue, overlap `skip` / `queue_one` | Done |
| Workers: runners, arguments, environment, stdout/stderr capture, job logs | Done |
| Outcomes: `standard`, `nagios`, explicit exit-code lists | Done |
| Metrics from job output: `metric` lines and Nagios performance data | Done |
| Supervisor: tick loop, hot reload, single-instance lock, `jobs.log` | Done |
| Recovery from crashes, restarts, reboots and damaged state | Done |
| `max_runtime` with ownership-checked process-tree termination | Done |
| Uncertain runs: recovery records, `on_uncertain`, `vigil resolve` | Done |
| Spool with write-ahead fan-out, size cap, per-backend backoff | Done |
| Backend: `file` (Prometheus text format, for node_exporter / windows_exporter) | Done |
| Backends: Datadog, OTLP, Splunk and the rest | Specified, not built |
| `vigil precheck`: every configuration problem, pre-flight checks, effective settings | Done |
| Installers, service registration, `vigil init` | Specified, not built |
| Fetching configuration and scripts from git, https, sftp, shares | Validated, not fetched yet |
| Forwarding Vigil's own logs (OTLP) | Specified, not built |
| Secrets for jobs: `env:`, `secret:` (Vigil's store, `vigil secret`), `store:` with a `helper` | Done |
| Secret stores: HashiCorp Vault, Azure Key Vault, AWS Secrets Manager, GCP Secret Manager, over HTTPS with curl (and openssl) or .NET | Done |

---

## Quick start

Vigil does not have installers yet. You can run it straight from a clone: every command takes `--root` (`-Root` on Windows), the folder holding `config/`, `state/`, `logs/` and so on.

**1. Make a root and a job.**

```sh
mkdir -p ~/vigil-demo/config ~/vigil-demo/scripts
cat > ~/vigil-demo/scripts/disk.sh <<'EOF'
used=$(df -P / | awk 'NR==2 { sub("%", "", $5); print $5 }')
echo "metric root_used_pct $used"
EOF
```

**2. Write `config/vigil.config`.**

```ini
[vigil]
instance = demo

[backend.file]
path = metrics/vigil.prom

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.disk]
metric_name = os.disk
file        = scripts/disk.sh
run_every   = 1m
max_runtime = 30s
```

**3. Check it, run the job once, then start the supervisor.**

```sh
cd vigil                                   # the clone
app/vigil --root ~/vigil-demo precheck     # every problem, changing nothing
app/vigil --root ~/vigil-demo run disk     # one run, in the foreground
app/vigil --root ~/vigil-demo supervise    # tick until stopped (Ctrl+C)
```

On Windows the steps are the same, with a Windows job. For example, `scripts\disk.ps1` run through a `powershell.exe` runner mapped to `.ps1` (see [`tests/mocks/simple/windows.config`](tests/mocks/simple/windows.config)):

```powershell
.\app\vigil.ps1 -Root C:\vigil-demo precheck
.\app\vigil.ps1 -Root C:\vigil-demo run disk
.\app\vigil.ps1 -Root C:\vigil-demo supervise
```

**4. Look at the results.**

```text
~/vigil-demo/logs/supervisor/jobs.log      what every job is doing, rewritten every tick
~/vigil-demo/logs/jobs/disk/<date>.log     each run's start, output and end
~/vigil-demo/state/jobs/disk.state         the last run, as recorded
~/vigil-demo/metrics/vigil.prom            metrics, ready for node_exporter's textfile collector
```

```text
# TYPE os_disk_root_used_pct gauge
os_disk_root_used_pct{host="web01",instance="demo",job="disk",os="linux"} 41
# TYPE os_disk_runs_total counter
os_disk_runs_total{host="web01",instance="demo",job="disk",os="linux"} 12
# TYPE os_disk_succeeded_total counter
os_disk_succeeded_total{host="web01",instance="demo",job="disk",os="linux"} 12
```

Annotated example configurations covering every feature are in [`tests/mocks/`](tests/mocks/): `simple/` (everything local), `mixed/` (some scripts fetched) and `advanced/` (configuration fetched from a source).

---

## How it works

### The big picture

Vigil is a handful of cooperating processes that talk **only through files**. There are no sockets, pipes or shared memory between them, which is what lets each one crash, restart or be upgraded without taking the others down.

```text
                         +---------------------------------------------------------+
                         |                          host                           |
                         |                                                         |
  config/vigil.config -->|  SUPERVISOR  (long-running; the OS service runs it)     |
                         |   every tick:                                           |
                         |     reload config if changed                            |
                         |     account for every job's last run   <-- reads ----+  |
                         |     decide each job's schedule                      |  |
                         |     admit due runs within max_concurrent            |  |
                         |     write launch record, start worker (detached)    |  |
                         |     stop runs past max_runtime (if proven theirs)   |  |
                         |     write jobs.log and its own metrics              |  |
                         |        |                                            |  |
                         |        | spawns, detached                           |  |
                         |        v                                            |  |
                         |  WORKER  (one process per run)                      |  |
                         |     claims the launch, holds the run token ---------+  |
                         |     runs the job through its runner                  |  |
                         |     captures stdout/stderr to the job log            |  |
                         |     parses metrics, classifies the outcome           |  |
                         |     writes events --> spool/incoming/                |  |
                         |     writes final state --> state/jobs/<job>.state ---+  |
                         |                                                         |
                         |  SENDER  (vigil_sender, a worker like any other)        |
                         |     fans spool files out to one queue per backend       |
                         |     delivers each queue, backing off a failing backend --+--> backends
                         +---------------------------------------------------------+
```

| Component | Lives | Owns |
| --- | --- | --- |
| Supervisor | As long as the service | `state/supervisor.lock`, schedule cursors, recovery records, `jobs.log` |
| Worker | One run | That run's token and the job's state file while the run is alive |
| Sender | One delivery pass | `spool/fanout/`, `spool/backends/`, backend backoff state |

The supervisor never runs a job itself, and a worker never talks to a backend. A slow backend can therefore never delay a job, and a slow job can never delay the scheduler.

### One tick of the supervisor

The supervisor wakes once per `[scheduler] tick` (default `60s`) and does the same thing every time:

```text
 tick ---+
         v
 +----------------------------+   unchanged: keep the active configuration
 | config/vigil.config changed?|-- invalid:  reject it, keep the last valid one (state/config.valid)
 +----------------------------+   valid:     activate it
         |
         v
 for each job ------------------------------------------------------------------+
 |                                                                             |
 |  1. ACCOUNT    gather evidence about its latest run, conclude what it is    |
 |                (alive / launching / finished / crashed / abandon /          |
 |                 uncertain / idle)                                           |
 |                record finished or crashed runs; abandon stale launches;     |
 |                stop a run past max_runtime if it is proven to be the run's  |
 |                                                                             |
 |  2. SCHEDULE   decide: disabled / new / wait / missed / run / queue / skip  |
 |                move and save the job's cursor                               |
 +------------------------------------------------------------------------------+
         |
         v
 3. ADMIT      start pending runs, oldest first, while workers < max_concurrent;
               beyond max_pending, runs are skipped and counted
         |
         v
 4. SENDER     start one if the spool holds anything and none is running
         |
         v
 5. REPORT     write logs/supervisor/jobs.log and spool/incoming/<epoch>-vigil_supervisor.events
         |
         v
       sleep until the next tick
```

One bad tick never stops the supervisor: it carries on at the next tick (on Windows the error is also logged).

### The life of a run

Evidence of a run must exist **before** its process does. Otherwise a supervisor that crashed halfway through starting a worker could not tell "never started" from "started and running", and might start it again.

```text
 SUPERVISOR                         FILESYSTEM (state/locks/)                 WORKER                      JOB
 ----------                         -------------------------                 ------                      ---
 generate run id
 write launch record  ------------> disk.<run>.launch
 start worker (detached,
   --run-id <run>)  ----------------------------------------------------------> starts
                                                                              open launch record
                                    disk.<run>.launch                         rename it (POSIX) or
                                          |  CLAIM: exactly one winner        hand over hand (Windows)
                                          v
                                    disk.<run>.token  <======== held open for the worker's whole life
                                                                              write state: running,
                                                                              deadline, identities
                                                                              start the job ----------->  runs
                                                                              (own process group on        (inherits
                                                                               Linux/macOS)                 VIGIL_RUN_ID, and
                                                                                                            on Linux/macOS
                                                                                                            the token)
                                                                              capture stdout/stderr  <---  prints, exits
                                                                              parse metrics, classify
                                                                              write events -> spool/incoming/
                                                                              write final state
                                    disk.<run>.token  deleted                 close and delete token, exit
```

The claim is a race with exactly one winner. If the supervisor decides a launch has been sitting unclaimed too long (past the 120-second grace), it abandons it with the same filesystem operation the worker uses to claim it, so one side always wins and the other knows it lost:

```text
                      disk.<run>.launch
                       /             \
   worker claims:     /               \     supervisor abandons:
   rename -> .token  /                 \    rename -> .abandoned  (Windows: delete)
   (Windows: open   /                   \
    exclusively)   v                     v
          winner runs the job      winner records "abandoned launch";
          loser exits, no run      loser treats the run as alive
```

Note the ordering at the end: events reach the spool **before** the final state is written. If the worker dies between the two, the spool file still proves how the run ended.

### Evidence: how Vigil knows a run is alive

State files can be stale, truncated or deleted, and PIDs get reused. So Vigil never trusts any single fact. Every run leaves several independent pieces of evidence:

```text
                                +--------------------------------------+
   launch record  ------------->|                                      |
   (a run was launched)         |                                      |
                                |                                      |
   run token  ----------------->|                                      |
   (held open = worker alive;   |                                      |
    the OS releases it however  |                                      |
    the worker dies)            |      RECOVERY CONCLUSION             |
                                |      (a pure function, tested        |
   run id on a command line --->|       from a shared table)           |---> alive
   (this process is the run's   |                                      |---> launching
    worker; a reused PID can    |                                      |---> finished
    never match)                |                                      |---> crashed
                                |                                      |---> abandon
   boot id  ------------------->|                                      |---> uncertain
   (an earlier boot means every |                                      |---> idle
    process of the run is gone) |                                      |
                                |                                      |
   state file  ---------------->|                                      |
   (what the worker recorded)   |                                      |
                                |                                      |
   spool file  ---------------->|                                      |
   (how the run ended, even if  |                                      |
    its final state was lost)   +--------------------------------------+
```

How each piece is read:

| Evidence | Linux | macOS | Windows |
| --- | --- | --- | --- |
| Token held | `/proc/<pid>/fd` links | `lsof -t <token>` | an exclusive open fails |
| Run id on a command line | `/proc/<pid>/cmdline` | `ps -o args=` | `Win32_Process.CommandLine` |
| Boot id | `/proc/sys/kernel/random/boot_id` | `sysctl kern.boottime` | last boot time |

### Recovery: what the supervisor concludes

Each tick, for each job, the supervisor turns the evidence into exactly one conclusion. A launch record is always checked first, and nothing is concluded "over" while any evidence says the run may still be alive:

```text
 launch record present?
 |-- held by a worker ...................................... ALIVE (being claimed)
 |-- from an earlier boot .................................. ABANDON
 |-- younger than the 120 s grace .......................... LAUNCHING (hold, start nothing)
 '-- older than the grace
       |-- a process carries the run id .................... LAUNCHING (slow worker)
       |-- no such process ................................. ABANDON
       '-- the probe failed ................................ UNCERTAIN

 no launch record:
 |-- no token, and state final or missing .................. IDLE (nothing to account for)
 |-- run from an earlier boot
 |     |-- outcome in state or spool ....................... FINISHED
 |     '-- no outcome ...................................... CRASHED
 |-- token held, or a process carries the run id ........... ALIVE
 |-- the probe failed ...................................... UNCERTAIN
 |-- outcome in state or spool ............................. FINISHED (reconciled)
 '-- otherwise ............................................. CRASHED (worker vanished)
```

| Conclusion | What the supervisor does |
| --- | --- |
| alive / launching | Treats the job as running; never starts another run of it |
| finished | Records the outcome (from the spool file if the state was lost); cleans up |
| crashed | Records `crashed`, posts `<metric>.crashes`; the job runs again at its next slot |
| abandon | Abandons the launch; the job never ran; posts `<metric>.abandoned_launches` |
| uncertain | Holds the job, reports it every tick, kills nothing (see [Uncertain runs](#uncertain-runs)) |
| idle | Schedules normally |

The supervisor writes a job's state file only once it has proven the worker can no longer write it. While a run may be alive, the worker is the only writer.

### Stopping a run that overruns

`max_runtime` is optional. When set, the worker records a deadline, and the supervisor checks it every tick. Vigil terminates a process only after proving it belongs to the run:

```text
 run past its deadline
        |
        v
 prove the job process is the run's
 |-- Linux/macOS: the job process holds the run token (it inherited it)
 '-- Windows:     PID, process name and start time match the state file,
                  and its parent is the worker (while the worker lives)
        |
   proven? ---- no ---> UNCERTAIN: hold the job, report it, kill nothing
        |
       yes
        v
 write state/locks/<job>.<run>.timeout     <- tells the worker why its job ended
        |
        |-- Linux/macOS: TERM to the job's process group,
        |                KILL on a later tick once `grace` has passed
        '-- Windows:     taskkill /T /F (no TERM exists for console programs)
        |
        v
 the worker sees its job exit, finds the marker,
 records `timed_out` and posts <metric>.timeouts (not a failure)
```

The worker itself is never killed: it stays alive to record the outcome. If the worker has gone too, the supervisor records `timed_out` itself.

### Uncertain runs

Sometimes the evidence cannot settle the question: a probe fails, or a run overruns but its process cannot be proven to be its own. Vigil then treats the run as **uncertain**. It writes a recovery record (`state/recovery/<job>.recovery`) that survives restarts, lists the job under `UNCERTAIN` in `jobs.log` with the reason, posts `<metric>.uncertain` every tick, and **never kills anything**.

What happens next is the job's `on_uncertain` policy:

```text
                       evidence becomes conclusive
   +-----------+  -------------------------------------->  +-----------------------+
   | UNCERTAIN |                                           | concluded: finished / |
   +-----------+  <--- still unclear: reported every tick  | crashed / alive       |
        |                                                  +-----------------------+
        |                                                     |          |
        |  wait     (default) job held ---------------------->|          |  wait, replace:
        |  replace  new runs start anyway, each posting       |          |  record deleted,
        |           <metric>.possible_duplicates ------------>|          |  job released
        |  manual   job held -------------------------------->|          |
        |                                                     |          |  manual:
        |                                                     v          |  still held
        |                                         +------------------------+
        +---- vigil resolve <job> --------------->| run concluded, record  |
              (operator confirms it is over;      | deleted, job released  |
               nothing is killed)                 +------------------------+
```

- **`wait`** suits most jobs.
- **`replace`** suits cheap, idempotent checks such as pings, disk usage or HTTP probes.
- **`manual`** suits jobs whose half-finished effects someone should inspect first: dumps, loads, transfers.

### Scheduling: slots and cursors

Every scheduled time is a **slot**. `run_every` slots are aligned to UTC (`5m` means :00, :05, :10, ...); `run_at` slots are local wall-clock times. Each job has a **cursor**, the last slot it dealt with, saved in `state/schedule/<job>.cursor`.

```text
 run_every = 5m                       now
                                       |
   ---|-------|-------|-------|-------|-|-----|-------> time
     :00     :05     :10     :15     :20  ^  :25
                      ^               ^   |
                    cursor        due slot  next slot
                 (last dealt with) (after the cursor, at or before now)
```

Each tick a job reaches exactly one decision:

| Decision | When | Cursor afterwards |
| --- | --- | --- |
| `disabled` | `enabled = false` | deleted |
| `new` | no cursor yet: a new job never runs immediately | now |
| `wait` | no slot is due | unchanged |
| `missed` | the due slot is too old (Vigil was down past `late_start_window`) | the slot |
| `run` | on time, and no run of the job is active | the slot |
| `queue` | on time, a run is active, `overlap = queue_one`, none queued yet | the slot |
| `skip` | on time and a run is active | the slot |

When several slots are due, only the latest counts: a restart never triggers a backlog of old runs. The decision is a pure function of its inputs, so it is tested as a table without waiting for real time to pass.

### The spool and the sender

Workers never talk to backends. They drop a file of events into `spool/incoming/` and exit. The sender (`vigil_sender`, started by the supervisor whenever the spool holds anything) moves each file through a **write-ahead fan-out**, so an interruption at any point can duplicate an event but never lose one:

```text
 spool/incoming/<epoch>-<job>-<run>.events            (written atomically by a worker)
        |
        |  1. CLAIM    rename into fanout/
        v
 spool/fanout/<f>
        |  2. TARGETS  write <f>.targets: the job's backends, fixed now, so a
        |              config reload in between cannot change where events go
        |  3. PLACE    for each target: copy to a temp name in its queue,
        |              rename into place, then create <f>.<backend>.done
        |  4. RETIRE   all targets done: delete <f>, its targets and markers
        v
 spool/backends/file/<f>      spool/backends/datadog/<f>      ...  (one queue per backend)
        |                             |
        v                             v
 DELIVER each queue on its own: up to 500 files as one request;
   success  -> delete the files
   failure  -> keep them, back off that backend only (5 s doubling to 5 min)
```

On every start the sender first resumes any unfinished fan-out, skipping targets already marked done. A dead backend delays only its own queue. The spool is capped by `[spool] max_mb`; when full, the oldest (or newest) queued files are dropped and counted in `vigil.spool.dropped`, never silently.

The **`file` backend** merges each batch into one Prometheus text file: gauges keep their latest value and counts become running `_total` counters. The file always holds the current state, so it stays small however long Vigil runs.

Today `file` is the only backend type that delivers. Events for an enabled backend of any other type are not queued: they are counted in `vigil.spool.dropped` with `reason=not_implemented`, so the spool never fills with events that cannot yet be sent.

---

## Writing jobs

A job is any script or program. Vigil captures everything it prints. Lines in this form become metrics:

```text
metric <name> <value> [key=value ...]
```

```sh
echo "metric rows_exported 1200 table=orders"
echo "metric lag_seconds 0.25"
```

These are posted as `<metric_name>.<name>`, with the job's tags plus the line's own. Everything else is simply logged. Numbers are handled as exact decimals on every platform, never floating point.

**Nagios plugins work unchanged.** With `exit_codes = nagios`, exit codes 0, 1, 2 and 3 map to succeeded, warning, failed and unknown, and the performance data after `|` is parsed, with units normalised (`11700MB` becomes `12268339200` bytes, `250ms` becomes `0.25` seconds):

```text
DISK OK - free space: / 7800 MB (40%) | /=11700MB;15600;17550;0;19500
```

Every run also posts its own metrics, whatever the job prints:

| Metric | Type | When |
| --- | --- | --- |
| `<m>.duration_seconds` | gauge | every completed run |
| `<m>.runs` | count | every run |
| `<m>.succeeded` / `.warnings` / `.failures` | count | by outcome (`.failures` tagged `exit_code`) |
| `<m>.timeouts` | count | stopped for `max_runtime` |
| `<m>.crashes` | count | the worker vanished without an outcome |
| `<m>.skipped` / `.missed` | count | overlap skip, or missed while Vigil was down |
| `<m>.running` | gauge | elapsed seconds, every tick while running |
| `<m>.uncertain` | gauge | `1` every tick while a run is uncertain |

Every metric carries `host`, `os` and `instance` tags plus your `[tags]`. A job's metrics also carry `job` and the job's own `tag` lines.

---

## Configuration

One instance has one configuration file, `config/vigil.config`, in a plain `key = value` format with `[sections]`. The same parser runs on every platform.

```ini
# instance names the deployment and becomes the "instance" tag;
# max_concurrent caps running workers across all jobs.
[vigil]
instance       = db01
max_concurrent = 5

# late_start_window: how late a missed run may still start.
[scheduler]
tick              = 60s
late_start_window = 15m

# Added to every metric.
[tags]
env = production

[backend.file]
path = metrics/vigil.prom

# {file} is replaced by the job's file.
[runner.psql]
command = /usr/bin/psql
arg     = -X
arg     = -f
arg     = {file}

# .sql files run through psql unless a job says otherwise.
[runners]
.sql = psql

# grace: time between TERM and KILL when max_runtime stops a run.
[defaults]
grace   = 30s
overlap = skip

# require_env: must be set in the service environment, or the run fails.
[job.backup]
metric_name  = db.backup
file         = sql/backup.sql
run_at       = 01:00, 13:00
run_on_days  = mon, tue, wed, thu, fri
max_runtime  = 2h
on_uncertain = manual
tag          = team=dba
env          = PGHOST=localhost
require_env  = PGPASSWORD
```

Comments are whole lines starting with `#` or `;`. There are no inline comments: a `#` or `;` inside a value is part of the value.

| Section | Purpose |
| --- | --- |
| `[vigil]` | Instance name, state directory, global concurrency, and optionally where to fetch the configuration from |
| `[scheduler]` | Tick, late-start window, pending limit |
| `[log]`, `[spool]` | Log and spool locations, retention and size caps |
| `[tags]` | Tags added to every metric |
| `[backend.<name>]` | A metrics destination |
| `[runner.<name>]`, `[runners]` | Reusable command prefixes, and file extension to runner mapping |
| `[source.<name>]` | A place scripts (or the whole configuration) are fetched from |
| `[defaults]` | Defaults for any overridable job key |
| `[job.<id>]` | One scheduled job |
| `[log_forward]`, `[log_destination.<name>]` | Optional forwarding of Vigil's own logs |
| `[secret_store.<name>]` | An external secret store, for `store:` references |

### Secrets

Secrets are never written in the configuration file. Every credential is a **reference** that names where its value comes from:

```ini
# From the service's environment.
[backend.datadog]
api_key = env:DATADOG_API_KEY

# From Vigil's own secret store on the host.
[backend.splunk]
token = secret:SPLUNK_HEC_TOKEN

# From an external secret store.
[backend.datadog_eu]
type    = datadog
api_key = store:ops_kv/datadog-eu-key

[secret_store.ops_kv]
type  = azure_keyvault
vault = https://ops-kv.vault.azure.net/
auth  = managed_identity

# A secret put into one job's environment when it runs.
[job.backup]
file      = sql/backup.sql
run_every = 1h
secret    = PGPASSWORD=secret:PGPASSWORD
```

```text
                       where the value lives               a changed value is used
 env:NAME     -->  the service's environment          --> Windows: next run (read from the registry)
                                                           Linux/macOS: when Vigil is next started
 secret:NAME  -->  config/secrets/NAME, owner-only;   --> next run, every platform
                   DPAPI-encrypted on Windows;
                   set with `vigil secret set NAME`
 store:S/NAME -->  Azure Key Vault, HashiCorp Vault,  --> next run, every platform
                   AWS, GCP, or a helper command
```

- **The source is always explicit.** Vigil never searches several sources for a name, so anyone reading the configuration knows where each secret comes from.
- **Secrets are resolved when each run or delivery starts,** held in memory only, and never written to logs, state, the spool or a command line. That's why `secret:` and `store:` values can be rotated without restarting anything.
- **`env:` is the simplest.** On Linux and macOS, though, a running service can't see a changed environment variable (systemd and launchd read it once, at start), so use `secret:` or `store:` for anything you rotate.
- **A raw value is rejected at validation,** and the rejected value is never echoed.
- **A store's own credentials** must be `env:` or `secret:`, so one store never needs another to unlock it.

All three are resolved for jobs today. `store:` works with HashiCorp Vault (token or AppRole), Azure Key Vault (managed identity or service principal), AWS Secrets Manager (instance role or access keys), GCP Secret Manager (the instance's service account, or a service account key) and a `helper` command for anything else.

For Azure, AWS and GCP, the vendor's CLI (`az`, `aws`, `gcloud`) is preferred when it's installed, and Vigil's own HTTPS client is the fallback. The store's `client` key says which:

| `client` | Fetches with | Prerequisite on the server |
| --- | --- | --- |
| `auto` (default) | The vendor's CLI if it's on Vigil's `PATH` and can sign in that way, otherwise Vigil's own HTTPS | Nothing beyond `http`'s |
| `cli` | The vendor's CLI, always | **The vendor's CLI, installed and signed in as the service account** (for az: `az login --identity`) |
| `http` | Vigil's own HTTPS, always | Linux and macOS: `curl`, plus `openssl` for AWS and GCP. Windows: nothing |

The CLI is used only where it can sign in without keeping a credential on disk: Azure managed identity, AWS instance role or access keys (passed in its environment, never its arguments), GCP instance service account. `vigil precheck` shows which one each store uses and why. HashiCorp Vault always uses Vigil's own HTTPS.

Vigil's own HTTPS client needs no vendor CLI: it calls the APIs itself, with `curl` on Linux and macOS (tokens and keys reach curl and openssl through pipes, never a command line or a file) and .NET on Windows. For a Vault behind a private CA, point `ca_file` at the CA's certificate:

```ini
[secret_store.vault]
type      = hashicorp_vault
url       = https://vault.internal:8200
auth      = approle
role_id   = 0f6c2b7e-vigil
secret_id = secret:VAULT_SECRET_ID
ca_file   = config/vault-ca.pem

[job.backup]
file      = sql/backup.sql
run_every = 1h
secret    = PGPASSWORD=store:vault/db/backup
```

`vigil precheck` fetches every store secret a job uses, and shows only the references, so a wrong token or an unreachable vault shows up before the first run does.

On Windows, keep in mind that the store is encrypted for the account that ran `vigil secret set`: run it as the service account. Under WSL, install Vigil inside the Linux filesystem, not under `/mnt/c`, where every file looks readable by everyone and Vigil refuses to use secrets kept there.

**Changes apply without a restart.** The file is checked every tick. A valid change becomes active at once; an invalid one is rejected with every error listed, and the last valid configuration keeps running. A single invalid job is skipped and reported, while the others keep running.

The full reference is in [`SPECIFICATION.md`](SPECIFICATION.md) (§6), and [`tests/mocks/`](tests/mocks/) has annotated examples of every key.

---

## Commands

| Command | What it does |
| --- | --- |
| `vigil supervise [--once]` | The supervisor: what the service runs. `--once` runs a single tick. |
| `vigil run <job>` | Runs one job now, in the foreground, recorded exactly as a scheduled run would be. Exits 0 succeeded, 1 warning, 2 failed, 3 unknown, 4 not run. |
| `vigil resolve <job>` | Confirms that the uncertain run holding a job is over. Never kills anything. |
| `vigil precheck [<job>]` | Checks everything without starting or changing anything: every configuration problem with its line, then each job's file, runner, working folder, secrets and required variables, store credentials and writable folders. With a job, also its effective settings and where each came from. Exits 0 when nothing failed. |
| `vigil secret set <NAME>` / `list` / `delete <NAME>` | Manages Vigil's own secret store. `set` prompts without echoing, or reads `--stdin` for deployment tools; `list` never shows values. |

On Linux and macOS the command is `app/vigil`; on Windows it is `app\vigil.ps1`. All take `--root <dir>` (`-Root <dir>` on Windows), defaulting to the folder that contains `app/`.

---

## Files on disk

Everything lives under one root, so uninstalling is a single delete:

```text
<root>/
  app/                          Vigil itself (replaced on upgrade)
    vigil, vigil.ps1              the command (Linux/macOS, Windows)
    lib/posix/                    the bash implementation
    lib/windows/                  the PowerShell implementation
  config/
    vigil.config                  your configuration (never overwritten)
    secrets/<NAME>                Vigil's secret store: owner-only; DPAPI-encrypted on Windows
  scripts/                      your job scripts (never overwritten)
  state/
    supervisor.lock               held open by the live supervisor
    config.valid                  the last valid configuration
    jobs/<job>.state              each job's last run: status, times, identities, summary
    locks/<job>.<run>.launch      a run launched, not yet claimed
    locks/<job>.<run>.token       held open by the live worker
    locks/<job>.<run>.timeout     a run being stopped for max_runtime
    schedule/<job>.cursor         the last slot each job dealt with
    recovery/<job>.recovery       why a job is held (uncertain runs)
    backends/<name>.state         a failing backend's backoff
  logs/
    supervisor/<date>.log         what the supervisor did
    supervisor/jobs.log           the live status view, rewritten every tick
    jobs/<job>/<date>.log         each run: start, stdout, stderr, end
  spool/
    incoming/                     events waiting for the sender
    fanout/                       fan-outs in progress
    backends/<name>/              each backend's delivery queue
  metrics/vigil.prom            the file backend's output (configurable)
```

Every state, cursor and record file is written to a temporary name and renamed into place, so a reader never sees a half-written file. A job log line reads:

```text
2026-10-30T15:07:35Z 20261030T150733Z-16052 out metric rows 5 table=orders
<UTC time>           <run id>               <run|out|err> <text>
```

---

## Repository layout

```text
app/
  vigil                 the command, Linux/macOS (bash)
  vigil.ps1             the command, Windows (PowerShell)
  lib/posix/            bash implementation        config.sh, schedule.sh, worker.sh, ...
  lib/windows/          PowerShell implementation  Config.ps1, Schedule.ps1, Worker.ps1, ...
tests/
  run-conformance.sh    shared conformance suite, bash runner
  Run-Conformance.ps1   shared conformance suite, PowerShell runner
  conformance/          the shared cases: inputs and expected outputs
  integration/          end-to-end tests that run real jobs and a real supervisor
  mocks/                annotated example configurations, also tested
tools/docs/             the documentation site generator (build.sh) and publisher (publish.sh)
SPECIFICATION.md        the full design: what Vigil does and why
VISION.md               the product vision
```

Every file in `lib/posix/` has a twin of the same name in `lib/windows/` (`config.sh` and `Config.ps1`). Each follows its own platform's naming convention, and the two must behave identically.

**Documentation site.** <https://godspeedhq.github.io/vigil/> is generated from the repository: this README, the specification (a page per section), the commands from their own usage text, every validator error code with its meaning and the tests that cover it, the test inventory, the example configurations and the backlog. Nothing on it is edited by hand. To update it after merging to main:

```sh
bash tools/docs/build.sh            # optional: generate into .site/ to look at locally
bash tools/docs/publish.sh          # regenerate from main and publish (needs gh)
```

---

## Testing

Two layers keep the twins honest.

**Conformance.** The suite in `tests/conformance/` feeds the same inputs to both implementations and requires byte-identical output: configuration parsing and validation, effective settings, command lines, schedule decisions, outcomes, metric parsing, run events, recovery conclusions, the `file` backend merge, and every example configuration.

```sh
bash tests/run-conformance.sh              # Linux, macOS, Git Bash
pwsh tests/Run-Conformance.ps1             # PowerShell 7
powershell -File tests\Run-Conformance.ps1 # Windows PowerShell 5.1
```

**Integration.** The tests in `tests/integration/` run real jobs and a real supervisor, then check the results end to end:
- runs, outcomes, logs and events;
- concurrency limits and overlap;
- crashes and abandoned launches;
- `max_runtime` stopping a job that ignores TERM;
- uncertain runs under each policy, with an unrelated process that must never be killed.

CI runs everything on macOS (with the system bash 3.2), Linux, Windows PowerShell 5.1 and PowerShell 7 for every pull request.

---

## Design rules

These hold everywhere in the code and are spelled out in [`SPECIFICATION.md`](SPECIFICATION.md):

- **bash 3.2 and PowerShell 5.1 are the floor.** No associative arrays, `mapfile` or `${var,,}` in bash; nothing beyond Windows PowerShell 5.1.
- **No floating point for numbers.** Values are exact decimal strings, so both platforms agree to the digit.
- **No secrets anywhere Vigil writes.** Not in logs, state, spool files or command lines.
- **Atomic writes.** A temporary file in the same directory, then a rename.
- **Evidence, not authority.** State is one piece of evidence among several; a run is concluded over only when nothing says it may be alive.
- **Ownership before termination.** Never kill by PID alone.
- **Nothing silent.** Dropped events, gaps, crashes and uncertainty are always counted and reported.

---

## Contributing

Vigil is built to make adding checks easy: a check is just a script that prints `metric` lines, or an existing Nagios plugin. Contributor guidelines are coming. Until then:

- Read the relevant section of [`SPECIFICATION.md`](SPECIFICATION.md) first. The spec leads, and code follows it.
- Change both implementations together, and add or update a conformance case that proves they agree.
- Run the conformance suite in bash and both PowerShells before opening a pull request.

---

## Licence

Vigil is released under the [Apache License 2.0](LICENSE).
