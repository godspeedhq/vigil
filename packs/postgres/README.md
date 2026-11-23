# The postgres pack

A PostgreSQL server, on this machine or any it can reach (a container, another server, a managed service such as RDS or Cloud SQL), through PostgreSQL's own client tools (`psql`, `pg_isready`): a machine that runs Vigil but not PostgreSQL needs only the client package. It logs in as a read-only role, never a superuser.

1. Create the role once, as a database administrator:

   ```sql
   CREATE ROLE vigil_monitor LOGIN PASSWORD '...' IN ROLE pg_monitor;
   ```

2. Give Vigil its password: `vigil secret set POSTGRES_MONITOR_PASSWORD`, as the account Vigil runs as (`sudo -u vigil vigil secret set ...` on Linux; an elevated prompt on Windows). The job reads it with a `secret:` reference when it runs; it is never in the configuration.
3. `vigil pack enable postgres`. It says what is still missing, such as the secret, and the settings the jobs use: they connect to `localhost:5432`, database `postgres`; for anything else, edit their `env` lines in `vigil.config`. `vigil pack list` says the same later.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| Client tools on the Vigil machine | `psql` and `pg_isready`: Debian and Ubuntu `postgresql-client`, Fedora and RHEL `postgresql` | `psql` and `pg_isready`: Homebrew's `libpq` | `psql.exe` and `pg_isready.exe`: PostgreSQL's installer (its command line tools) or its zip of binaries. Found on the `PATH`, or under `Program Files\PostgreSQL\<version>\bin` |
| The server | PostgreSQL 14 or later for `postgres_activity` to `postgres_io`; any supported version for `postgres_status` and `postgres_size` | | |
| A role | `vigil_monitor`, read-only, in `pg_monitor` (step 1); `pg_hba.conf` must let it in from the Vigil machine | | |
| A secret | `POSTGRES_MONITOR_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |
| Where to connect | Each job's `env` lines: `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` | | |

The client must be on the `PATH` the Vigil service runs with, as well as yours. A package manager's `/usr/bin` is; Homebrew's `libpq` is not, as it is keg-only. Give such jobs an `env` line for it, such as `env = PATH=/opt/homebrew/opt/libpq/bin:/usr/bin:/bin`.

## Its jobs

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `postgres_status` | Up, connections and the limit, the longest query and transaction, commits, rollbacks, deadlocks, cache hits | Yes | Yes | Yes |
| `postgres_size` | Each database's size | Yes | Yes | Yes |
| `postgres_activity` | Sessions active, idle and idle in a transaction; those waiting on a lock and those blocked by another; the longest lock wait and the longest idle transaction | Yes | Yes | Yes |
| `postgres_replication` | On a primary: replicas streaming, each one's lag in bytes and seconds, unused replication slots and the WAL each slot keeps. On a replica: whether it receives, and how far its replay is behind | Yes | Yes | Yes |
| `postgres_wraparound` | Each database's transaction ID and multixact age, as a count and as a percent of the limit where PostgreSQL stops accepting writes; the oldest transaction anything still needs | Yes | Yes | Yes |
| `postgres_vacuum` | Each database's dead rows and the tables past the autovacuum threshold; autovacuum workers running and the limit | Yes | Yes | Yes |
| `postgres_io` | Checkpoints on schedule and forced, temporary files and their bytes, WAL written (running totals) | Yes | Yes | Yes |

Each script's header says what its metrics mean and how to read them.

A server that does not answer reports `postgres.up` 0, and the run succeeds: that is a reading. The other jobs then print nothing and succeed, since `postgres_status` has said it. A refused login fails the run, and its log says why.

**Several servers:** `vigil pack enable` writes one copy of the jobs. For another server, copy a job's section in `vigil.config` under a new name (`[job.postgres_status_db2]`) and change its `env` lines; each copy reports with its own `job` tag.

## What to alert on

Starting points, not rules: Vigil runs the jobs and delivers what they print, and the alerts are yours, in the backend you already use. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Give most alerts a few minutes, since a backup or a nightly report holds a transaction open for a while, and a replica that restarts leaves its slot unused for a moment, and that is healthy. The last column is what the test servers showed, in the console output of [PostgreSQL 18](../../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-postgres-18-replication/console.txt), [PostgreSQL 14](../../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-postgres-14-replication/console.txt) and [Windows](../../tests/integration/backends/reports/runs/2026-11-19/windows/pack-postgres-windows/console.txt): some of it caused on purpose, and where we caused nothing, it says so. Everything not here (commits, rollbacks, checkpoints, temporary files, WAL, and `last_replay_seconds`, which grows whenever the primary has nothing to write) is for dashboards.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `postgres.up` | 1 | | 0: the server does not answer | `up 0` on the replica, stopped on purpose, and with the job pointed at port 1, where nothing listens |
| `postgres.connections_pct` | Below 70 | 70 to 90 | Above 90: new connections will soon be refused | Not caused: 1 to 2 |
| `postgres.wraparound.xid_pct`, `mxid_pct` | Below 10 | Above 20 and climbing: autovacuum is not keeping up | Above 50: plan a `VACUUM (FREEZE)` of the oldest tables now. Near 100, PostgreSQL refuses writes | Not caused: 0 on every database |
| `postgres.wraparound.oldest_xmin_age_count` | Small, and falling back as transactions end | Rising for an hour or more: something holds back vacuum | Hundreds of millions: end the old session, or drop the abandoned slot or prepared transaction | Not caused: 0 on every run |
| `postgres.replication.replicas` (a primary) | As many as you run | | Fewer: a replica is not streaming, and falls further behind | `replicas 0` with the replica stopped, 1 again once it started |
| `postgres.replication.receiver_up` (a replica) | 1 | | 0: it serves older and older data | Not caused: 1 on every run. A stopped replica cannot be asked: its `postgres.up` reads 0 |
| `postgres.replication.is_replica` | As you set it up: 0 on the primary, 1 on each replica | | Changed when no one failed over: a replica was promoted, and no longer follows the primary | Not caused: 0 on the primary and 1 on the replica on every run |
| `postgres.replication.lag_bytes`, `lag_seconds` (a primary); `replay_lag_bytes` (a replica) | Near 0, and a few seconds at most | Rising for 15 minutes or more, and not falling after heavy writes end | Rising for an hour: the replica serves old data, and a failover would lose what it has not received | Not caused: 0 on every run, after the replica stopped and started again too |
| `postgres.replication.slots_inactive`, `slot_retained_bytes` | 0, and steady | `slots_inactive` above 0 for 15 minutes or more: a replica is down, or a slot was left behind | `slot_retained_bytes` growing on an unused slot: it keeps every WAL file until the disk fills | `slots_inactive 1` with the replica stopped; `slot_retained_bytes 19285704` on a slot the test made and left unused |
| `postgres.activity.waiting`, `blocked`, `longest_wait_seconds` | 0, or briefly above | `longest_wait_seconds` above a few seconds, again and again | `blocked` growing, or `longest_wait_seconds` in minutes: something holds a lock, and everything behind it waits | `waiting 1`, `blocked 1` and `longest_wait_seconds 4` (6 and 7 on Windows): a session waiting for a lock the test held |
| `postgres.activity.longest_idle_in_transaction_seconds`, `idle_in_transaction` | 0, or a few seconds | Above a minute, again and again, or `idle_in_transaction` rising | 10 minutes or more: the session holds its locks and holds back vacuum | `idle_in_transaction 1` and `longest_idle_in_transaction_seconds 6` (8 and 9 on Windows): a session the test left idle in its transaction, holding a lock |
| `postgres.longest_transaction_seconds`, `longest_query_seconds` | Seconds | Minutes: it holds back vacuum | Still growing, on a busy database | `longest_query_seconds 4` and `longest_transaction_seconds 4`, from a transaction the test held open (`pg_sleep(30)`) |
| `postgres.deadlocks_count` (as a rate) | 0 | Any | Rising | Not caused: 0 on every run |
| `postgres.vacuum.tables_due_count`, `dead_tuples_count` | `tables_due_count` 0, or briefly above while workers catch up | `tables_due_count` above 0 for an hour or more | `dead_tuples_count` growing run after run with tables due: tables bloat and queries slow. Look for a long open transaction holding vacuum back | `dead_tuples_count 20000` and `tables_due_count 1` in `orders`: a table the test made with autovacuum off, filled and emptied |
| `postgres.vacuum.autovacuum_workers` | Below `autovacuum_max_workers` | At it for an hour or more: tables wait their turn | | Not caused: 0 of 3 |
| `postgres.cache_hit_pct` | Above 99, on a busy database | Falling | Well below your usual | Not caused: 94 to 99 |
| `postgres.database.size_bytes` | Growing as the data does | Growing much faster than the data: bloat that vacuum does not keep up with | Close to the space left on its disk | Not caused: under 9 MB a database |

## How it was tested

**Tested** on 2026-11-19 on the Fedora 44 test machine, against **PostgreSQL 14.25 and 18.1**, each a primary with a streaming replica (`compose.replication.yaml`), by `tests/integration/backends/scripts/run-replication.sh`: `service-packs.sh` through Vigil, **58 passed, 0 failed** on each, then the replica stopped and started. The full console output, with the versions of everything it ran: [PostgreSQL 18](../../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-postgres-18-replication/console.txt), [PostgreSQL 14](../../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-postgres-14-replication/console.txt). **On Windows**, every job on Windows PowerShell 5.1 and PowerShell 7, against PostgreSQL 18.1 with a replica on another machine, then through Vigil itself on Windows: [the console output](../../tests/integration/backends/reports/runs/2026-11-19/windows/pack-postgres-windows/console.txt). From PostgreSQL 18, on Linux:

A session holds a lock, idle in its transaction, and a second waits for it:

```text
  PASS  postgres: activity runs
        metric active 2
        metric idle 0
        metric idle_in_transaction 1
        metric waiting 1
        metric blocked 1
        metric longest_wait_seconds 4
        metric longest_idle_in_transaction_seconds 6
```

Replication, from both sides, as the replica stops and starts again:

```text
# Both sides, streaming.
$ PGPORT=15433 bash packs/postgres/replication.sh
metric is_replica 0
metric replicas 1
metric slots_inactive 0
metric lag_bytes 0 replica=replica1
metric lag_seconds 0 replica=replica1
metric slot_retained_bytes 0 slot=replica1
$ PGPORT=15434 bash packs/postgres/replication.sh
metric is_replica 1
metric receiver_up 1
metric replay_lag_bytes 0
metric last_replay_seconds 5

# The replica stops.
$ PGPORT=15433 bash packs/postgres/replication.sh
metric is_replica 0
metric replicas 0
metric slots_inactive 1
metric slot_retained_bytes 0 slot=replica1
$ PGPORT=15434 bash packs/postgres/status.sh
metric up 0

# The replica starts again, and catches up.
$ PGPORT=15433 bash packs/postgres/replication.sh
metric is_replica 0
metric replicas 1
metric slots_inactive 0
metric lag_bytes 0 replica=replica1
metric lag_seconds 0 replica=replica1
metric slot_retained_bytes 0 slot=replica1
$ PGPORT=15434 bash packs/postgres/replication.sh
metric is_replica 1
metric receiver_up 1
metric replay_lag_bytes 0
metric last_replay_seconds 12
```

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
