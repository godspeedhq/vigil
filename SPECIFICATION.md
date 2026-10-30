# Vigil — Technical Specification

| | |
| --- | --- |
| **Project** | Vigil |
| **Organisation** | GodspeedHQ |
| **Repository** | <https://github.com/godspeedhq/vigil> |
| **Licence** | Apache License 2.0 |
| **Status** | Proposed v1 Specification |

---

## 1. Overview

Vigil is a lightweight, cross-platform job scheduler and supervisor that runs your scripts, attaches metrics to every run and forwards them to the observability backends you already use.

It is built entirely from operating-system-native scripts. There is no compiled agent, no runtime to install and no central server. On a brand-new Windows, Linux or macOS machine, Vigil needs nothing beyond what the OS ships with, plus a short, honest list of prerequisites (§5).

Vigil:

- Runs any script or executable on a schedule: PowerShell, bash, SQL through a database client, Java, Perl, shell scripts under Cygwin, native binaries.
- Supervises every run as an independent OS process with its own state.
- Detects failures, crashes and overruns.
- Records structured logs and a live status view of every job.
- Publishes metrics about every run, plus any metrics the job itself prints, to one or many backends at once (Datadog, Splunk, OpenTelemetry, CloudWatch, Azure Monitor and others), and to a local flat file.
- Keeps working with no network and no backend.

Vigil does not interpret the metrics. It runs your scripts, adds metrics to them and forwards them. Alerting and dashboards belong to the backend the organisation already uses.

---

## 2. Design Philosophy

### 2.1 Simplicity

The supervisor must remain small, readable and maintainable by the operators who run it. Avoid frameworks, databases, background services and dependencies.

### 2.2 Native Scripts Only

Vigil is written in the scripting language each OS ships with:

| OS | Implementation language |
| --- | --- |
| Windows | Windows PowerShell 5.1 (also runs unmodified on PowerShell 7) |
| Linux | bash |
| macOS | bash (3.2 compatible — the version macOS ships) |

Vigil must not require Python, Node.js, Java, Go, containers, agents or any compiled binary of its own. The single exception is NSSM on Windows, used only to register the service (§18.1).

The motivation is adoption: plain-text scripts can be read, reviewed and approved by an IT or security team far more easily than a binary that needs scanning, whitelisting and change approval.

### 2.3 Failure Is Expected

Scripts crash, hang, exit with misleading codes or print malformed output. None of this may compromise the supervisor or unrelated jobs.

### 2.4 Bounded Execution

Concurrency is limited globally. A job may declare a runtime limit; when it does, the limit is enforced (§10.3).

### 2.5 Observable Behaviour

Every significant state transition is observable through logs, the status file and metrics. A failed job must never silently appear successful.

### 2.6 Local Autonomy

Vigil keeps scheduling and supervising with no network, no backend and no control plane. Every backend is optional.

### 2.7 Predictable Recovery

Supervisor restarts, worker crashes and machine reboots have documented recovery behaviour that does not depend on undocumented assumptions.

### 2.8 Honest Limits

Where a platform cannot guarantee something, Vigil documents the limit instead of pretending. Known limits are listed in §24.

---

## 3. Non-Goals

Vigil is not:

- A replacement for Kubernetes, systemd, launchd or the Windows Service Control Manager.
- A distributed or fleet-wide job scheduler. Each host runs independently; there is no shared state between hosts.
- An alerting, notification or dashboard system. That is the backend's job.
- An observability backend or metrics database.
- A configuration-management or deployment platform.
- A secrets manager.
- A sandbox for untrusted scripts.
- A remote command-execution platform.

---

## 4. Architecture

Vigil has four logical components. They communicate only through files.

```text
            +-------------------- host --------------------+
            |                                              |
  config -->|  Supervisor (tick loop)                      |
            |    reads config + all worker state files     |
            |    decides: spawn / wait / kill / report     |
            |      |                       ^               |
            |      | spawns (detached)     | reads (only)  |
            |      v                       |               |
            |  Worker  ---- writes ---->  state/<job>      |
            |    runs the job (runner + file)              |
            |    writes metric events --> spool/           |
            |                               |              |
            |  Sender (drains spool) <------+              |
            |    file | datadog | splunk | otel | ...  ----+--> backends
            +----------------------------------------------+
```

### 4.1 Supervisor

The long-running process managed by the OS service manager. Responsible for:

- Loading, validating and hot-reloading configuration.
- Evaluating every job once per tick.
- Spawning workers when jobs are due.
- Enforcing the global concurrency limit.
- Detecting crashed workers and overrunning jobs.
- Enforcing `max_runtime` where declared.
- Writing the live status file (`jobs.log`).
- Publishing its own health metrics.

The supervisor is job-agnostic. It knows nothing about sqlcmd, psql, PowerShell, Java or any tool a job uses.

Only one supervisor may own a given state directory (VIGIL-001).

### 4.2 Scheduler

The scheduling logic inside the supervisor. It decides, per tick, whether each job is due. It is implemented by Vigil and never delegates to cron, Windows Task Scheduler or launchd calendar intervals.

### 4.3 Worker

One worker process per job run.

**Launch.** Evidence of a run must exist before its process does, so a supervisor that crashes mid-launch can never mistake a started worker for a job that never ran. The supervisor:

1. Generates a unique run id.
2. Writes a launch record, `state/locks/<job id>.<run id>.launch` (`[launch]` section: job, run id, boot id, scheduled and launch times), atomically.
3. Only then starts the worker, passing the run id on its command line (`--run-id`) and in the environment (`VIGIL_RUN_ID`).

**Claim.** The worker takes ownership of the run by claiming the launch record, an operation that can succeed for exactly one party (§11.2):

- **Linux/macOS:** open the launch record, then rename it to `<job id>.<run id>.token`. The open descriptor follows the file, so it is held under its new name without a gap.
- **Windows:** open the launch record exclusively, create and exclusively hold `<job id>.<run id>.token`, then close and delete the launch record — hand over hand, so one of the two is held at every moment.

If the claim fails because the launch record is gone, the supervisor has abandoned the launch (§11.3): the worker exits at once **without running the job**.

The worker then:

1. Holds its run token open for its whole life (§11.2).
2. Writes its own state file: `status=running` with its identity, the boot id and its deadline (§11.1).
3. Starts the job through its runner (§6.4). The job inherits `VIGIL_RUN_ID` and, on Linux/macOS, the open run token.
4. Records the identity of the job process it started.
5. Captures the job's stdout and stderr to the job log, parsing metric lines (§14.3) and, for Nagios jobs, performance data (§14.4).
6. Classifies the outcome from the exit code (§10).
7. Writes the run's events, including its outcome, to the spool.
8. Writes its final state.
9. Closes and deletes its run token, and exits.

Step 7 comes before step 8 on purpose: if the final state cannot be written, the spool file still proves how the run ended (§11.3).

Workers are independent OS processes, not threads or child jobs of the supervisor. **Stopping or crashing the supervisor does not stop running workers.** A worker that finishes while the supervisor is down still records its outcome; the supervisor reads it when it returns.

### 4.4 State

Each worker owns its job's state file and is its only writer. The supervisor only reads worker state while a run may be alive, and takes over writing only once the worker provably cannot write (VIGIL-005, §12.3). There is no shared memory, socket, pipe or callback between supervisor and worker. The state file is the contract.

This is what allows workers to survive supervisor restarts, upgrades and crashes, and what lets a restarted supervisor know the exact state of every job immediately.

### 4.5 Spool and Sender

The spool is a local outbox: a directory of small text files. There is no broker and no extra software.

Workers never talk to backends. A worker writes its run's metric events to one spool file and exits, so a slow or unreachable backend can never delay a job, cause it to overrun its next run, or lose its metrics.

**Producers.** At the end of a run, the worker writes all of the run's events to `spool/incoming/<epoch>-<job id>-<run id>.events`. The supervisor writes its own events (heartbeat, `.running`, `invalid_config`, …) once per tick to `spool/incoming/<epoch>-supervisor.events`. Files are written to a temporary name and renamed, so a reader never sees a partial file.

**Event file format.** One event per line: a Unix timestamp, the full metric name, the value, its type (`gauge` or `count`), then every tag already applied, in order: `host`, `os`, `instance`, `job`, then `[tags]` and the job's tags (§6.6), then the event's own (a metric line's tags replace same-named ones in place):

```text
1793282403 db.backup_full.duration_seconds 867 gauge host=db01 os=windows instance=db-windows job=backup_full environment=production
```

**Sender.** The sender is a worker like any other, with one fixed job id, `vigil_sender`:

- On each tick where the spool is not empty and no sender is alive, the supervisor starts one, exactly as it starts a job: detached, with its own state file, identity check (§11) and log.
- Only one sender runs at a time. It has a fixed internal `max_runtime` of 5 minutes.
- Like every worker, it keeps running if the supervisor stops, and is never started while the supervisor is down.

**Fan-out.** The sender copies each incoming file into `spool/backends/<name>/` for every enabled backend that should receive it (respecting each job's `backends` key). An interrupted fan-out must never silently lose a destination, so it follows a write-ahead protocol:

1. **Claim:** rename `incoming/<f>` to `fanout/<f>` (atomic).
2. **Fix the targets:** write `fanout/<f>.targets`, the list of destination backends, atomically. A resumed fan-out uses this list, never the current configuration, so a reload in between cannot change where events go.
3. **Place, per target:** copy to a temporary name in `backends/<name>/`, rename it into place, then create the empty marker `fanout/<f>.<name>.done`.
4. **Retire:** once every target has its marker, delete `fanout/<f>`, then the targets file and markers.

On every sender start, unfinished fan-outs in `fanout/` are resumed before new incoming files are taken: targets with a marker are skipped, the rest are placed. A target whose backend has since been removed or disabled is dropped and counted in `vigil.spool.dropped` with `reason=backend_removed`, never silently. A crash between placing a copy and writing its marker places it again: a possible duplicate, consistent with at-least-once delivery, never a loss. A crash mid-copy leaves only a temporary file, which is never sent and is deleted on resume. Copies, not links, are used: event files are small, and copies keep size accounting exact on every filesystem.

**Delivery.** For each backend in turn, the sender:

1. Takes the oldest queued files, up to a batch limit.
2. Sends them as **one request** for the whole batch, with the backend's timeout.
3. On success, deletes those files.
4. On failure, leaves them, records the failure, and backs off for that backend only (exponential, capped at 5 minutes). It then moves on to the next backend.

So a dead Datadog delays only Datadog's queue; Splunk and the local file still receive everything on time.

**Limits and guarantees.**

- **Delay:** normally at most one tick (60 seconds by default).
- **At-least-once delivery:** a crash between "sent" and "deleted" can resend a batch. Gauges are unaffected; a count may occasionally be duplicated.
- **Size cap:** when a backend's queue pushes the spool past `max_mb`, that queue's oldest (or newest, per `when_full`) files are dropped and counted in `vigil.spool.dropped`, tagged by backend.
- **Removed or disabled backends:** their queues are discarded on the next sender run and counted as dropped.
- **Old timestamps:** backends limit how old an accepted timestamp may be. Events older than a backend accepts are rejected; they are then dropped and counted, never retried forever.
- **Supervisor down:** workers keep writing to `spool/incoming/`, and delivery resumes when the supervisor returns. The missing `vigil.supervisor.up` heartbeat is how the backend learns of the outage.

A slow or unreachable backend therefore never blocks a job, the scheduler or another backend (VIGIL-009), and its events survive the outage within the spool's size cap.

---

## 5. Supported Platforms and Prerequisites

### 5.1 Prerequisites

Vigil is honest about what it needs:

| OS | Required |
| --- | --- |
| Windows client and server | Windows PowerShell 5.1 (inbox on Windows 10 / Server 2016 and later). NSSM (vendored, §18.2) for system-mode service installation. |
| Linux | bash, curl, systemd. |
| macOS | bash (the shipped 3.2 is sufficient), curl (shipped), launchd (shipped). |

PowerShell 7 is supported on Windows but never required.

Windows support floor:

| Windows | Status |
| --- | --- |
| Server 2016, 2019, 2022, 2025; Windows 10 and 11 | Supported. PowerShell 5.1 built in. |
| Server 2012 / 2012 R2 | Supported once WMF 5.1 (Microsoft's PowerShell 5.1 package) is installed. |
| Server 2008 R2 SP1 / Windows 7 SP1 | Best effort with WMF 5.1. Out of vendor support; documented, not tested. |
| XP / Server 2003 | Not supported: PowerShell 2.0 at most and no TLS 1.2, so HTTPS backends are unreachable. |

Some backends carry an extra prerequisite, documented with the backend (for example openssl for Google Cloud when not running on GCP, §15.4).

Remote sources (§6.9) likewise need a tool only when one of that type is configured: the git command-line client for `git` sources, and the OpenSSH `sftp` client for `sftp` sources (built into Windows 10 1809 and Windows Server 2019 and later, and installable on older Windows). `https` and `local` sources need nothing extra. A host with only local configuration needs none of them.

Jobs may need their own tools (sqlcmd, psql, java, Cygwin). Those are the job's prerequisites, not Vigil's, and are checked by pre-flight validation (§16.4).

### 5.2 Language Constraints

- **PowerShell:** code must run unmodified on Windows PowerShell 5.1. Known 5.1 pitfalls (BOM on `Set-Content -Encoding UTF8`, function output pollution, `$PSScriptRoot` empty under `Start-Process`, `GetTempFileName()` exhaustion, case-insensitive variable collisions) are documented in the contributor guide and must not be reintroduced.
- **bash:** code must run on bash 3.2. No associative arrays, `mapfile`, `${var,,}`, `declare -n` or `wait -n`. Use only tools present on a default install of every supported distribution and macOS; where GNU and BSD tools differ (`date`, `sed -i`, `stat`), use the portable subset.
- **Files:** all files Vigil writes are ASCII or UTF-8 without BOM, with LF line endings on Linux/macOS.

### 5.3 Portability

Platform-specific operations live behind explicit internal interfaces:

- Process creation and detachment.
- Process identity lookup (name, start time).
- Process-tree termination.
- Single-instance locking.
- Service installation.
- Atomic file replacement.

The same configuration semantics produce the same behaviour on every platform wherever the OS permits. Differences are documented in §24.

---

## 6. Configuration

### 6.1 Format

Vigil uses its own small INI dialect, parsed identically in PowerShell 5.1 and bash 3.2. The file extension is `.config`.

Rules:

- One `key = value` per line. Whitespace around `=` is trimmed.
- `[section]` and `[section.name]` headers.
- A line starting with `#` or `;` is a comment. There are no inline comments; `#` inside a value is literal.
- No quoting, no escaping, no variable expansion. Values are literal. The only substitution is the `{file}` token in runner arguments (§6.4).
- Repeating a key appends to a list (used for `arg`, `env`, `tag` and `require_env`).
- Lists inside one value are comma-separated.
- Durations: `30s`, `5m`, `2h`, `7d`. There are no months; `m` is always minutes.
- Times: `HH:MM`, 24-hour, local wall-clock.
- Days: `mon` … `sun`, case-insensitive.
- Relative paths resolve against the install root — the folder that contains `config/` (§12.1). So `file = scripts/disk.sh` points at `<root>/scripts/disk.sh`.
- Keys may begin with `.` (used by `[runners]`).
- ASCII only.

XML and JSON were rejected because neither can be parsed reliably in bash without non-native tools.

A config file is not tied to an OS. Backends, tags and schedules are portable; runners and paths are usually OS-specific, so in practice each OS has its own file.

### 6.2 Sections

| Section | Purpose |
| --- | --- |
| `[vigil]` | Instance name, state directory, global concurrency limit, and where the configuration comes from (§6.8). |
| `[scheduler]` | Tick interval, late-start window, pending limit. |
| `[log]` | Log directory, stdout mirroring, retention, file size cap. |
| `[tags]` | Tags attached to every metric. |
| `[spool]` | Spool directory, size cap, overflow policy. |
| `[backend.<name>]` | One metrics destination (§15). |
| `[log_forward]` | Optional forwarding of Vigil's logs (§13.4). |
| `[log_destination.<name>]` | One log destination (§13.4.1). |
| `[runner.<name>]` | A reusable command prefix (§6.4). |
| `[runners]` | File extension → runner map (§6.4). |
| `[source.<name>]` | A place the configuration or scripts are fetched from (§6.9). |
| `[defaults]` | Default values for overridable job keys (§6.6). |
| `[job.<id>]` | One scheduled job (§6.3). |

### 6.3 Job Definition

| Key | Required | Description |
| --- | --- | --- |
| `file` | Yes | Script or executable to run. |
| `source` | No | `[source.*]` the script is fetched from; `file` is then a path inside that source (§6.9). Default: none, `file` is local. |
| `sha256` | No | Expected SHA-256 digest of the script, 64 hex digits. Required for `https` and `sftp` sources (§6.9). |
| `runner` | No | `[runner.*]` that runs `file`. Overrides the extension map. |
| `arg` | No | Extra argument after `file`. Repeat per argument. |
| `metric_name` | No | Base metric name. Default: the job id. |
| `run_every` | One of | Fixed interval. |
| `run_at` | One of | One or more local times of day. |
| `run_on_days` | No | Restricts `run_every` or `run_at` to weekdays. |
| `max_runtime` | No | Runtime limit. Absent means unlimited. |
| `grace` | No | Time between polite stop and forced kill. |
| `overlap` | No | `skip` (default) or `queue_one`. |
| `exit_codes` | No | `standard` (default), `nagios` or a success list such as `0-7`. |
| `enabled` | No | `false` keeps the job defined but unscheduled. Default `true`. |
| `on_uncertain` | No | `wait` (default), `replace` or `manual`: what to do when a previous run's liveness cannot be established (§11.4). |
| `backends` | No | Comma-separated backend names. Default: all enabled backends. |
| `tag` | No | Extra metric tag, `key=value`. Repeat per tag. Merged with `[tags]` (§14.6). |
| `env` | No | Environment variable for the job, `NAME=value`, literal. Repeat per variable. Merged with the runner's `env`. Never a secret. |
| `require_env` | No | Comma-separated variables that must exist before the job may start. Combined with the runner's `require_env`. |
| `late_start_window` | No | Overrides `[scheduler] late_start_window` for this job (§7.7). |
| `log_retain_days` | No | Overrides `[log] retain_days` for this job's log (§13.1). |
| `forward_output` | No | `false` keeps this job's stdout and stderr out of log forwarding (§13.4). Default `true`. |
| `working_dir` | No | Working directory of the job process. Default: the install root. |

Where each key may also be set, and which value wins, is defined in §6.6.

The job id (`[job.<id>]`) names the state file, the log folder and the `job` tag. Ids are restricted to `[a-z0-9_]`. Ids starting with `vigil_` are reserved for Vigil's own workers (such as `vigil_sender`).

The smallest valid job:

```ini
[job.disk_usage]
file      = checks/disk_usage.sh
run_every = 5m
```

A disabled job remains visible as `DISABLED` in `jobs.log` and is still validated, so a mistake in it is caught before it is re-enabled.

### 6.4 Runners

A runner is a reusable command prefix. Vigil builds the job's command line as:

```text
runner.command  runner.arg...  job.file  job.arg...
```

If any runner `arg` contains the token `{file}`, the file path is substituted there and not appended. This supports clients that take the script inside another argument (`sqlplus @{file}`, `mysql --execute=source {file}`).

Runner keys: `command`, `arg` (repeatable), `env` (repeatable `NAME=value`, literal, never secrets), `require_env` (variables that must exist before any job using the runner may start).

Runner resolution, first match wins:

1. The job's `runner` key.
2. The file extension looked up in `[runners]`.
3. No runner: the file is executed directly (native executables, `.bat`/`.cmd` on Windows, scripts with a `#!` line and the executable bit on Linux/macOS).

A file that matches nothing and cannot run directly is rejected by pre-flight (§16.4), never discovered at first run.

**Paths.** `file`, `working_dir` and a runner `command` that contains a directory separator resolve against the install root when relative; a bare command name (`java`, `sqlplus`) is found on `PATH` when the job starts. On Windows, `/` in these paths becomes `\`, and drive (`C:\`), UNC (`\\server\`) and rooted (`\dir`) paths are absolute. Runner and job `arg` values are passed literally and never resolved. `arg` may be empty: some tools take an empty argument.

**Arguments are an argument vector, never a shell command line.** No quoting is needed in the config, and no shell expansion occurs:

- **Linux/macOS:** the vector is passed to the program as is.
- **Windows** has no argument vector: every program receives one command-line string and splits it itself. Vigil builds that string by the Microsoft C runtime's rules, which most programs use, quoting every argument, and starts the job with `ProcessStartInfo` (never `& $cmd @args`, which in Windows PowerShell 5.1 drops empty arguments and does not escape embedded quotes). Quoting every argument also stops Cygwin programs from expanding `*` and `?`, which they do to unquoted arguments when started from a Windows process. Programs that split their command line by other rules may see different arguments; this is documented (§24).
- **Batch files are the exception.** When the program is a `.bat` or `.cmd` file, `cmd.exe` parses the command line and interprets some characters even inside quotes. Arguments are then quoted only when they contain a space or tab or are empty, and an argument or batch file path containing `"`, `%`, `!`, `&`, `|`, `<`, `>` or `^` makes the job invalid (`E_BATCH_ARG`, `E_BATCH_PATH`). Such values are rejected, never escaped: no escaping for `cmd.exe` is reliable. Wrap the work in a PowerShell script or executable instead.

The encoding is verified on every change: `tests/Test-CommandLineRoundTrip.ps1` parses each generated command line back with Windows' `CommandLineToArgvW` and requires the original vector exactly.

### 6.5 Secrets

Secrets are never written in configuration. Every credential value has the form `env:NAME`:

```ini
api_key = env:DATADOG_API_KEY
```

Credential keys (`api_key`, `token`, `username`, `password`, `*_secret`, `*_key`, `header_value`, …) reject any value that does not start with `env:`. A pasted raw secret fails validation; the rejected value is never echoed in errors or logs.

Vigil reads the variable only at the moment it needs it, and never logs it, persists it, writes it to the spool or passes it on a command line. On Linux/macOS secrets are passed to curl on stdin (`curl -K -`), never as arguments. Secrets go in headers, never URL query strings.

Jobs receive the service environment, plus the literal `env` entries of their runner and job (§6.6). An `env` entry whose value starts with `env:` is a validation error: `env` values are literal, and the job already inherits the variable it names. Job tools that need credentials should use their own credential store (Windows integrated auth, pgpass, MySQL option files, Oracle Wallet) or a wrapper script that reads environment variables. Credentials should not be placed on a job's command line, where other users can see them in the process list.

### 6.6 Precedence and Overrides

A setting that describes how a job runs can be set on the job, in `[defaults]`, or left to its built-in default. A setting that describes the host or Vigil itself is global only.

For a single-valued key the first value found wins, in this order:

1. The job (`[job.<id>]`).
2. The key's global source: `[defaults]`, or the section named below.
3. The built-in default.

| Job key | Global source | When both are set |
| --- | --- | --- |
| `runner` | `[runners]` extension map | Job wins |
| `max_runtime`, `grace`, `overlap`, `exit_codes`, `on_uncertain`, `backends`, `enabled`, `working_dir` | `[defaults]` | Job wins |
| `late_start_window` | `[defaults]`, then `[scheduler]` | Job wins |
| `log_retain_days` | `[defaults]`, then `[log] retain_days` | Job wins |
| `tag` | `[tags]` | Merged by key; the job's value wins on a clash |
| `env` | The resolved runner's `env` | Merged by name; the job's value wins on a clash |
| `require_env` | The resolved runner's `require_env` | Combined |

Rules:

- `backends` replaces the global choice; it is not merged. A job that lists backends sends only to those.
- Job-only keys may not appear in `[defaults]`: `file`, `source`, `ref`, `sha256`, `arg`, `metric_name`, `run_every`, `run_at`, `run_on_days`, `runner`, `tag`, `env` and `require_env`. A default schedule would silently schedule every job that forgot its own; a default runner, tag or environment belongs in `[runners]`, `[tags]` or a runner. Setting one is a validation error.
- Global-only settings cannot be set on a job: `[vigil]` (instance, state directory, `max_concurrent`), `[scheduler]` `tick` and `max_pending`, `[log]` `dir`, `stdout` and `max_file_mb`, `[spool]` and the `[backend.*]` definitions. A job chooses *which* backends receive its metrics, not how they connect.
- In `env` and `tag`, a repeated name within the same section is a validation error; repeating one across layers is an override.
- Relative `working_dir` paths resolve against the install root; the directory must exist (checked by pre-flight).
- Merged `tag` and `env` lists keep the global order: a job value with the same name replaces the global one in place, and the job's other names follow in job order. `require_env` lists the runner's names, then the job's, each once.
- The runner from the extension map is found by the file's extension, compared case-insensitively, after the last `/` or `\`.

Built-in defaults, used when no layer sets a key:

| Key | Built-in |
| --- | --- |
| `metric_name` | the job id |
| `max_runtime` | none (unlimited) |
| `grace` | `30s` |
| `overlap` | `skip` |
| `exit_codes` | `standard` |
| `enabled` | `true` |
| `on_uncertain` | `wait` |
| `backends` | every backend not disabled, in file order |
| `late_start_window` | `15m` |
| `log_retain_days` / `[log] retain_days` | `7` |
| `working_dir` | the install root |
| `runner` | none: the file is executed directly |

`vigil precheck <job>` prints a job's effective settings and where each came from:

```text
job.legacy_export
  runner            = java8                  (job)
  max_runtime       = 2h                     (job)
  grace             = 30s                    (defaults)
  overlap           = skip                   (built-in)
  late_start_window = 3h                     (job)
  log_retain_days   = 7                      (log)
  working_dir       = C:\ProgramData\Vigil   (built-in)
  tag               = team=dba               (tags)
  tag               = database=orders        (job)
  env               = JAVA_TOOL_OPTIONS=-Xmx4g       (job)
  require_env       = ORACLE_HOME            (runner)
```

### 6.7 Example

Annotated example configurations live in `tests/mocks/`, one tier per folder, each for Windows and for Linux/macOS:

| Tier | Folder | Shows |
| --- | --- | --- |
| Simple | `simple/` | Everything local: every runner, schedule, override, exit-code mode and backend, with local scripts only. |
| Mixed | `mixed/` | A local configuration whose jobs fetch some scripts from sources, every source type and form. |
| Advanced | `advanced/` | Pointer files for every source type, and the fetched configurations they name (`advanced/fetched/`). |

They are part of the conformance suite (§22.1), so every example always validates, with identical results on both implementations.

### 6.8 Where the Configuration Comes From

Each Vigil instance has one configuration file, `config/vigil.config`. It is used in one of two ways:

- **Local:** the file is the configuration.
- **Remote:** the file says only where the configuration is, and Vigil fetches it from a source (§6.9):

```ini
[vigil]
config_source = central
config_file   = hosts/db01.config

[source.central]
type        = git
url         = git@git.example.com:ops/vigil-config.git
ref         = main
check_every = 5m
```

| Key | Description |
| --- | --- |
| `config_source` | The `[source.*]` holding the configuration, defined in the same file. |
| `config_file` | The configuration file inside that source: a relative path with `/` separators, without `..` segments. |

`config_source` and `config_file` are set together or not at all. With them, the local file is a *pointer file*:

- It holds only `[vigil]` with `config_source`, `config_file` and optionally `state_dir`, and the one `[source.*]` they name. Anything else is `E_POINTER_ONLY`. A setting therefore always has exactly one place it can come from.
- The fetched file is a complete configuration in the same format, validated the same way (§16.3). It may define its own `[source.*]` sections for scripts.
- The fetched file cannot set `config_source`, `config_file` or `state_dir` (`E_NOT_FROM_SOURCE`): where the configuration comes from, and where Vigil keeps its state, are decided on the host. Configuration is never chained.
- A new version of the fetched file is picked up every `check_every`. It is validated as a whole and becomes active only when it, and every script it names, is present and verified (§16.5). A broken or unreachable configuration never replaces a working one.

Jobs are the same in both modes: each job names a script, local or from a source (§6.9). The three common layouts are:

| Layout | Configuration | Scripts |
| --- | --- | --- |
| Everything local | `vigil.config` | Local files. |
| Mixed | `vigil.config` | Some local, some from sources. |
| Everything remote | Fetched from a source; `vigil.config` is a pointer file. | Local files or sources, as the fetched configuration says. |

### 6.9 Sources

A source is a place Vigil fetches the configuration or scripts from. Sources are optional: with none, everything is local.

```ini
# Scripts from a Git repository, at a release tag.
[source.scripts]
type = git
url  = https://git.example.com/ops/monitoring.git
ref  = v2.3.1

# Single scripts from an HTTPS file server.
[source.files]
type         = https
url          = https://files.example.com/vigil/
header_name  = Authorization
header_value = env:VIGIL_FILES_AUTH

[job.disk_usage]
source    = scripts
file      = checks/disk_usage.sh
run_every = 5m

[job.cert_expiry]
source    = files
file      = cert_expiry.ps1
sha256    = 9f2c4e...(64 hex digits)
run_at    = 06:00
```

| Key | Types | Description |
| --- | --- | --- |
| `type` | all | `local`, `git`, `https` or `sftp`. Required. |
| `path` | `local`, `sftp` | The source directory: a local path or a network share for `local` (relative paths resolve against the install root), a remote directory for `sftp`. Required for those types. |
| `url` | `git`, `https` | The repository URL for `git`: `https://`, `ssh://` or `user@host:path`. The base URL for `https`, which must use `https://`. Credentials in a URL are rejected. Required for those types. |
| `host`, `port`, `user` | `sftp` | Server, port (default `22`) and login. Authentication uses the service account's SSH key; `user` is not a secret. `host` is required. |
| `ref` | `git` | The tag, commit or branch everything from this source is taken at. Required. |
| `check_every` | all | How often the source is checked for changes. Default `5m`. |
| `timeout` | all | Limit for one fetch from the source. Default `60s`. |
| `header_name`, `header_value` | `https` | An authentication header. `header_value` is a credential (`env:NAME`, §6.5). |

**Scripts.** A job with `source` runs a script from that source; `file` is then a relative path inside it, with `/` separators and without `..` segments. Its `runner`, `arg`, `{file}` substitution and extension mapping work as for a local file, applied to the locally cached copy. A job without `source` runs a local file.

**Versions.** The version is set once, on the source; a job only names the file. Upgrading every job from a source is a one-line change to its `ref`. To run two versions side by side, for example to trial a release candidate on one job, define a second source with the other `ref`.

| Source type | Fixed by |
| --- | --- |
| `git` | A tag or commit in `ref`. A branch follows the branch: changes are picked up every `check_every`, and the script is reported as unpinned (`W_SCRIPT_UNPINNED`) unless the job sets `sha256`. |
| `https`, `sftp` | The job's `sha256`, required: these sources have no versions. |
| `local` | The job's `sha256` if set; otherwise changes in the directory are picked up every `check_every`, and the script is reported as unpinned. |

A job's `sha256` always wins: if the content in its source changes, the new content is rejected and the last verified copy keeps running until the digest is updated (§16.5).

**Single files.** `https` and `sftp` sources deliver the one file named, so a script that needs files beside it should come from a `git` or `local` source. A `git` reference delivers the repository's whole tree at that commit.

---

## 7. Scheduling

### 7.1 Tick Model

The supervisor evaluates every job once per tick (default `60s`). A job becomes due at the first tick at or after its scheduled time. Scheduling resolution is therefore one tick; Vigil is not intended for sub-tick precision.

### 7.2 Interval Scheduling

```ini
run_every = 5m
```

Intervals use scheduled-time semantics: the next run is due one interval after the previous **scheduled** time, not after the previous run finished. A long run does not shift the schedule; overlap is handled by the overlap policy (§9).

Interval slots are aligned to the Unix epoch: a job with `run_every = 5m` is scheduled at every UTC time that is a whole multiple of five minutes since 1970-01-01T00:00:00Z. This makes the schedule independent of when the job was added or the supervisor started, the same on every host, and unaffected by daylight saving, since intervals measure elapsed time. In a time zone whose offset is not a whole number of hours, `run_every = 1h` therefore runs at half past the local hour; use `run_at` for times tied to the local clock.

### 7.3 Time-of-Day Scheduling

```ini
run_at = 01:00
run_at = 03:00, 09:00, 15:00, 21:00
```

`run_at` accepts a list, so several fixed times need no interval arithmetic.

### 7.4 Day Selection

```ini
run_at      = 18:00
run_on_days = mon, wed, fri, sun
```

### 7.5 Valid Combinations

| Combination | Valid |
| --- | --- |
| `run_every` | Yes |
| `run_at` | Yes |
| `run_every` + `run_on_days` | Yes |
| `run_at` + `run_on_days` | Yes |
| `run_every` + `run_at` | No — list the times in `run_at` |
| `run_on_days` alone | No — nothing says when to run |
| neither | No |

### 7.6 New Jobs

A job seen for the first time runs at its next scheduled time, never immediately. A job added at 14:00 with `run_at = 20:00` first runs at 20:00.

### 7.7 Missed Runs

The default and only v1 missed-run policy is skip. If the supervisor was down when a run was due:

- If it returns within `late_start_window` (default `15m`, overridable per job; §6.6) of the scheduled time, the run fires.
- Otherwise the run is recorded as missed and the job waits for its next scheduled time.

A restart never triggers a backlog of historical runs (VIGIL-008).

A worker that crashed is not respawned immediately; the job runs again at its next scheduled time. Immediate respawn would turn a crash loop into a tight restart loop.

### 7.8 Clock Behaviour

- Calendar scheduling uses local wall-clock time.
- Elapsed durations use a monotonic clock where the platform offers one to scripts; otherwise wall-clock, and the limitation is documented.
- A backwards clock change never re-runs a run that already completed for the same scheduled time.
- A forwards jump is treated as missed runs, subject to §7.7.
- Daylight-saving: a `run_at` time that does not exist on the transition day fires at the first tick after it; a time that occurs twice fires once.

### 7.9 Schedule Decisions

Each tick, the supervisor reaches exactly one decision per job. The decision is a pure function of the inputs below, so it is tested as a table (§22.1) without waiting for real time to pass.

**Slots.** A scheduled time is a *slot*. `run_every` slots are UTC instants (§7.2). `run_at` slots are local wall-clock times: the local date and time with no offset, so a time that occurs twice is the same slot both times. `run_on_days` keeps only slots whose local date falls on a listed day; for `run_every` the day is taken at the current UTC offset.

**Cursor.** The last slot the job has dealt with — run, skipped, queued or missed — in the same form as its slots. A slot is due when it is at or before now and after the cursor; when several are due, only the latest counts and the earlier ones are passed over (VIGIL-008). The cursor is supervisor-owned, kept in `state/schedule/<job id>.cursor` and written atomically (§12.3) whenever it moves. A job with no cursor is new; a disabled job's cursor is deleted, so re-enabling it makes it new again, and a change between `run_every` and `run_at` does the same.

**Inputs.**

| Input | Meaning |
| --- | --- |
| now | Current UTC time and UTC offset. |
| previous tick | UTC time and offset of the supervisor's previous tick, or none after a start. |
| cursor | As above, or none. |
| active | `none`, `running` (a run of the job is active) or `queued` (active, and one run held by `queue_one`). |
| settings | The job's effective `run_every` or `run_at`, `run_on_days`, `late_start_window`, `overlap` and `enabled` (§6.6), and `[scheduler] tick`. |

**On time.** A due slot is on time when the supervisor was ticking normally — a previous tick exists, at most two ticks ago, not in the future — and the slot came after that tick; this is the first tick at or after the slot (§7.1). Otherwise the supervisor was down or the clock jumped, and the slot is on time only when it is at most `late_start_window` old, measured in elapsed time. A local slot's age uses the current UTC offset. So a `run_at` time skipped by a daylight-saving change fires at the next tick, while a forwards clock jump or a resume from sleep is subject to the window.

**Decisions.** Evaluated in this order:

| Decision | When | Cursor afterwards |
| --- | --- | --- |
| `disabled` | `enabled = false` | deleted |
| `new` | No cursor (§7.6) | now |
| `wait` | No slot is due | unchanged |
| `missed` | The due slot is not on time | the slot |
| `run` | On time, and no run of the job is active | the slot |
| `queue` | On time, a run is active, `overlap = queue_one` and none is queued | the slot |
| `skip` | On time and a run is active, otherwise | the slot |

Every decision except `disabled` also reports the next slot that can run — the first after both now and the cursor — shown as `NEXT` in `jobs.log`. `run` and `queue` hand the slot to admission (§8), which may still hold it as pending for capacity.

---

## 8. Concurrency

`max_concurrent` (default `5`) limits the number of running workers across all jobs.

When the limit is reached:

1. Due jobs become pending.
2. Running workers continue.
3. Pending jobs start as capacity frees, oldest first.
4. Scheduling delay is recorded.
5. `max_pending` (default `20`) bounds the pending queue; beyond it, runs are skipped and recorded.

Because workers outlive the supervisor, a restarted supervisor counts workers that are still alive (from their state files) before admitting new work.

---

## 9. Overlapping Runs

Each job has an overlap policy:

- **`skip`** (default): if the previous run is still active when the next is due, the new run is skipped and recorded as skipped.
- **`queue_one`**: at most one run is held pending until the active run finishes.

A skipped run is never reported as a failure. Pending runs are held in supervisor memory and are not persisted; a supervisor restart drops them (documented in §24).

---

## 10. Run Outcomes

### 10.1 Lifecycle

```text
waiting --> pending --> running --+--> succeeded
                                  +--> warning      (nagios exit 1)
                                  +--> failed
                                  +--> unknown      (nagios exit 3)
                                  +--> timed_out    (max_runtime)
                                  +--> crashed      (worker vanished)
```

`skipped`, `missed`, `invalid_config` and `file_missing` are recorded events, not run states.

`uncertain` is the supervisor's assessment of a run whose liveness it cannot establish (§11.3). It is reported, never written into the state file of a run that may still be live.

### 10.2 Exit Code Classification

| `exit_codes` | Succeeded | Warning | Failed | Unknown |
| --- | --- | --- | --- | --- |
| `standard` | 0 | — | any other | — |
| `nagios` | 0 | 1 | 2 | 3 and any other |
| list, e.g. `0-7` | listed codes | — | any other | — |

`nagios` lets existing Nagios-compatible plugins run unmodified, including their performance data (§14.4). Explicit lists cover tools with unusual conventions (robocopy exits 1–7 on success).

A job that cannot start (missing runner, missing file, permission denied) is `failed` with a reason.

### 10.3 Runtime Limit

`max_runtime` is optional. A job without it runs until it finishes, however long that takes; its climbing `.running` metric is the signal that something is wrong.

When `max_runtime` is set, the supervisor checks it every tick. On expiry it asks the job's process tree to stop, waits `grace`, then kills it, and records `timed_out`. Enforcement is therefore accurate to one tick.

The supervisor kills only processes whose identity matches the state file (§11). It never kills by PID alone.

While the supervisor is down, `max_runtime` is not enforced. It is enforced on the first tick after the supervisor returns. This is a deliberate simplicity trade-off (§24).

### 10.4 Supervisor Shutdown

Stopping the supervisor:

1. Stops scheduling.
2. Leaves running workers alone. They finish and record their own outcome.
3. Flushes the spool within a bounded deadline.
4. Exits.

Service managers are configured not to kill the worker process tree on stop (§18).

`vigil uninstall` (§18.8) is the only operation that terminates running workers.

---

## 11. Process Identity and Recovery

**State is evidence, not authority over a process.** A corrupt or missing state file is a metadata failure. It is never, by itself, proof that a run has ended, and never, by itself, a reason to kill or replace anything (VIGIL-018).

Vigil keeps two separate concerns apart:

- **State recovery** — repairing or replacing unreadable run metadata.
- **Run recovery** — deciding whether a run is alive, finished or safe to replace.

Recovering the state never implies the run has been recovered. Deleting a state file terminates nothing.

### 11.1 Evidence

Each run leaves several independent pieces of evidence. Losing one does not lose the others.

| Evidence | Where | What it proves |
| --- | --- | --- |
| **State file** | `state/jobs/<job id>.state` | What the worker last recorded: run id, PIDs, names, start times, boot id, deadline. Useful, but only as trustworthy as the file. |
| **Boot id** | In the state file; compared with the running system's | A run recorded during a previous boot is certainly over — every process in it died with the reboot. |
| **Launch record** | `state/locks/<job id>.<run id>.launch`, written by the supervisor before the worker starts | A run was launched. Until it is claimed, the run is *launching*: it may be starting, so the job is held (§11.3). |
| **Run token** | `state/locks/<job id>.<run id>.token`, created by the worker's claim and held open by it | Held open means alive. The OS releases it however the process dies, so a token that exists but is not held proves its worker has gone. |
| **Run id on the command line** | The worker's `--run-id` argument | A process whose command line carries this run id is this run's worker. A reused PID belongs to a process with a different command line, so it can never match. |
| **Run id in the environment** | `VIGIL_RUN_ID`, inherited by the job's processes | Ties the job's processes (sqlcmd, java, …) to the run, even after the worker has died. |
| **Process identity** | PID + process name + start time | Supporting evidence; never sufficient alone (VIGIL-007). |
| **Spool file** | `spool/…-<job id>-<run id>.events`, written before the final state | The run finished, and how — even if its final state was never written. |

Boot id sources: `/proc/sys/kernel/random/boot_id` on Linux, `sysctl kern.boottime` on macOS, the last boot time on Windows.

### 11.2 How Evidence Is Read

| Platform | Run token | Run id on command line | Run id in environment | Start time |
| --- | --- | --- | --- | --- |
| Linux | `/proc/<pid>/fd` links to the token: names the exact holder, worker or inherited child | `/proc/<pid>/cmdline` | `/proc/<pid>/environ` (own processes) | `/proc/<pid>/stat` |
| macOS | `lsof -t <token>` lists every holder, worker or inherited child | `ps -o args= -p <pid>` | not relied on | `ps -o lstart= -p <pid>` |
| Windows | An exclusive open fails while the worker holds it; the job's processes do not inherit it | Process `CommandLine` | not relied on | `Get-Process` `StartTime` |

The resulting guarantees are deliberately not conflated:

- **Linux and macOS:** the token identifies the worker and every job process that inherited it, so "worker dead, psql still running" is visible without knowing psql's PID. A job process that deliberately closes inherited files (a self-daemonising program) escapes this and is tracked only by its recorded identity.
- **Windows:** the token proves the worker is alive but does not name it, and something else (antivirus, backup software) briefly opening the file reads as "held" — a conservative error. The job's processes are tracked by their recorded identity plus the worker's command line.

**Claim and abandonment are a single race with one winner.** The worker's claim and the supervisor's abandonment act on the same launch record, and the filesystem lets only one succeed:

| Platform | Worker claims | Supervisor abandons | Why only one wins |
| --- | --- | --- | --- |
| Linux/macOS | rename `.launch` → `.token` (after opening it) | rename `.launch` → `.abandoned` | `rename` of a name that no longer exists fails |
| Windows | exclusive open of `.launch` | delete `.launch` | Deleting a file held exclusively fails; opening a deleted file fails |

A worker that loses exits without running the job. A supervisor that loses treats the run as Alive.

### 11.3 Recovery Decisions

Each tick, for each job, the supervisor gathers the evidence and reaches exactly one of five conclusions:

| Conclusion | Established by | Action |
| --- | --- | --- |
| **Alive** | Run token held, or a process carrying the run id is running | Treat as running. Post `.running`. Never start another run (overlap policy applies). Enforce `max_runtime` only when ownership is proven (§11.5). |
| **Orphaned** | Worker gone, but a job process of the run is still alive | As Alive: no replacement while it runs. Reported as `ORPHANED`. |
| **Finished** | Boot id changed; or no token held, no process carrying the run id, and a terminal state or spool file shows the outcome | Record the outcome (reconciled from the spool if the state is unreadable), then schedule normally. |
| **Crashed** | Boot id changed, or no token held and no process carrying the run id, and no outcome anywhere | Record `crashed`, post `.crashes`, schedule at the next scheduled time (§7.7). Never treated as success (VIGIL-006). |
| **Uncertain** | The evidence conflicts or cannot be read (permission denied, a probe failed, identity partly matches) | Do not kill. Do not replace (unless `on_uncertain = replace`, §11.4). Report every tick until resolved. |

Applying the table to damaged or absent state:

| State file | Evidence | Conclusion |
| --- | --- | --- |
| Readable, `running` | Token held / run id process found | Alive |
| Readable, `running` | Worker gone, job process found | Orphaned |
| Readable, `running` | Nothing alive, spool has outcome | Finished (reconciled) |
| Readable, `running` | Nothing alive, no outcome | Crashed |
| Readable, `running` | Previous boot | Finished or Crashed — nothing can be alive |
| **Unreadable** | A token for this job held, or a process carries this job's run id | Alive. The worker's final write repairs the file. |
| **Unreadable** | Nothing held, nothing running | Finished (from spool) or Crashed; the bad file is quarantined. |
| **Missing** | A token for this job held, or a process carries this job's run id | Alive — **not** a new job. |
| **Missing** | Nothing held, nothing running | New job (§7.6). |
| Any | Probes fail or conflict | Uncertain |

**Launching runs.** A launch record is checked before anything else, whatever the state file says — this is what stops a restarted supervisor from mistaking a just-started worker for a job that never ran:

| Launch record | Evidence | Conclusion |
| --- | --- | --- |
| Present, held (worker is claiming) | — | Alive |
| Present, not held, younger than the launch grace (120 seconds) | — | Launching: hold the job, start nothing |
| Present, not held, older than the grace | A process carries the run id | Launching: the worker is slow; keep holding |
| Present, not held, older than the grace | No process carries the run id | Abandon (§11.2). If the supervisor wins, the run never started: record it, post `<m>.abandoned_launches`, and treat the scheduled time under §7.7. If it loses, Alive. |
| Present, from a previous boot | — | Abandon immediately: nothing from that boot can claim it |

An abandoned launch is not a crash and not a failure: the job never ran. `<m>.abandoned_launches` makes a repeated launch problem visible.

When the state file is unreadable or missing, the run id is recovered from the launch, token and spool file names for that job. The process scan for a run id is only done in these cases and for launch records past their grace, not every tick.

**Quarantine.** An unreadable state file is moved to `state/quarantine/<job id>.<epoch>.state` only once the run is concluded Finished or Crashed, never while it might be alive. Quarantine follows the log retention limit. Corruption is always recorded: `<m>.state_corrupt` and a `jobs.log` entry.

**Stale tokens.** A run token that exists but is not held was left behind by a claimed worker that was killed. It is deleted once the run is concluded. An `.abandoned` file is deleted at once; a launch record that is not held is never "stale" — it is handled as a launching run above.

### 11.4 Uncertain Runs

An uncertain run holds its job: no new run starts and nothing is killed. It is shown as `UNCERTAIN` in `jobs.log` with the reason, and `<m>.uncertain = 1` is posted every tick, so a stalled job is loud, never silent.

It resolves:

- **Automatically**, as soon as the evidence becomes conclusive — the token is released, the process exits, or the boot id changes.
- **By an operator**, with `vigil resolve <job>`, which records that the operator confirmed the run is over. It never kills anything.

The `on_uncertain` policy chooses between these:

| Policy | While uncertain | When the evidence becomes conclusive |
| --- | --- | --- |
| `wait` (default) | Hold the job; report every tick. | Conclude the run (§11.3) and resume scheduling. |
| `replace` | Keep scheduling; each run started posts `<m>.possible_duplicates`. For cheap, idempotent checks (ping, disk, HTTP probes). | Conclude the run. |
| `manual` | Hold the job; report every tick. | Conclude the run but keep the job held until `vigil resolve`. For jobs where a run of unknown fate may have left half-done external effects (dumps, loads, transfers) that someone should inspect first. |

No policy ever authorises killing anything; termination always requires proven ownership (§11.5).

**Recovery record.** The supervisor never writes uncertainty into the worker's state file, because the worker may still be alive and writing it. Each held job instead has a supervisor-owned record, `state/recovery/<job id>.recovery`, in the same `key = value` format with a single `[recovery]` section:

```ini
[recovery]
job          = dump_databases
run_id       = 20261029T200000Z-4821
conclusion   = uncertain
reason       = run token held but no process carries the run id
first_seen   = 1793305200
last_checked = 1793308800
policy       = wait
resolved_by  =
resolved_at  =
```

The record survives supervisor restarts, so a held job stays held without re-deriving why. `vigil resolve` fills `resolved_by` (the operator's user name) and `resolved_at`; the supervisor then concludes the run and deletes the record. A record is also deleted when the run is concluded automatically, except under `manual`.

### 11.5 Ownership Before Termination

Vigil terminates a process only for `max_runtime` or `vigil uninstall`, and only when it has proven the process belongs to the run:

- **Worker:** its command line carries the run id, and its start time matches where available.
- **Job process:** on Linux/macOS it holds the run token or carries `VIGIL_RUN_ID`; on Windows its PID, name and start time match the state file and, while the worker lives, its parent is the worker.

If ownership cannot be proven, Vigil does not terminate. It records the timeout and the uncertainty, keeps the job held, and reports it.

Deadlines: `deadline_epoch` is recorded at start. While the supervisor runs, elapsed time is measured with a monotonic clock where the platform offers one to scripts. After a supervisor restart, only the recorded timestamps are available; they are used for enforcement but are not equivalent to uninterrupted monotonic timing (§24).

### 11.6 Process-Tree Termination

Used only for `max_runtime` and `vigil uninstall`, after §11.5.

- **Windows:** `taskkill /T /F` against the ownership-checked job process, then the worker.
- **Linux/macOS:** the worker starts the job in its own process group (`set -m`); termination signals the group (`TERM`, then `KILL` after `grace`).

Processes that deliberately escape their group or tree may survive. This limit is documented (§24).

Vigil does not guarantee exactly-once execution of a job's external effects. Jobs that need stronger guarantees implement idempotency, transactions or external coordination themselves.

---

## 12. State

### 12.1 Layout

Everything lives under one install root (§18.6 gives the root per platform):

```text
<root>/
  app/                    Vigil's own scripts - replaced on upgrade
  vendor/nssm/            Windows only
  config/
    vigil.config          the configuration, or a pointer to it (§6.8); never overwritten
    vigil.env             credential variables (systemd EnvironmentFile), owner-only
  scripts/                the operator's job scripts - never overwritten
  cache/                  fetched configuration and scripts (§16.5); Vigil-owned
    <source>/repo.git       git: bare mirror, never checked out
    <source>/<commit>/      git: the tree at one commit, read-only once complete
    <source>/files/<sha256>/<name>   https, sftp, local: one file by content
    staging/                fetches in progress
  state/
    config.active                 the active configuration record (§16.5)
    config.valid                  a copy of the last valid local configuration, kept active while a newer one is rejected (§16.3)
    supervisor.lock               held open by the live supervisor
    jobs/<job id>.state
    jobs/vigil_sender.state
    jobs/vigil_fetch.state
    jobs/vigil_logs.state
    logs/<encoded file path>.checkpoint   log forwarding progress (§13.4.4)
    locks/<job id>.<run id>.launch  written by the supervisor before the worker starts
    locks/<job id>.<run id>.token held open by the live worker after its claim
    quarantine/<job id>.<epoch>.state   unreadable state, kept as evidence
    recovery/<job id>.recovery    supervisor-owned record of a held job (§11.4)
    schedule/<job id>.cursor      the last slot the job dealt with (§7.9): one line, the slot
  spool/
    incoming/<epoch>-<job id>-<run id>.events
    fanout/<file>, <file>.targets, <file>.<backend>.done   fan-out in progress (§4.5)
    backends/<backend name>/<same file names>
  logs/
    supervisor/yyyy-MM-dd.log
    supervisor/jobs.log
    jobs/<job id>/yyyy-MM-dd.log
  metrics/vigil.prom      when the file backend is enabled
```

Relative paths in the config resolve against the root (§6.1). The state, spool and log locations can be overridden in the config.

### 12.2 Format

State files use the same `key = value` format as the configuration, with a single `[state]` section, so the same parser reads both on every platform with no special mode. JSON is not used: writing it from bash is easy, but the bash supervisor must also *read* every state file each tick, and bash has no native JSON parser.

Example of a completed run:

```ini
[state]
schema_version   = 1
job              = dump_databases
run_id           = 20261029T200000Z-4821
instance         = ops-windows
status           = succeeded
reason           =
boot_id          = 6f1c0e2a-9b4d-4a57-8e0f-2c1d3b5a7e90
scheduled_epoch  = 1793304000
started_epoch    = 1793304003
deadline_epoch   =
ended_epoch      = 1793304870
scheduled_at     = 2026-10-29T20:00:00Z
started_at       = 2026-10-29T20:00:03Z
ended_at         = 2026-10-29T20:14:30Z
duration_seconds = 867
exit_code        = 0
worker_pid       = 4821
worker_name      = powershell.exe
worker_start     = 1793304002
job_pid          = 4830
job_name         = sqlcmd.exe
job_start        = 1793304003
metric_lines     = 0
invalid_lines    = 0
spool_file       = 1793304870-dump_databases-20261029T200000Z-4821.events
```

Field rules:

- **Status** is one of `waiting`, `running`, `succeeded`, `warning`, `failed`, `unknown`, `timed_out` or `crashed`. `reason` holds a one-line explanation for anything other than success (for example `exit code 2`, `runner not found`, `worker vanished`).
- **Times are stored twice.** `*_epoch` fields are Unix seconds in UTC and are what Vigil computes with. `*_at` fields are ISO 8601 UTC, for humans. Both are needed because converting an ISO date back to a number is not portable between GNU and BSD `date`, while printing both is trivial on every platform.
- **Process identity:** `*_pid`, `*_name` and `*_start` (epoch) for the worker and for the job process it started (§11.1). On platforms where a start time is unavailable, `*_start` is empty.
- **A running file** has `status = running` and no `ended_*`, `duration_seconds` or `exit_code`.
- **`run_id`** is generated by the supervisor before the worker starts and also appears on the worker's command line, in `VIGIL_RUN_ID`, in the run token's name and in the spool file's name (§11.1).
- **`boot_id`** identifies the system boot the run started in. On Linux it is the kernel boot id; on macOS and Windows it is derived from the boot time.
- **`deadline_epoch`** is `started_epoch + max_runtime`, empty when the job has no `max_runtime`.
- **Run summary:** `metric_lines`, `invalid_lines` and `dropped_lines` count the metric lines and Nagios perfdata items accepted, rejected and dropped over the cap (§14.3); `spool_file` names the spool file holding the run's events, so a missing metric can be traced from state to spool.
- **Values are single-line.** Line breaks in a reason or error are replaced by spaces, and values are truncated to 500 characters. Full detail belongs in the job log, not the state file.
- **Unknown keys are ignored**, so a newer Vigil can add fields. A higher `schema_version` than the running Vigil understands is reported as unsupported state (§12.3).
- **Never secrets.** State files never contain credentials or environment values.

### 12.3 Rules

- **Atomic publication.** Every state and recovery-record write goes to a temporary file in the same directory, `<name>.tmp.<pid>`, which is then renamed over the target: `mv -f` on POSIX; on Windows `File.Replace`, or `File.Move` when the target does not exist yet (`File.Replace` requires it). Same directory, so the rename never crosses filesystems. Readers only ever open the exact target name, so a temporary file is never mistaken for state.
- **Durability.** On Windows the temporary file is flushed to disk (`FileStream.Flush($true)`) before the rename. bash has no portable per-file flush, so on Linux/macOS a power loss can leave an empty or truncated state file; that is handled as unreadable state (§11.3), never trusted. Atomic replacement prevents partially published state; it does not prevent every corruption, which is why state is evidence, not authority (§11).
- **Leftover temporary files** (from a writer that died mid-write) are deleted by the supervisor only once the run they belong to is concluded, never while their writer might be alive.
- **One writer at a time (VIGIL-005).** While a run may be alive, its worker is the only writer of the job's state file. The supervisor writes it only to create the initial `waiting` state of a new job, or to record a concluded run (`crashed`, `timed_out`, or an outcome reconciled from the spool, §11.3) — and only after it has established that the worker can no longer write: the run token is no longer held **and** no process carries the run id on its command line. A passed deadline, a missing PID or an unreadable state file is never, by itself, that proof. While ownership is uncertain, the supervisor writes only its own recovery record (§11.4).
- An unreadable or unsupported state file is reported and handled per §11.3: never silently discarded, and quarantined only once the run is concluded.
- Deleting a state file resets the job to "new" only when no run of it is alive (§11.3). Deleting the state of a live run changes nothing: the run is still found through its token and run id, and its final write recreates the file. Editing a state file is not supported.
- Configuration is the source of truth for scheduling. State records what happened.

### 12.4 Single Supervisor

The supervisor holds `state/supervisor.lock` open for its whole life, the same way a worker holds its run token (§11.2), and records its PID and start time in it. At startup it refuses to run if another live supervisor holds the lock. A lock file that exists but is not held is stale and is taken over.

---

## 13. Logging

### 13.1 Logs

- **Supervisor log:** `logs/supervisor/yyyy-MM-dd.log`, one line per event: `<UTC time> <level> supervisor <message>`, the level being `INFO`, `WARN` or `ERROR`: configuration loaded or rejected, runs started, slots missed or skipped, launches abandoned, runs reconciled or crashed, start and stop.
- **Job log:** one daily file per job, `logs/jobs/<job id>/yyyy-MM-dd.log`, append-only. Every line is `<UTC time> <run id> <stream> <text>`, so each line names its run and can be read, grepped or forwarded on its own (§13.4):

  ```text
  2026-10-30T15:07:34Z 20261030T150733Z-16052 run start
  2026-10-30T15:07:35Z 20261030T150733Z-16052 out metric rows 5 table=orders
  2026-10-30T15:07:35Z 20261030T150733Z-16052 err to stderr
  2026-10-30T15:07:35Z 20261030T150733Z-16052 run end succeeded in 1s
  ```

  `run` lines are Vigil's own (`start`, then `end <outcome> [(<reason>)] in <n>s`); `out` and `err` lines are the job's stdout and stderr, one line each, unchanged except that a trailing carriage return is removed.
- **stdout mirroring:** optional, so service managers (NSSM, journald, launchd) capture the supervisor's output.

Retention (`retain_days`) and a per-file size cap (`max_file_mb`) apply to every log file (VIGIL-014). A job may keep its own log for a different number of days with `log_retain_days` (§6.6); the size cap is global. A file that reaches the cap is never truncated or renamed: writing continues in a new file with the next sequence number, `yyyy-MM-dd.1.log`, `yyyy-MM-dd.2.log` and so on. Log files are therefore append-only and their names are never reused; retention deletes whole files only.

### 13.2 Status File

`logs/supervisor/jobs.log` is rewritten every tick and is the primary operator view. It groups jobs into sections:

- `UNCERTAIN` (with the reason; §11.4)
- `CRASHED` / `ORPHANED`
- `INVALID` (with the validation reason)
- `FILE MISSING`
- `RUNNING` (PID, elapsed, time to `max_runtime`)
- `PENDING` (waiting for capacity)
- `WAITING` (next scheduled time)
- `DISABLED`
- `LAST RUN` (outcome, end time, duration)

A healthy system shows only `WAITING`, `RUNNING` and `LAST RUN`.

### 13.3 Log Safety

Vigil never writes secret values or environment values to its logs. A job's own output is logged as the job printed it (§13.4.7). A full disk or unwritable log location is reported and never crashes the supervisor.

### 13.4 Log Forwarding

Vigil can forward the logs it writes to an organisation's logging service, so its activity is visible without logging in to each host. It forwards only its own logs; it is not a host log collector. Forwarding is off by default.

**Local logs are authoritative; forwarding is optional and asynchronous.** The supervisor and workers write their local logs exactly as they would without forwarding, and never wait for, or talk to, a log destination. Forwarding never modifies, truncates, renames or deletes a log file, and a destination that is down never affects scheduling, jobs, recovery or metrics delivery.

#### 13.4.1 Configuration

```ini
[log_forward]
destination = ops_logs
include     = supervisor, run, stdout, stderr

[log_destination.ops_logs]
type         = otel
endpoint     = https://collector.example.com:4318/v1/logs
header_name  = Authorization
header_value = env:OTEL_LOGS_AUTH
timeout      = 10s
```

| `[log_forward]` key | Description |
| --- | --- |
| `enabled` | `true` or `false`. Default `true` when the section exists, so turning forwarding off keeps its settings. |
| `destination` | The `[log_destination.*]` to send to. Required. One destination in v1. |
| `include` | Which records to forward: `supervisor` (the supervisor log), `run` (Vigil's own lines in job logs: start, end, outcome), `stdout`, `stderr`. Default `supervisor, run`. |
| `check_every` | How often the forwarder looks for new log lines. Default `30s`. |
| `batch_lines` | Most lines per request. Default `500`. |
| `batch_kb` | Most kilobytes per request. Default `512`. |
| `max_pending_mb` | Most unsent log data the forwarder works through in one run. Default `64`. |

| Job key | Description |
| --- | --- |
| `forward_output` | `false` keeps this job's stdout and stderr local even when `include` names them. Its `run` lines are still forwarded. Default `true`; may also be set in `[defaults]`. |

- **Job output is opt-in.** stdout and stderr are where secrets and personal data leak, so they are forwarded only when `include` names them, and any job can keep its output local with `forward_output = false`.
- **`[log_destination.*]` is separate from `[backend.*]`.** A metrics endpoint is never assumed to accept logs, even when both point at the same product. A log destination takes `type` (`otel` in v1), `endpoint` (`https://` only, without credentials), `timeout` (default `10s`) and an optional `header_name` and `header_value`, the value under the `env:` rule (§6.5). `type` and `endpoint` are required.
- Changes take effect at the next tick, like any configuration change (§16.1). Turning forwarding on or off, or changing what it includes, needs no restart. An invalid `[log_forward]` or `[log_destination.*]` is a configuration error like any other (§16.3): the last valid configuration stays active, and local logging is never affected.

#### 13.4.2 What Is Forwarded

| Category | Source | Severity |
| --- | --- | --- |
| `supervisor` | `logs/supervisor/*.log` | The line's own level. |
| `run` | `run` lines of `logs/jobs/<job id>/*.log` | `info`; an `end` line with an outcome other than `succeeded` is `warn` (warning) or `error` (failed, unknown, timed_out, crashed). |
| `stdout` | `out` lines of job logs | Unspecified: Vigil never guesses the severity of a job's output. |
| `stderr` | `err` lines of job logs | Unspecified. |

The internal workers `vigil_sender` and `vigil_fetch` write job logs like any job and are forwarded with them. **The forwarder's own log, `logs/jobs/vigil_logs/`, is never forwarded**, so a failing destination cannot produce errors that are themselves forwarded, fail, and produce more. Its failures are reported as metrics instead (§13.4.6).

Every record carries: the time from the line, `host`, `os`, `instance` and the `[tags]` section (§14.6), the component (`supervisor` or `job`), for job lines the job id and run id, the category, the severity when there is one, the message (the line's text, unchanged), the source file name, and the active configuration revision (§16.5). Run ids are fine in log records, unlike metric tags: logs are not aggregated into series.

#### 13.4.3 The Forwarder

Forwarding is done by a third internal worker, `vigil_logs`, started and supervised exactly like `vigil_sender` (§4.5): detached, with its own state file, run token, log and identity checks, one at a time, with a fixed internal `max_runtime` of 5 minutes. The supervisor starts it, when forwarding is enabled, on each `check_every` where a log has grown since its last checkpoint. A forwarder that fails or is killed never affects the supervisor or other workers, and the next one resumes from the checkpoints.

It is separate from the metrics sender on purpose: metrics and logs have independent progress, failures and backlogs, and neither can delay the other.

#### 13.4.4 Checkpoints

The forwarder keeps one checkpoint per log file, `state/logs/<encoded file path>.checkpoint`, in the `key = value` format with a single `[checkpoint]` section, written atomically (§12.3):

```ini
[checkpoint]
file        = logs/jobs/backup_full/2026-10-30.log
fingerprint = 3816409027 64
offset      = 827391
```

- **File identity.** Log files are append-only and their names are never reused (§13.1), so a file is identified by its name plus a fingerprint: the `cksum` of its first 64 bytes, and the number of bytes fingerprinted (fewer for a file shorter than 64 bytes, completed once it grows). A file whose fingerprint no longer matches has been replaced or edited: it is forwarded again from the start, and a `replaced` gap is reported, since some of its old content may never have been sent.
- **Truncation.** A file shorter than its checkpoint's offset is treated as replaced, never as "nothing new".
- **Whole lines only.** The offset only ever points just past a newline; an incomplete last line is left for the next run.
- **Advanced only on acceptance.** A checkpoint moves past a batch only after the destination has accepted that batch (§13.4.5).
- **Unreadable checkpoint.** The file is forwarded again from the start (duplicates rather than loss), and a `checkpoint_reset` is reported. Vigil never assumes a file was delivered because it cannot tell.
- **Deleted files.** When retention deletes a file whose checkpoint is behind its end, the undelivered bytes are reported as a `deleted` gap, and the checkpoint is removed. A deleted file is never reported as delivered. Retention is never delayed for the forwarder: local retention settings stay authoritative.
- **Changing destination.** Checkpoints belong to the destination they were written for. When `destination` changes, the new destination starts from the current end of every file (it does not receive history), and the records the old destination had not accepted are reported as a `destination_changed` gap.
- Files are processed oldest first, so the end of one day's file is sent before the next day's begins.

#### 13.4.5 Delivery

Delivery is **at least once** while a file still exists: a crash between a destination accepting a batch and the checkpoint being written resends that batch. Duplicates are possible; exactly-once is not promised.

- **Acceptance, not transport.** Each destination type defines what counts as accepted: for `otel`, an HTTP 2xx whose response reports no rejected records. A partial success advances the checkpoint only past the leading records that were accepted; the rest are retried. A response Vigil cannot interpret is a failure, never a success.
- **Retries.** A failed request is retried in the next forwarder run, with exponential backoff between runs up to 15 minutes. Authentication failures are reported separately, since retrying does not fix them. Every request is bounded by the destination's `timeout`.
- **Bounds.** One forwarder run sends at most `max_pending_mb` of log data, in requests of at most `batch_lines` lines and `batch_kb` kilobytes, one request at a time. It reads files line by line, so its memory use is bounded by one batch whatever the size of the logs. Lines longer than 64 KB are truncated, and the truncation is marked in the record.
- **Content.** Records are sent as text in the destination's encoding (for `otel`, OTLP/HTTP JSON). Control characters and invalid UTF-8 in job output are escaped, never sent raw. The forwarder never interprets or executes what a record says.

Destination types in v1: `otel` (OTLP/HTTP, JSON encoding), which a collector can route to almost any logging service. Native `splunk` (HEC) and `datadog` (logs intake) adapters follow, each only once its acceptance, rejection and error responses are covered by tests (§22).

#### 13.4.6 Health Metrics

Posted through the normal metrics path (§14), so they reach the metrics backends even while log forwarding is failing:

| Metric | Type |
| --- | --- |
| `vigil.logs.enabled` | gauge, `1` every tick while forwarding is enabled |
| `vigil.logs.records_sent` | count |
| `vigil.logs.bytes_sent` | count |
| `vigil.logs.pending_bytes` | gauge, unsent bytes across all files |
| `vigil.logs.failures` | count, tagged `reason` (unreachable, timeout, auth, rejected, invalid_response) |
| `vigil.logs.gaps` | count, tagged `reason` (deleted, replaced, checkpoint_reset, destination_changed) |
| `vigil.logs.gap_bytes` | count, with the same `reason` tag |

A growing `pending_bytes` with recurring `failures` means the destination is unhealthy; any `gaps` means log records were lost and will not arrive.

#### 13.4.7 Security

- Forwarding happens only when configured. Job output is opt-in, and opt-out per job (§13.4.1).
- Credentials follow the `env:` rule (§6.5) and never appear in logs, checkpoints or state. Credentials in endpoint URLs are rejected, as for sources (§16.3).
- `https` only, with certificate verification never disabled, as for backends (§15.2).
- Checkpoints get the same owner-only permissions as the rest of `state/` (§17).
- Nothing is redacted, because there is nothing to redact: Vigil's own lines say only what it ran and how it ended, and never contain credentials (§6.5, §13.3). A job's output is the job's own; it is forwarded only when asked for, and a job whose output should stay on the host sets `forward_output = false`.

#### 13.4.8 Non-Goals

Vigil does not collect operating-system or application logs, scan the system for logs, index or search logs, alert on them, or replace Fluent Bit, Vector or an organisation's log pipeline. Its logs go to that pipeline; the pipeline does the rest.

---

## 14. Metrics

### 14.1 Naming

Metric names are written with dots (`db.backup_full.failures`), and underscores are allowed within a part (`backup_full`). There is no setting for the separator: each backend translates names to its own convention. Backends using the Prometheus format (`file`, `prometheus`, `victoriametrics`) allow only underscores, so dots become underscores there; every other backend keeps the dots. A name written with underscores only (`x_y_z`) is sent unchanged everywhere.

Two different names can become the same name after that translation (`app.queue_depth` and `app_queue.depth` are both `app_queue_depth`). When two jobs with such base names send to the same Prometheus-format backend, validation reports `W_METRIC_COLLISION`. Jobs sharing one `metric_name` are not a collision: their `job` tag tells them apart.

### 14.2 Per-Job Metrics

Posted for each job under its `metric_name`:

| Metric | Type | When |
| --- | --- | --- |
| `<m>.duration_seconds` | gauge | Every completed run. |
| `<m>.runs` | count | Every run started. |
| `<m>.succeeded` | count | Run succeeded. |
| `<m>.warnings` | count | Nagios warning. |
| `<m>.failures` | count | Run failed or unknown. Tagged `exit_code`. |
| `<m>.timeouts` | count | `max_runtime` exceeded. |
| `<m>.crashes` | count | Worker vanished without a final state. |
| `<m>.abandoned_launches` | count | A launched worker never claimed its run; the job did not run (§11.3). |
| `<m>.uncertain` | gauge | `1` every tick while a run's liveness cannot be established (§11.4). |
| `<m>.possible_duplicates` | count | A run started under `on_uncertain = replace`. |
| `<m>.state_corrupt` | count | The job's state file was unreadable. |
| `<m>.skipped` | count | Overlap or pending-limit skip. |
| `<m>.missed` | count | Missed while the supervisor was down. |
| `<m>.running` | gauge | Elapsed seconds, every tick while running. |
| `<m>.invalid_config` | gauge | `1` every tick while the job fails validation. |
| `<m>.file_missing` | gauge | `1` every tick while the job's file is missing. |
| `<m>.invalid_metric_lines` | count | A run printed metric lines or perfdata items that did not parse (§14.3). |
| `<m>.dropped_metric_lines` | count | A run printed more metric lines and perfdata items than the cap (§14.3). |

### 14.3 Job-Emitted Metrics

Any line a job prints to stdout of the form:

```text
metric <name> <value> [key=value ...]
```

is posted as `<metric_name>.<name>` with the job's tags plus the line's tags. Any language can emit metrics this way; no library is needed.

Grammar:

- A metric line starts with the word `metric` in the first column, followed by a space or tab. Fields are separated by any number of spaces or tabs. A trailing carriage return is ignored, so CRLF output from Windows jobs works.
- `<name>`: parts of `[A-Za-z0-9_]+` joined by single dots, as for `metric_name` (no leading, trailing or doubled dot).
- `<value>`: an optional `-`, digits, and an optional `.` followed by digits (`42`, `-3.5`, `0.25`). No exponent, no leading `.`, no hexadecimal. It is posted in canonical form: `012.500` is `12.5` and `-0` is `0`.
- Tags: `key=value` pairs; keys `[A-Za-z0-9_]+`; values are non-empty and contain no spaces, and may contain `=`. A reserved tag key (§14.6), or a key repeated on one line, makes the line invalid.
- Other stdout lines are written to the job log only.
- A line starting with the word `metric` that does not parse is logged and counted in `<m>.invalid_metric_lines`; it never fails the run.
- At most 1000 metric lines and perfdata items are taken from one run. Later ones are not parsed; they are dropped and counted in the run summary (`dropped_lines`, §12).

### 14.4 Nagios Performance Data

Jobs with `exit_codes = nagios` also have their Nagios performance data parsed, so existing plugins report their numbers without modification. Other jobs are never parsed for perfdata, so a `|` in ordinary output is never misread.

Perfdata follows the Nagios plugin guidelines: everything after the first `|` on the first output line, plus everything after a `|` on any later line, is a space-separated list of:

```text
'label'=value[UOM];[warn];[crit];[min];[max]
```

Example (`check_disk`):

```text
DISK OK - free space: / 7800 MB (40%) | /=11700MB;15600;17550;0;19500
```

Parsing rules:

- Items are separated by spaces or tabs. An unquoted label runs to the first `=`.
- The label may be single-quoted to contain spaces or `=`; `''` inside quotes is a literal quote. In the `label` tag, spaces become `_`, since tag values cannot contain spaces.
- The value is a number as in §14.3, directly followed by its unit of measure, if any (`11700MB`, `0.8ms`, `40%`). A value of `U` (undetermined) is skipped and not counted.
- Units are normalised: `s`, `ms`, `us` to seconds; `B`, `KB`, `MB`, `GB`, `TB` to bytes (1024 multiples); `%` kept as a percentage; `c` (continuous counter) posted as a count. Units are case-sensitive. Unknown units are kept as-is and recorded in a `uom` tag. Conversion is exact decimal arithmetic, never floating point: `11700MB` is `12268339200` and `250ms` is `0.25`, identically on every platform.
- `warn`, `crit`, `min` and `max` are converted with the value's unit and posted as `<…>.warn`, `<…>.crit`, `<…>.min`, `<…>.max` when they are plain numbers. Anything else in those fields, including range syntax (`10:20`, `@10:20`, `~:5`), is not posted and does not make the item invalid.
- An item is malformed when its label is empty, it has no `=`, a quote is not closed (the rest of the line is then one malformed item), it has more than five `;`-separated fields, or its value is not a number with an optional unit. A malformed item is skipped and counted in `<m>.invalid_metric_lines`; it never fails the run.
- Perfdata items count towards the per-run cap of §14.3.
- `metric` lines (§14.3) work in Nagios jobs too; both are collected. A `metric` line is never scanned for perfdata.

Every perfdata value is posted under one fixed name, `<m>.perf`, with the perfdata label as a `label` tag. There is nothing to configure:

```text
<m>.perf      = 12268339200   label=/      (11700 MB as bytes)
<m>.perf.warn = 16357785600   label=/
<m>.perf.crit = 18402508800   label=/
<m>.perf.min  = 0             label=/
<m>.perf.max  = 20447232000   label=/
```

This works for every plugin, whether its labels are fixed names (`rta`, `pl`, `time`) or variable ones (disk paths, interface names), and matches how established collectors such as Telegraf represent Nagios perfdata. Backends filter or group by the `label` tag.

### 14.5 Supervisor Metrics

| Metric | Type |
| --- | --- |
| `vigil.supervisor.up` | gauge, every tick (heartbeat) |
| `vigil.supervisor.workers` | gauge |
| `vigil.supervisor.pending` | gauge |
| `vigil.supervisor.config_reload_failed` | gauge, `1` while a reload is rejected |
| `vigil.config.info` | gauge, `1` every tick, tagged `revision` (the active configuration revision, §16.5) |
| `vigil.config.activated` | count, when a new revision becomes active |
| `vigil.source.check_age` | gauge, seconds since the last successful check, tagged by source |
| `vigil.source.failures` | count, tagged by source and `reason` (unreachable, timeout, auth, digest, invalid, unpinned) |
| `vigil.spool.bytes` | gauge |
| `vigil.spool.dropped` | count |
| `vigil.backend.failures` | count, tagged by backend |

The absence of `vigil.supervisor.up` is how a backend detects that Vigil itself is down.

Fleet convergence is read from the backend, not from a Vigil dashboard: hosts reporting the same `vigil.config.info` revision run the same configuration and the same script content; a host on an older revision, with a growing `check_age` or with `source.failures`, has not converged.

### 14.6 Tags

Every metric carries the `[tags]` section plus automatic tags: `host` (the short host name in lower case), `os` (`windows`, `linux` or `macos`), `instance` (`[vigil] instance`, default `vigil`) and, for job metrics, `job`. Run ids are never attached to metrics, to keep cardinality bounded. Variable dimensions (database, drive, tablespace) belong in tags, not in metric names.

`[tags]` accepts any number of tags:

- Keys: `[a-z0-9_]+`. Values: any text without spaces.
- Reserved keys, set only by Vigil: `host`, `os`, `instance`, `job`, `label`, `uom`, `exit_code`. Declaring one is a validation error.
- Tags are static per host, so adding more does not multiply the number of series in the backend.
- A job adds or overrides tags for its own metrics with repeatable `tag = key=value` lines (§6.6), under the same key, value and reserved-key rules. A metric line's own tags (§14.3) override both, except reserved keys.
- Some backends cap the number of tags (dimensions) per metric — Azure Monitor custom metrics allow 10 and CloudWatch 30, counting Vigil's automatic tags. Validation warns when an enabled backend's cap would be exceeded; the backend's own documentation is authoritative for current limits.

---

## 15. Backends

### 15.1 Model

Any number of backends may be enabled. By default every job's metrics go to every enabled backend. A job may restrict this with `backends = <name>, ...`; names refer to `[backend.<name>]` sections, so `backends = datadog_eu` targets one Datadog account and not another. An unknown name makes the job invalid; a disabled one is a validation warning.

`[backend.<name>]` names are free text; `type` defaults to the name, so the same backend type can be configured twice (for example two Datadog sites).

### 15.2 Transport

- Linux/macOS: curl, with secrets on stdin.
- Windows: `Invoke-WebRequest` / .NET.
- UDP backends (StatsD) use bash `/dev/udp` and .NET `UdpClient`; no curl.

Every request has a timeout. Retries are bounded with backoff. Delivery is from the spool (§4.5).

### 15.3 Supported Types

| Type | Protocol | Auth |
| --- | --- | --- |
| `file` | Prometheus text format on local disk | none |
| `datadog` | Series API | API key |
| `otel` | OTLP/HTTP JSON | optional bearer |
| `prometheus` | Pushgateway | optional basic |
| `victoriametrics` | Prometheus text import | optional basic / bearer |
| `influxdb` | Line protocol (v1 and v2) | token |
| `splunk` | HTTP Event Collector | HEC token |
| `graphite` | Carbon plaintext (TCP) | none |
| `statsd` | StatsD / DogStatsD (UDP) | none |
| `elasticsearch` | Document API | basic or API key |
| `opensearch` | Document API | basic or API key |
| `azuremonitor` | Custom metrics REST | service principal or managed identity |
| `cloudwatch` | PutMetricData, SigV4 | access keys or instance profile |
| `gcp` | Cloud Monitoring `timeSeries.create` | metadata server or service-account key |
| `newrelic` | Metric API | license key |
| `dynatrace` | Metrics ingest line protocol | API token |
| `webhook` | Generic JSON POST | optional header |

### 15.4 Platform Notes

- **Cloud-native auth:** on AWS, Azure and GCP machines, credentials can come from the local metadata service (`auth = instance_profile`, `managed_identity`, `metadata`), so no secret is stored on the host.
- **CloudWatch** request signing needs curl 7.75 or later on Linux/macOS.
- **Google Cloud off-GCP** needs openssl on Linux/macOS to sign the service-account token.
- **Prometheus remote_write is not supported**: it requires protobuf and snappy, which cannot be produced from plain scripts. Use VictoriaMetrics import, OTLP/HTTP or Influx-protocol endpoints instead.

### 15.5 Failure Behaviour

When a backend fails:

- Scheduling and supervision continue.
- The failure is logged and counted.
- That backend's events stay in the spool and are retried with bounded backoff.
- When the spool reaches `max_mb`, events are dropped according to `when_full` and counted.

A backend can never consume unbounded memory or disk (VIGIL-009, VIGIL-014).

---

## 16. Configuration Management

### 16.1 Hot Reload

`config/vigil.config` is checked every tick and parsed again when it was modified. In remote mode, the configuration's source is checked every `check_every` (§6.8). Changes to jobs, schedules, runners, backends, tags and sources take effect without a restart, once anything they need has been fetched (§16.5). Only changes to Vigil's own scripts require a service restart.

Removing a job, disabling it or changing it never stops a run already in progress: the run finishes under the settings and script it started with, and the change applies from the next run.

On Windows, environment variables named by `env:` and `require_env` are re-read from the machine and user scopes every tick, so rotated secrets take effect without a restart. On Linux/macOS, environment changes require a service restart.

### 16.2 Adding a Job

Adding a job never needs a restart:

1. Copy the script into `<root>/scripts/`.
2. Add its `[job.<id>]` block to `vigil.config`.
3. On the next tick the config is reloaded and validated, and the job is scheduled.

On a fleet, the same change is made in the configuration source instead, and each host adopts it at its next check (§16.5).

Copy the script before editing the config. A config saved with a mistake is rejected, the previous configuration keeps running, and `jobs.log` shows the reason. A new job first runs at its next scheduled time (§7.6); `vigil run <job>` runs it once immediately in the foreground for testing. Scripts reached through the `[runners]` map need no executable bit; only files executed directly do, and pre-flight reports them.

### 16.3 Validation

- At startup, an invalid configuration stops Vigil with the full list of errors.
- On reload, an invalid configuration is rejected as a whole; the last known valid configuration stays active and `vigil.supervisor.config_reload_failed` is posted (VIGIL-010).
- A single invalid job does not invalidate the file: that job is skipped, shown as `INVALID` and reported via `invalid_config` until fixed. Other jobs keep running.
- A job whose file disappears is shown as `FILE MISSING` and reported via `file_missing`; it resumes automatically when the file returns.
- Validation is a pure function of the parsed files: it never reads the filesystem, the network or the environment (pre-flight and fetching do, §16.4, §16.5). Each problem is reported once, with its line; a problem in a `[job.*]` section makes only that job invalid, and any other problem rejects the configuration. Messages never contain a credential value.

Error codes, shared by both implementations and the conformance suite (`tests/conformance`):

| Stage | Code | Meaning |
| --- | --- | --- |
| File | `E_FILE_NOT_FOUND`, `E_FILE_UNREADABLE`, `E_FILE_TOO_LARGE` | The file is missing, unreadable or over 1 MiB. |
| Syntax | `E_INVALID_CHAR` | A character other than printable ASCII or tab. |
| | `E_SECTION_SYNTAX`, `E_SECTION_DUPLICATE` | A malformed or repeated `[section]`; its keys are skipped. |
| | `E_KEY_OUTSIDE_SECTION`, `E_KEY_SYNTAX`, `E_NO_EQUALS` | A key before any section, a malformed key, or a line that is none of the allowed forms. |
| Structure | `E_SECTION_UNKNOWN` | A section Vigil does not define. |
| | `E_POINTER_ONLY` | A pointer file containing anything but `config_source`, `config_file`, `state_dir` and the source they name (§6.8). |
| | `E_NOT_FROM_SOURCE` | A fetched configuration setting `config_source`, `config_file` or `state_dir` (§6.8). Checked when fetching. |
| | `E_KEY_UNKNOWN`, `E_KEY_DUPLICATE`, `E_KEY_REQUIRED` | A key not allowed in that section (or not for that source type, §6.9), a single-valued key set twice, or a required key missing (`file`, a runner's `command`, a source's `type` and the keys its type needs, `config_source` and `config_file` together). |
| | `E_KEY_NOT_DEFAULTABLE` | A job-only key in `[defaults]` (§6.6). |
| Values | `E_VALUE_EMPTY` | An empty value (allowed only for `arg`). |
| | `E_DURATION`, `E_INTEGER`, `E_BOOLEAN`, `E_ENUM` | Not a duration (`30s`, `5m`, `2h`, `7d`; zero only for `grace` and `late_start_window`), a whole number, `true`/`false`, or one of the listed words. |
| | `E_TIME`, `E_DAY`, `E_EXIT_CODES` | Not `HH:MM`, a weekday, or `standard`/`nagios`/codes `0-255`. |
| | `E_NAME`, `E_METRIC_NAME` | An instance name or metric name with characters outside its set. |
| References | `E_RUNNER_UNKNOWN`, `E_BACKEND_UNKNOWN`, `E_BACKEND_TYPE`, `E_EXTENSION` | A runner or backend that is not defined, an unknown backend type, or a `[runners]` key that is not an extension. |
| | `E_DESTINATION_UNKNOWN` | `[log_forward] destination` names a `[log_destination.*]` that is not defined (§13.4.1). |
| Tags and environment | `E_TAG_SYNTAX`, `E_TAG_RESERVED`, `E_TAG_DUPLICATE` | A malformed tag, a reserved tag key (§14.6), or a tag name repeated in one section. |
| | `E_ENV_SYNTAX`, `E_ENV_NAME`, `E_ENV_LITERAL`, `E_ENV_DUPLICATE` | A malformed `NAME=value`, an invalid variable name, an `env` value starting with `env:` (§6.5), or a name repeated in one section. |
| Secrets | `E_SECRET_RAW` | A credential key whose value is not `env:NAME`; the value is never shown. |
| Sources | `E_SOURCE_UNKNOWN` | A job or `config_source` names a source that is not defined. |
| | `E_SOURCE_PATH` | A `file` or `config_file` inside a source that is absolute, uses `\` or contains a `..` segment. |
| | `E_URL` | A malformed URL, an `https` source URL not starting with `https://`, or a URL containing credentials (never shown). |
| | `E_SHA256`, `E_SHA256_REQUIRED` | Not 64 hex digits, or missing for a script from an `https` or `sftp` source. |
| Jobs | `E_SCHEDULE_NONE`, `E_SCHEDULE_BOTH`, `E_SCHEDULE_DAYS_ONLY` | An invalid schedule combination (§7.5). |
| | `E_JOB_ID_RESERVED` | A job id starting with `vigil_`. |
| Command | `E_BATCH_ARG`, `E_BATCH_PATH` | A batch file argument or path containing a `cmd.exe` metacharacter (§6.4). |
| Warnings | `W_BACKEND_DISABLED` | A job names a disabled backend. |
| | `W_SCRIPT_UNPINNED` | A script from a `local` source without `sha256`. Also reported when fetching, for a `git` source whose `ref` turns out to be a branch (§6.9). |
| | `W_METRIC_COLLISION` | Two jobs' different base metric names become the same name in a Prometheus-format backend they both send to (§14.1). |

Backend sections are checked for `type`, `enabled`, `timeout` and the `env:` rule on credential keys; the keys specific to each backend type are checked by that backend (§15).

### 16.4 Pre-flight Checks

Before install or start, and on demand, Vigil checks without starting anything:

- Configuration parses and validates.
- Every `env:` and `require_env` variable is set (names only are printed).
- Every job file exists and is runnable through its resolved runner.
- Every runner `command` exists.
- Every job `working_dir` exists.
- `VIGIL_FAULT` is not set (§22.4.1).
- State, log and spool directories are writable.

`vigil precheck <job>` also prints that job's effective settings and their sources (§6.6).

Install and start abort with no changes if any check fails.

### 16.5 Sources and Reconciliation

Vigil watches the configuration and the sources it names. A source pinned to a tag, a commit or a digest never changes; one following a branch or a directory is picked up at its next check (§6.9). Nothing is activated until everything it needs is present and verified.

**Fetcher.** Fetching is done by a worker, `vigil_fetch`, started and supervised like `vigil_sender` (§4.5): detached, with its own state, run token, log and identity checks. A slow or unreachable source therefore never delays a tick, and at most one fetcher runs at a time. The supervisor starts it when a source is due for its check, or when a local change references a script that is not yet cached.

**Reconciliation.** One fetcher run:

1. In remote mode, fetches the configuration file from its source into `cache/staging/` when that source is due (§6.8). Checks each other due source for a new commit or new content. If nothing changed and every referenced script is cached and verifies, it stops: there is nothing to do.
2. Takes the candidate configuration (the local file, or the fetched one) and validates it (§16.3); a fetched file is also checked for `E_NOT_FROM_SOURCE`. An invalid candidate is rejected as a whole.
3. Lists the script references of the candidate's valid jobs, disabled jobs included, so re-enabling one never waits for a fetch.
4. Fetches each reference not already cached, verifies its `sha256` where set, and moves it into the cache. A cached entry is complete or absent, never partial: it is assembled under `staging/` and renamed into place.
5. When every reference is present and verified, writes the candidate's activation record to `state/config.active` atomically (§12.3).

The supervisor reads `state/config.active` each tick. When it changes, the supervisor loads the configuration it names, validates it again and makes it active. The next runs use it.

If anything fails — a source unreachable, a timeout, a rejected login, a digest mismatch, an invalid candidate — nothing changes: the previous activation record, and every file it names, stays in force. The failure is posted (`vigil.source.failures`, §14.5), shown in `jobs.log`, and retried at the next check. A host that loses its source keeps running its last valid configuration indefinitely.

**Activation record.** Names the configuration file and every cached script of the active configuration, each with its digest, and the configuration revision. The revision is the first 12 hex digits of a SHA-256 over those names and digests. Two hosts with the same revision run the same configuration and the same script content. The record survives restarts, so a host that restarts while its source is unreachable starts with its last valid configuration. Purely local configurations have a revision too.

**Running jobs.** A run executes the cached copy named when it was launched, recorded in its launch record and state. Activating a new revision never touches a running run or its files.

**Cache.** `cache/` belongs to Vigil, and deleting it is safe: it is refetched, and the jobs whose scripts are missing show as `FILE MISSING` until it returns. The fetcher removes cache entries that are named neither by the active nor the previous activation record and not used by a run in progress; the previous record's entries are kept so a rollback in the source needs no fetch.

**Per type:**

| Type | How it is fetched |
| --- | --- |
| `git` | `git fetch` of the needed refs into a bare mirror (`cache/<source>/repo.git`), then `git archive` of the commit into `cache/<source>/<commit>/`. Nothing is checked out in the mirror, so no repository hook, filter or submodule ever runs. A tree containing a symbolic link that points outside it is rejected. Credentials come from the service account's Git credential helper or SSH key; Vigil never passes a token on a command line or in a URL. |
| `https` | `curl` on Linux and macOS, with the authentication header passed on stdin (`curl -K -`); `Invoke-WebRequest` on Windows. Certificate verification is never disabled. Redirects to plain HTTP are refused. |
| `sftp` | The OpenSSH `sftp` client in batch mode with `BatchMode=yes` and `StrictHostKeyChecking=yes`: the server's host key must already be in the service account's `known_hosts`, so a first connection can never silently trust an impostor. |
| `local` | A copy from the directory, so a job never runs a file directly from a share that may change or disappear under it. |

Every fetch is bounded by the source's `timeout`; a fetched configuration file larger than 1 MiB, or a script larger than 16 MiB, is rejected.

---

## 17. Security

- **Least privilege:** Vigil runs as an ordinary user in user mode. Jobs run with Vigil's identity; Vigil never elevates.
- **Secrets by reference:** credentials are `env:` references only (§6.5).
- **No secrets on command lines** constructed by Vigil.
- **Script trust:** jobs run with Vigil's permissions. Vigil is not a sandbox; untrusted scripts need OS-level isolation.
- **Sources are trusted code paths:** a configuration source decides what runs on every host that uses it, so it deserves the same review and access control as production code. Vigil relies on the organisation's own controls there (repository permissions, reviews, protected branches, file server access) rather than reproducing them. Vigil adds pinning (§6.9), digest verification, last-known-good fallback, and the rule that fetched configuration can never change where configuration comes from (§6.8).
- **No insecure transports:** `https` only, with certificate verification; `sftp` only with a known host key. Plain HTTP and FTP are not supported.
- **File permissions:** configuration, state, spool and the install directory must not be writable by untrusted users. Install sets owner-only permissions where the OS allows.
- **No remote control:** Vigil exposes no network listener.
- **Script signing:** Windows releases are Authenticode-signed so they run under `AllSigned` execution policy.

---

## 18. Service Management

### 18.1 Install Modes

| OS | User mode (no admin) | System mode (admin) |
| --- | --- | --- |
| Windows | Per-user Run registry entry (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`) starting the supervisor hidden at logon | NSSM service running as a service account |
| Linux | `systemd --user` unit | system unit in `/etc/systemd/system`, running as a dedicated `vigil` user |
| macOS | launchd LaunchAgent | launchd LaunchDaemon |

User mode generally runs only while the user is logged in. Unattended operation needs:

- Linux: lingering (`loginctl enable-linger`), which may need admin once depending on distribution policy.
- macOS: a LaunchDaemon (admin).
- Windows: system mode. Registering any Windows service requires admin. Windows user mode starts at logon only and has **no automatic restart** if the supervisor crashes; it is intended for trying Vigil out and for workstations, and the docs say so.

The docs state plainly that unattended server monitoring realistically needs one admin action at install time. After that the supervisor may run as an unprivileged account.

Windows Task Scheduler and cron are not used, even as launchers.

### 18.2 NSSM

NSSM (public domain) is vendored in `vendor/nssm/` as the 2.24-101 pre-release build, 64-bit and 32-bit, with a NOTICE giving its source and SHA-256 hashes. 2.24 is not used: it fails to start services on Windows 10 Creators Update and later. NSSM is unmaintained upstream; this is stated in the docs.

### 18.3 Workers Survive Service Stop

Each service manager is configured so stopping the service stops only the supervisor:

| Manager | Setting |
| --- | --- |
| NSSM | Do not kill the process tree on stop (verified against the vendored build) |
| systemd | `KillMode=process` |
| launchd | `AbandonProcessGroup = true` |

### 18.4 Service Behaviour

- Start automatically.
- Restart on failure with throttling (to avoid restart storms from a bad deploy). Not available in Windows user mode (§18.1).
- Graceful stop (§10.4).
- Capture supervisor stdout/stderr (NSSM append mode, journald, launchd log paths).

### 18.5 Operator Commands

| Command | Purpose |
| --- | --- |
| `init` | Onboarding (§19). |
| `precheck [<job>]` | Pre-flight checks (§16.4); with a job, also its effective settings (§6.6). |
| `service install` / `service remove` | Register or unregister the service without touching files (for example to switch mode). |
| `start` / `stop` / `restart` | Service control. Stop leaves workers running. |
| `status` | Print `jobs.log`. |
| `supervise [--once]` | The supervisor itself (§4.1), as the service manager runs it: ticks until stopped (TERM or INT on Linux/macOS, stopping the process on Windows), or a single tick with `--once`. Running workers are never stopped with it. Refuses to start while another supervisor owns the state directory, or when the configuration is invalid and no earlier valid one exists. |
| `run <job>` | Run one job once now, in the foreground, for testing: launched, claimed and recorded exactly as the supervisor would. Exits 0 succeeded, 1 warning, 2 failed, 3 unknown, 4 not run (another run may be in progress, the job is unknown or invalid, or the configuration has errors). |
| `resolve <job>` | Confirm that an uncertain run is over so the job can be scheduled again (§11.4). Never kills anything. |
| `uninstall` | Remove Vigil completely (§18.8). |

### 18.6 Install Locations

Everything is installed under one root (layout in §12.1):

| Platform | User mode | System mode |
| --- | --- | --- |
| Linux | `~/.local/share/vigil` | `/opt/vigil` |
| macOS | `~/.local/share/vigil` | `/opt/vigil` |
| Windows | `%LOCALAPPDATA%\Vigil` | `C:\ProgramData\Vigil` |

Outside the root, Vigil creates only:

- The service registration: the systemd unit, the launchd plist, the NSSM service, or the Windows Run entry.
- The `vigil` command: a link in `~/.local/bin` (user mode) or `/usr/local/bin` (system mode) on Linux/macOS; on Windows the root's `app\` folder is added to the user's or machine's `PATH`.

`--prefix <path>` installs to a custom root.

Rationale:

- **One root over OS conventions.** Splitting across `/etc`, `/var/lib` and `/var/log` is more conventional on Linux, but one root makes uninstall a single delete and lets an operator find everything.
- **macOS user mode uses `~/.local/share/vigil`, not `~/Library/Application Support/Vigil`,** because a space in the root path breaks carelessly written job scripts.
- **SELinux:** on Fedora/RHEL with SELinux enforcing, a system-mode service cannot execute scripts from a home directory; system mode therefore always uses `/opt/vigil`, and pre-flight warns when SELinux is enforcing.

### 18.7 Installer

One-line installers, in the style of rustup:

```text
Linux / macOS:  curl -fsSL https://<host>/install.sh | sh
Windows:        irm https://<host>/install.ps1 | iex
```

The installer:

1. Runs pre-flight checks for Vigil's prerequisites (§5.1) and stops before changing anything if one is missing.
2. Downloads a versioned release archive from GitHub Releases and verifies its SHA-256 (`sha256sum`, `shasum -a 256` or `Get-FileHash`) before using it.
3. Unpacks it into the root. On upgrade, only `app/` and `vendor/` are replaced; `config/` and `scripts/` are never touched.
4. Registers the service for the chosen mode.
5. Runs `vigil init` on a fresh install (§19).

Details:

- Every prompt has a flag equivalent (`sh -s -- --system --backend datadog`), so the installer runs unattended from deployment tooling. When piped, prompts read from `/dev/tty`, because standard input is the script itself.
- `install.sh` is POSIX `sh`, since it is what `| sh` runs; it switches to bash for the rest of the install.
- Windows: the documented one-liner first enables TLS 1.2, which PowerShell 5.1 on older servers may not use by default. After verifying the hash, the installer removes the downloaded-from-the-internet mark from Vigil's files so a RemoteSigned execution policy does not block them; signed releases (§17) avoid the issue under AllSigned.
- A version can be pinned (`--version 1.2.0`).

Many IT teams do not allow piping a remote script into a shell. The docs therefore give an equivalent reviewed path: download the release archive and its published checksum, verify, read the installer, and run it locally. Both paths run the same installer.

### 18.8 Uninstall

`vigil uninstall` removes Vigil completely:

1. Stop and unregister the service.
2. Terminate Vigil's running workers. Only processes whose ownership is proven (§11.5) are terminated — never "every process that mentions the install folder".
3. Wait for file handles to be released (Windows).
4. Delete the root, the `vigil` command link or `PATH` entry, and the service registration.

Before deleting, it lists what will be removed — including how many scripts are in `scripts/` — and asks for confirmation:

- `--yes` skips the confirmation, for unattended use.
- `--keep-config` keeps `config/` and `scripts/`, so a reinstall picks up where it left off.

Environment variables set outside Vigil (machine environment, `vigil.env` aside) are left untouched. Uninstall is idempotent: running it on a clean machine succeeds and changes nothing. On Windows, when the root cannot be deleted because the uninstall itself is running from inside it, deletion is completed by a short-lived detached process after Vigil exits.

---

## 19. Onboarding

`vigil init` generates a starting configuration:

1. Detects the OS and available shells.
2. Asks which backend(s) the organisation uses.
3. Writes a commented config with the correct runners, paths, `env:` placeholders and one sample job.
4. Prints the environment variable names that must be set.

`init` never asks for or stores secret values. Every prompt has a flag equivalent so it can run unattended from deployment tooling.

### 19.1 Check Library

The repository includes a `checks/` library of ready-made job scripts, per platform: disk, memory, load, TCP port, certificate expiry and similar. `init` can enable a basic set. Contributed checks follow a short guide:

- Print results as `metric` lines (§14.3).
- Use meaningful exit codes, or Nagios codes with `exit_codes = nagios`.
- Start with a header comment: purpose, platforms, prerequisites, metrics emitted, suggested alert thresholds.
- POSIX checks stay bash 3.2 compatible; PowerShell checks stay 5.1 compatible.
- Include a test.

---

## 20. Resource Limits

Explicit, configurable limits exist for:

- Concurrent workers and pending runs.
- Log file size and retention.
- Spool size.
- Metric lines per run.
- Backend request timeouts and retries.
- Configuration file size.

`max_runtime` is the only per-job limit, and it is optional. Vigil does not claim CPU or memory isolation.

---

## 21. Failure Behaviour

| Scenario | Behaviour |
| --- | --- |
| Config invalid at startup | Refuse to start; print all errors. |
| Config invalid on reload | Keep last valid config; post `config_reload_failed`. |
| One job invalid | Skip that job; `INVALID`; `invalid_config` metric. |
| Required env var missing at start | Refuse to start; print all missing names. |
| Job file missing | Skip; `FILE MISSING`; `file_missing` metric; auto-resume. |
| Job exits non-zero | Classified per `exit_codes`; failure metric. |
| Job exceeds `max_runtime` | Tree terminated; `timed_out`. |
| Worker vanishes, job process gone | `crashed`; crash metric; next scheduled run. |
| Worker vanishes, job process alive | `orphaned`; no respawn until it exits. |
| Supervisor crashes | Workers continue; supervisor resumes from state on restart. |
| Machine reboots | Boot id differs: every `running` run is concluded over (outcome from spool or `crashed`); normal scheduling. |
| Corrupt or missing state file | Liveness established from independent evidence (§11.3). Live run: protected, no duplicate. Concluded run: reconciled or `crashed`, file quarantined. Uncertain: job held and reported (§11.4). |
| Backend unreachable | Spooled and retried; other backends and jobs unaffected. |
| Spool full | Drop per policy; counted. |
| Disk full | Reported where possible; supervisor keeps running. |
| Clock change | §7.8. |

Where an outcome cannot be determined, Vigil reports the uncertainty rather than inventing a result.

---

## 22. Testing and Verification

### 22.1 Shared Conformance Suite

Both implementations run the same cases from `tests/conformance/` and must produce identical results, byte for byte. Each suite feeds an input to both and compares the output with a recorded expectation:

| Suite | Input | Checks |
| --- | --- | --- |
| `parser` | A configuration file | The parsed sections, keys and values, and parse errors. |
| `validate` | A configuration file | Every error and warning, with its line and code (§16.3). |
| `effective` | A configuration file | Each job's effective settings and where each value came from (§6.6). |
| `command` | A configuration file | The command line built for each job, per platform (§6.4). |
| `schedule` | A configuration and a decisions table | The scheduling decision for each row of inputs (§7.9). |
| `outcome` | A table of `exit_codes`, exit code and outcome | The run outcome for each row (§10.2). |
| `metrics` | A run's captured stdout | Its metrics and perfdata, invalid lines and the run summary (§14.3, §14.4). |
| `events` | A configuration, a finished run and its stdout | The spool events of the run, with their tags (§4.5, §14). |
| `mocks` | The example configurations in `tests/mocks/` (§6.7) | Their validation and effective settings. |

CI runs every suite on Windows PowerShell 5.1, Linux bash and macOS bash 3.2 (§22.5).

### 22.2 Unit Tests

Config parsing and validation, schedule calculation, exit-code classification, metric-line parsing, state transitions, identity matching, spool bounds and backend formatting.

### 22.3 Integration Tests

Successful, failing and hung jobs; Nagios exit codes; child-process spawning; `max_runtime` tree termination; supervisor restart with live workers; reboot simulation; overlap and concurrency limits; backend failure and recovery; hot reload.

### 22.4 Fault Injection

General: kill workers; kill the supervisor; kill a worker while its job runs; remove files; break the network; fill the spool; change the clock; flood stdout.

State and ownership (§11) — each test must show the run was protected or correctly concluded, not merely that a replacement started:

1. Corrupt the state file while the worker is still running.
2. Delete the state file while the worker is still running.
3. Kill the supervisor while a worker remains active.
4. Restart the supervisor and reconcile surviving workers.
5. Simulate PID reuse: a recorded PID now belonging to an unrelated process.
6. Corrupt the state file after the worker has completed.
7. Interrupt a state write midway (leftover temporary file, truncated file).
8. Let a job pass its deadline while the supervisor is down.
9. Confirm the run token is released when the worker is killed.
10. Make ownership uncertain and confirm the job is held, reported and never killed.
11. Confirm `on_uncertain = replace` starts a run and posts `possible_duplicates`.
12. Confirm an unrelated process is never terminated using stale ownership data.
13. Reboot (or simulate a boot id change) with runs recorded as `running`.
14. Kill the worker while its job process keeps running (orphan), on each platform.
15. Let a worker finish while the supervisor is down; on return, the outcome is recorded without a crash or a rerun.
16. Make the worker's final state write fail; the outcome is reconciled from its spool file.
17. Confirm the supervisor never writes a job's state file while the run token is held or a process carries the run id — including after the deadline passes.
18. Confirm `on_uncertain = manual` keeps the job held after the evidence clears, until `vigil resolve`.
19. Restart the supervisor while a job is held; it stays held from its recovery record.

Launch window (§4.3, §11.3) — the invariant is *exactly one run per launch, or none, never two*:

20. Crash the supervisor at `launch.after_record` (record written, worker not started); after restart the launch is abandoned past its grace and the job is not run twice.
21. Crash the supervisor at `launch.after_spawn`; the worker claims, and the restarted supervisor sees it Alive and starts nothing.
22. Delay the worker past the launch grace before it claims (`worker.before_claim` with a pause); the supervisor abandons, and the late worker exits without running the job.
23. Run claim against abandonment concurrently, at least 1,000 iterations per platform; exactly one side wins every time.
24. Leave a launch record from a previous boot; it is abandoned immediately.

Fan-out (§4.5) — the invariant is *every event reaches every one of its targets at least once; no partial file is ever sent*:

25. Crash the sender at `fanout.after_claim`, `fanout.after_targets`, after each placement (`fanout.after_place:N`) and at `fanout.before_retire`; after restart every target holds every event.
26. Crash mid-copy; the temporary file is never sent and is cleaned up on resume.
27. Remove a backend from the config between a crash and the resume; the drop is counted with `reason=backend_removed`.
28. Fill the disk part-way through a fan-out; the incoming file is not retired and the fan-out completes once space returns.
29. Randomised crash loop over all launch and fan-out crash points, per platform, checked against both invariants.

### 22.4.1 Crash Points

Timed kills cannot reliably land inside windows that last microseconds on three operating systems, so the code carries named crash points. When the environment variable `VIGIL_FAULT` names a point (for example `fanout.after_place:2`), the process exits immediately with code 99 when it reaches it.

Points: `launch.after_record`, `launch.after_spawn`, `worker.before_claim`, `worker.after_claim`, `worker.after_spool`, `worker.after_state`, `fanout.after_claim`, `fanout.after_targets`, `fanout.after_place:N`, `fanout.before_retire`, `sender.after_send`, `state.after_temp` (temporary file written, not yet renamed).

A crash point only ever makes Vigil's own process exit; it cannot change behaviour otherwise. The supervisor logs a warning at startup and pre-flight fails if `VIGIL_FAULT` is set in the service environment, so it cannot be left on in production by accident.

### 22.5 Platform Matrix

A pass on one platform is never evidence for another. The v1 matrix:

| Platform | Where it is tested |
| --- | --- |
| Windows 11, PowerShell 5.1 and 7 | Development machine; Windows Sandbox for clean-install tests |
| Windows Server 2016 / 2019 / 2022 / 2025 | Free 180-day evaluation VMs in Hyper-V; GitHub Actions Windows runners |
| Windows Server 2012 R2 + WMF 5.1 | Evaluation VM where obtainable |
| Ubuntu (Debian family) | WSL2 with systemd enabled; GitHub Actions Ubuntu runners |
| Fedora (Red Hat family, SELinux enforcing) | Dedicated Fedora machine |
| macOS, bash 3.2, launchd | MacBook; GitHub Actions macOS runners |
| Cygwin-hosted jobs | Windows development machine |

Backends are simulated: most tests assert on spool contents; sender tests run against a test-only local HTTP receiver (.NET `HttpListener` on Windows, a small test script on Linux/macOS) that records requests and can simulate failures. Optional Docker-based tests run real VictoriaMetrics and an OpenTelemetry Collector. Test tooling is never shipped.

### 22.6 Evidence

Every result records Vigil version, OS and version, shell version, test id, result and artifacts. Unexecuted tests are never reported as passing.

---

## 23. Engineering Invariants

**VIGIL-001 — Single Supervisor Ownership.** Only one supervisor may own a state directory.

**VIGIL-002 — Bounded Concurrency.** Running workers never exceed `max_concurrent` while the supervisor is running.

**VIGIL-003 — Declared Runtime Limits.** A declared `max_runtime` is enforced by tree termination within one tick of expiry while the supervisor runs. Jobs without one are unbounded by design.

**VIGIL-004 — Failure Isolation.** A job's failure never terminates the supervisor or another job.

**VIGIL-005 — Single-Writer State.** A job's state file has at most one writer at any moment. While a run may be alive, that is its worker. The supervisor writes it only after proving the worker can no longer write (run token released and no process carrying the run id); otherwise it writes only its own recovery record (§12.3).

**VIGIL-006 — Safe Recovery.** A run without a worker-written final state is never treated as successful.

**VIGIL-007 — Process Identity.** A PID alone is never sufficient to treat a process as a live job or to kill it; name and, where available, start time must match.

**VIGIL-008 — No Backlog.** Missed runs are skipped, never replayed in bulk.

**VIGIL-009 — Telemetry Independence.** Backends never block scheduling, supervision or each other.

**VIGIL-010 — Configuration Safety.** An invalid configuration never replaces the last valid one.

**VIGIL-011 — No Silent Failure.** Every failure produces a local record where storage allows.

**VIGIL-012 — Native Only.** Vigil requires only its documented prerequisites. No cron, Task Scheduler, agents or compiled code of its own (NSSM excepted).

**VIGIL-013 — Explicit Privilege.** Vigil never elevates its own or a job's privileges.

**VIGIL-014 — Bounded Storage.** Logs, state history and spool have explicit limits.

**VIGIL-015 — Graceful Degradation.** Unavailable backends or optional features never stop core scheduling.

**VIGIL-016 — Secrets by Reference.** Credentials appear in configuration only as `env:` references; raw values are rejected.

**VIGIL-017 — Workers Outlive the Supervisor.** Stopping or restarting the supervisor never terminates running workers, except through `vigil uninstall`.

**VIGIL-018 — Conservative Orphan Recovery.** Loss or corruption of state never, by itself, authorises terminating or replacing a potentially active run. Liveness and ownership are established from independent evidence first; when they cannot be, the work is preserved, conflicting runs are deferred and the uncertainty is reported. Evidence of a run is written before its worker starts, so no crash can leave a running worker with no trace.

Each invariant has a documented enforcement mechanism and regression tests.

---

## 24. Known Limitations

- `max_runtime` is not enforced while the supervisor is down, and is accurate to one tick.
- Scheduling resolution is one tick (default 60 seconds).
- `queue_one` pending runs are lost on supervisor restart.
- Processes that deliberately escape their process group or tree may survive termination.
- Cygwin emulates fork/exec; Windows parent/child links may differ from Cygwin's, so tree termination of Cygwin jobs needs its own verification.
- On Windows, a program that splits its command line by rules other than the Microsoft C runtime's may receive different arguments from those configured. Batch files reject arguments containing `cmd.exe` metacharacters (§6.4).
- bash on Linux/macOS has no portable monotonic clock; elapsed time may be affected by clock changes.
- Process start time is unavailable or coarse on some platforms; identity then relies on the run id, the run token and PID plus name.
- Ownership guarantees differ by platform (§11.2). Linux and macOS: the run token identifies the worker and every job process that inherited it. Windows: the run token proves the worker is alive but not which process it is, and job processes are tracked by recorded identity only. A job process that closes inherited files escapes token tracking on every platform.
- A job whose run stays uncertain is held until the evidence resolves or an operator runs `vigil resolve`; it is reported every tick but does not run in the meantime (unless `on_uncertain = replace`). Under `manual` it stays held until `vigil resolve` even after the evidence resolves.
- After a supervisor restart, deadlines are enforced from recorded timestamps, which are affected by clock changes; uninterrupted monotonic timing is only available while the supervisor runs.
- bash cannot force a single file to disk, so after a power loss a just-written state file may be empty or truncated; it is then handled as unreadable state (§11.3). Windows flushes before renaming, but filesystem and storage caches can still lose a write.
- Process-tree termination on Windows uses `taskkill /T`, which can miss children whose parent has already exited. Windows Job Objects would close this gap but need compiled code (§26).
- User-mode installs run only while the user is logged in unless lingering (Linux) or system mode is used.
- Prometheus remote_write is not supported.
- NSSM is unmaintained upstream.
- Environment variable changes require a restart on Linux/macOS.
- Windows user mode starts at logon only and is not restarted automatically if the supervisor crashes.
- macOS privacy controls (TCC) silently block launchd jobs from `~/Documents`, `~/Desktop`, `~/Downloads` and external volumes unless `/bin/bash` is granted Full Disk Access.
- macOS still ships bash 3.2 as `/bin/bash`; if Apple removes it, macOS support needs a replacement shell.
- WSL needs systemd enabled (`systemd=true` in `/etc/wsl.conf`) for the systemd service.
- A host cannot override a single setting of a job it receives from a source; each section is defined once (§6.8). Per-host differences are expressed by including different files from the source.
- `https` and `sftp` sources deliver single files; scripts that need files beside them should come from `git` or `local` sources.
- A `git` reference to a commit that is not the tip of a branch or a tag must be fetchable by its id; most hosted Git services allow this, a self-hosted server may need `uploadpack.allowReachableSHA1InWant`.
- Scripts without a digest, from a `local` source or a `git` branch, may briefly differ between hosts until each has made its next check (§6.9).
- A worker reads `config/vigil.config` when it starts. If that file was saved with an error after the supervisor launched the run, the worker refuses to run, and the launch is abandoned after the 120-second launch grace (§11.3); the job runs again at its next slot once the file is fixed.

---

## 25. v1 Acceptance Criteria

Vigil v1 is ready when:

- [ ] The supervisor runs on Windows PowerShell 5.1, Linux bash and macOS bash 3.2.
- [ ] User-mode and system-mode installation work on all three platforms.
- [ ] The one-line installers and the reviewed manual path work on all three platforms, verify checksums, and never overwrite `config/` or `scripts/` on upgrade.
- [ ] `vigil uninstall` removes everything (or keeps `config/` and `scripts/` with `--keep-config`) and is idempotent.
- [ ] A job added to `vigil.config` is scheduled without a restart, and a pointer file switches the instance to its fetched configuration.
- [ ] Configuration and scripts are fetched from `local`, `git`, `https` and `sftp` sources; a failed fetch or an invalid candidate leaves the last valid configuration active, including across a restart.
- [ ] A script version changes on a host only when its configuration changes; running jobs are never interrupted by an activation.
- [ ] Hosts report their configuration revision, and the same revision means the same configuration and script content.
- [ ] The config parser and validator behave identically on PowerShell and bash (shared conformance suite), and every example configuration in `tests/mocks/` validates.
- [ ] `run_every`, `run_at` (lists) and `run_on_days` schedule correctly, including missed-run handling.
- [ ] Runners, the extension map, `{file}` substitution and direct execution work.
- [ ] Per-job overrides follow §6.6 identically on PowerShell and bash, and `vigil precheck <job>` shows each effective value's source.
- [ ] Standard, Nagios and explicit exit-code classification work.
- [ ] Global concurrency and overlap policies are enforced.
- [ ] Workers survive supervisor stop and restart on all three platforms.
- [ ] Crashed, orphaned and identity-mismatched workers are handled per §11.3.
- [ ] Corrupt or missing state never, by itself, causes a run to be killed or a duplicate run to start.
- [ ] A live run is recognised from its run token and run id alone, with its state file deleted or corrupted.
- [ ] A finished run whose final state was lost is reconciled from its spool file.
- [ ] A reboot is recognised from the boot id and all prior runs are concluded.
- [ ] A supervisor crash at any point of a launch never produces two runs; a worker that loses its claim never runs the job.
- [ ] An interrupted fan-out never loses a destination or sends a partial file; every drop is counted.
- [ ] The crash points of §22.4.1 drive the launch and fan-out tests on every platform.
- [ ] Uncertain runs are held, reported every tick, resolvable by `vigil resolve`, and never killed; a held job stays held across supervisor restarts.
- [ ] The supervisor never writes a state file whose worker may still be alive; it takes over writing only after proving the worker can no longer write.
- [ ] `on_uncertain` `wait`, `replace` and `manual` behave per §11.4.
- [ ] A reused PID can never authorise a termination.
- [ ] Every test in §22.4 passes on Windows, Linux and macOS separately.
- [ ] `max_runtime` terminates the whole process tree on all three platforms.
- [ ] Invalid configuration is rejected safely, at startup and on reload.
- [ ] `env:` enforcement rejects raw secrets.
- [ ] Each job has its own log; `jobs.log` reflects every state.
- [ ] Job-emitted metric lines are parsed and forwarded.
- [ ] Nagios performance data is parsed, unit-normalised and forwarded.
- [ ] The file backend and at least the Datadog, OTLP and Splunk backends work.
- [ ] Backend failures do not block jobs; the spool is bounded.
- [ ] Fault-injection tests cover §22.4.
- [ ] `init`, installation and configuration are documented.
- [ ] Optional log forwarding (§13.4) sends supervisor and job logs to an OTLP destination, resumes from its checkpoints after any restart, reports every gap, and never affects jobs, scheduling or metrics delivery.
- [ ] Known limitations are published.

Not every backend type is required for v1. Reliable scheduling and supervision come before breadth of backends.

---

## 26. Future Development

- Bounded catch-up policies for missed runs.
- Cron-style expressions.
- Per-job CPU and memory limits where the OS supports them for unprivileged users.
- Stronger process containment: Windows Job Objects and Linux cgroups (`systemd-run --scope`) for complete tree termination. Deferred from v1 because Job Objects need compiled code from PowerShell 5.1 and cgroup scopes differ between user and system mode; the run token and run id already establish ownership without them.
- Package-manager distribution (winget, Chocolatey, Homebrew, apt, dnf).
- Signature verification of configuration revisions (signed Git tags or commits, signed manifests) before activation.
- Log forwarding: native Splunk HEC and Datadog log adapters, and more than one destination (§13.4).
- Per-host overrides of jobs received from a source.
- Further source types where they can be secured, such as FTPS or object storage, and archive sources that deliver a folder over `https`.
- Additional backend types.

None may compromise the simplicity or reliability of the supervisor.

---

## 27. Success Criteria

Vigil succeeds when an operator on a brand-new machine can:

1. Install it with native tools and no agent.
2. Point it at a script in any language.
3. Set a schedule.
4. Start the service.
5. See every run's outcome and the script's own metrics in the backend they already use.
6. Survive crashes and reboots without manual repair.
7. Never think about Vigil again.

---

## 28. Final Principle

Vigil must remain operationally boring.

**Small supervisor. Independent workers. Explicit state. Predictable recovery. Observable outcomes.**
