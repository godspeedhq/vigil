# Vigil packs

A pack is a set of scripts and jobs that gives a machine useful metrics straight away. `vigil init` turns on the base pack, and `vigil pack` manages them after that. [SPECIFICATION.md](../SPECIFICATION.md), section 18.10, has the full format.

## What's here

```text
packs/<name>/pack.config    the pack's version, jobs and metrics
packs/<name>/linux/         scripts for Linux
packs/<name>/macos/         scripts for macOS
packs/<name>/windows/       scripts for Windows
```

Each release carries the packs, signed with it, and a machine only ever holds its own platform's scripts.

## The base pack

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `base_cpu` | CPU in use, split into programs and the kernel; on Linux, I/O wait and steal too | Yes | Yes | Yes |
| `base_memory` | Memory in use and available; swap on Linux and macOS, commit on Windows | Yes | Yes | Yes |
| `base_disk` | Space used per file system; inodes on Linux and macOS | Yes | Yes | Yes |
| `base_diskio` | Bytes and operations read and written per disk; busy time on Linux | Yes | Yes | Yes |
| `base_network` | Bytes, packets, errors and drops per interface | Yes | Yes | Yes |
| `base_load` | Load averages | Yes | Yes | No |
| `base_services` | Failed services | Yes | Yes | Yes |
| `base_processes` | The 10 programs using the most CPU and the 10 using the most memory, by name | Yes | Yes | Yes |
| `base_host` | Uptime, process count, cores, and an `info` metric tagged with the OS, its version, the kernel and the CPU model | Yes | Yes | Yes |

Every metric is listed, with an example, in its script's header, and a metric a platform cannot report is named there too. Counters (bytes, packets, operations) are running totals since boot: graph them as a rate. `base_processes` sends program names only, never a process id or a command line.
On Windows the scripts read the kernel, .NET and the service manager, not WMI, so they work when Vigil runs as a standard user started over SSH, where WMI refuses. One thing cannot: there, the service manager refuses to list services too, so `base_services` fails and says so. Run Vigil as a service (`--system`), or from a desktop logon, to have it.

## Reading the results

These are starting points, not rules: tune them to what's normal on each machine. Each script's header has the same guide, with an example of its output.

| Metric | Healthy | Watch | Act |
| --- | --- | --- | --- |
| `system.cpu.used_pct` | Below 70 | 70 to 90 for 15 minutes or more | Above 90 for 5 minutes or more |
| `system.memory.used_pct` | Below 80 | 80 to 90, or climbing steadily | Above 90 for 5 minutes or more |
| `system.disk.used_pct` | Below 80 | 80 to 90, or growing fast | Above 90 |
| `system.network.rx_bytes`, `tx_bytes` (as a rate) | Well below the link speed | Above 70 percent of the link speed for 15 minutes or more | Close to the link speed, or no traffic where there should be some |
| `system.network.rx_errors`, `tx_errors` (as a rate) | 0 | Rising | Rising steadily: a cable, a port or a driver |
| `system.diskio.busy_ms` (as a rate, Linux) | Below 500 a second (50 percent busy) | Above 800 a second for 15 minutes or more | Near 1000 a second with work waiting |
| `system.memory.commit_used_bytes` (Windows) | Well below `commit_limit_bytes` | Within 10 percent of it | At it: programs fail to get memory |
| `system.load.load1`, `load5`, `load15` | Below the number of cores | 1 to 2 times the cores for 15 minutes or more | Above 2 times the cores for 5 minutes or more |
| `system.services.failed` | 0, or your usual number on macOS and Windows | Higher than usual on macOS | 1 or more on Linux, or still rising elsewhere |

## Service packs

For what a server runs. They are off until you turn one on: `vigil init` never enables them, and nothing touches a database or a web server uninvited.

### postgres

A PostgreSQL server, on this machine or any it can reach (a container, another server, a managed service such as RDS or Cloud SQL), through PostgreSQL's own client tools (`psql`, `pg_isready`): a machine that runs Vigil but not PostgreSQL needs only the client package. It logs in as a read-only role, never a superuser.

1. Create the role once, as a database administrator:

   ```sql
   CREATE ROLE vigil_monitor LOGIN PASSWORD '...' IN ROLE pg_monitor;
   ```

2. Give Vigil its password: `vigil secret set POSTGRES_MONITOR_PASSWORD`, as the account Vigil runs as (`sudo -u vigil vigil secret set ...` on Linux; an elevated prompt on Windows). The job reads it with a `secret:` reference when it runs; it is never in the configuration.
3. `vigil pack enable postgres`. It says what is still missing, such as the secret, and the settings the jobs use: they connect to `localhost:5432`, database `postgres`; for anything else, edit their `env` lines in `vigil.config`. `vigil pack list` says the same later.

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `postgres_status` | Up, connections and the limit, the longest query and transaction, commits, rollbacks, deadlocks, cache hits | Yes | Yes | Yes |
| `postgres_size` | Each database's size | Yes | Yes | Yes |
| `postgres_activity` | Sessions active, idle and idle in a transaction; those waiting on a lock and those blocked by another; the longest lock wait and the longest idle transaction | Yes | Yes | No |
| `postgres_replication` | On a primary: replicas streaming, each one's lag in bytes and seconds, unused replication slots and the WAL each slot keeps. On a replica: whether it receives, and how far its replay is behind | Yes | Yes | No |
| `postgres_wraparound` | Each database's transaction ID and multixact age, as a count and as a percent of the limit where PostgreSQL stops accepting writes; the oldest transaction anything still needs | Yes | Yes | No |
| `postgres_vacuum` | Each database's dead rows and the tables past the autovacuum threshold; autovacuum workers running and the limit | Yes | Yes | No |
| `postgres_io` | Checkpoints on schedule and forced, temporary files and their bytes, WAL written (running totals) | Yes | Yes | No |

The jobs from `postgres_activity` on need PostgreSQL 14 or later. Each script's header says what its metrics mean and how to read them.

A server that does not answer reports `postgres.up` 0, and the run succeeds: that is a reading. The other jobs then print nothing and succeed, since `postgres_status` has said it. A refused login fails the run, and its log says why.

**Several servers:** `vigil pack enable` writes one copy of the jobs. For another server, copy a job's section in `vigil.config` under a new name (`[job.postgres_status_db2]`) and change its `env` lines; each copy reports with its own `job` tag.

**Tested** on 2026-11-19 on the Fedora 44 test machine, against **PostgreSQL 14.25 and 18.1**, each a primary with a streaming replica (`compose.replication.yaml`), by `tests/integration/backends/scripts/run-replication.sh`: `service-packs.sh` through Vigil, **58 passed, 0 failed** on each, then the replica stopped and started. The full console output, with the versions of everything it ran: [PostgreSQL 18](../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-postgres-18-replication/console.txt), [PostgreSQL 14](../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-postgres-14-replication/console.txt). From PostgreSQL 18:

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

### mysql

A MySQL or MariaDB server, on this machine or any it can reach (a container, another server, a managed service such as RDS or Cloud SQL), through the `mysql` client (MySQL's, or MariaDB's `mariadb`): a machine that runs Vigil but not the database needs only the client package. It logs in as a read-only user, never root. Linux and macOS.

1. Create the user once, as a database administrator:

   ```sql
   CREATE USER 'vigil_monitor'@'%' IDENTIFIED BY '...';
   GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'vigil_monitor'@'%';
   -- MariaDB only: reading replication status is a right of its own there
   GRANT REPLICA MONITOR ON *.* TO 'vigil_monitor'@'%';
   ```

   Neither grant lets it read or change any table's data.
2. Give Vigil its password: `vigil secret set MYSQL_MONITOR_PASSWORD`, as the account Vigil runs as. The jobs pass it to the client in `MYSQL_PWD`, never on a command line.
3. `vigil pack enable mysql`. The jobs connect to `127.0.0.1:3306` as `vigil_monitor`; for anything else, edit their `env` lines (`MYSQL_HOST`, `MYSQL_TCP_PORT`, `MYSQL_USER`) in `vigil.config`.

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `mysql_status` | Up, connections and the limit, statements running and the longest, statements, slow ones, failed connection attempts, temporary tables spilled to disk | Yes | Yes | No |
| `mysql_activity` | The longest open transaction, transactions open on an idle connection and the longest, transactions waiting on a row lock and the longest wait | Yes | Yes | No |
| `mysql_replication` | On a replica: whether each replication thread runs, and the lag, per channel. On a source: replicas connected | Yes | Yes | No |
| `mysql_innodb` | Buffer pool hit rate and use, undo history waiting for purge, row lock waits and deadlocks | Yes | Yes | No |
| `mysql_size` | Each database's InnoDB tables on disk | Yes | Yes | No |

Each script reads MySQL's and MariaDB's own names for the same thing, so a dashboard works for both. It needs nothing from `performance_schema`, which MariaDB leaves off by default. Each script's header says what its metrics mean and how to read them. Two things the servers do that are worth knowing:

- On MariaDB `buffer_pool_hit_pct` can be missing, on a fresh server most of all: MariaDB counts read requests only in part, and while it shows more reads from disk than requests, no hit rate can be worked out.
- A source counts a replica whose machine stopped without closing the connection until that connection times out, so alert on each replica's own `io_running` and `mysql.up` too.

A server that does not answer reports `mysql.up` 0, and the run succeeds: that is a reading. The other jobs then print nothing and succeed. A refused login fails the run, and its log says why. For several servers, copy a job's section under a new name, as for postgres.

**Tested** on 2026-11-19 on the Fedora 44 test machine, against **MySQL 8.4.13 and MariaDB 11.4.13**, each a source with a replica replicating by GTID (`compose.mysql.yaml`), each with its own client, by `tests/integration/backends/scripts/run-replication.sh`: `service-packs.sh` through Vigil, **39 passed, 0 failed** on each, then the replica's applying thread stopped and started, and the replica itself. The full console output: [MySQL 8.4](../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-mysql-replication/console.txt), [MariaDB 11.4](../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-mariadb-replication/console.txt). In CI, the same test runs against MySQL 8.4 and MariaDB 11.4 on every change to the packs, without a replica. From MariaDB 11.4:

A transaction holds a row, idle on its connection, and a second statement waits for it:

```text
  PASS  mysql: activity runs
        metric longest_transaction_seconds 10
        metric idle_in_transaction 1
        metric longest_idle_in_transaction_seconds 9
        metric waiting 1
        metric longest_wait_seconds 8
```

The replica's applying thread stops, then the replica itself, and it comes back:

```text
# The replica's applying thread stops.
$ MYSQL_TCP_PORT=13317 bash packs/mysql/replication.sh
metric is_replica 1
metric replicas 0
metric io_running 1 channel=default
metric sql_running 0 channel=default

# The replica stops.
$ MYSQL_TCP_PORT=13316 bash packs/mysql/replication.sh
metric is_replica 0
metric replicas 1
$ MYSQL_TCP_PORT=13317 bash packs/mysql/status.sh
metric up 0

# The replica starts again, and catches up.
$ MYSQL_TCP_PORT=13317 bash packs/mysql/replication.sh
metric is_replica 1
metric replicas 0
metric io_running 1 channel=default
metric sql_running 1 channel=default
metric lag_seconds 0 channel=default
```

The source still counts the stopped replica (`replicas 1`) until their connection times out; the replica's own `mysql.up` says at once that it is gone.

### nginx

An nginx server on this machine, from its `stub_status` page, which you turn on once, reachable from this machine only:

```nginx
location = /nginx_status { stub_status; allow 127.0.0.1; deny all; }
```

Then `vigil pack enable nginx`, which reminds you of the page. The job reads `http://127.0.0.1/nginx_status`; for another address, edit its `env` line.

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `nginx_status` | Up, connections (active, reading, writing, waiting), accepted, handled and dropped connections, requests | Yes | Yes | No |

| Metric | Healthy | Watch | Act |
| --- | --- | --- | --- |
| `postgres.up`, `nginx.up` | 1 | | 0 |
| `postgres.connections_pct` | Below 70 | 70 to 90 | Above 90: new connections will soon be refused |
| `postgres.longest_transaction_seconds` | Seconds | Minutes: it holds back vacuum | Growing, on a busy database |
| `postgres.cache_hit_pct` | Above 99, on a busy database | Falling | Well below your usual |
| `postgres.deadlocks_count` (as a rate) | 0 | Any | Rising |
| `nginx.dropped_count` (as a rate) | 0 | Any | Rising: nginx is turning connections away |

## Writing a pack

`tools/new-pack.sh <name>` starts one, and `tools/check-pack.sh --run <name>` says what is left to fix. [CONTRIBUTING.md](../CONTRIBUTING.md#your-first-pack) has the steps. In short:

- Use only what ships with the operating system: bash 3.2 and PowerShell 5.1.
- Print metrics as `metric <name> <value> [key=value ...]`, and use plain ASCII.
- Exit 0 when the script worked. A high reading is not a failure.
- Read data; never change the machine.
- Start with the same header as the other scripts: what it does, its metrics, an example of its output, what healthy and unhealthy look like, what it needs, its exit codes and the disclaimer.

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../LICENSE) gives the full terms, and it takes precedence over this summary.
