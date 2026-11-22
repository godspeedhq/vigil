# Vigil packs

A pack is a set of scripts and jobs that gives a machine useful metrics for one thing it runs. Vigil comes with the base pack, which `vigil init` turns on; the others are installed from the pack repository: `vigil pack search`, `vigil pack install <name>`, then `vigil pack enable <name>`. [SPECIFICATION.md](../SPECIFICATION.md), section 18.10, has the full format.

## What's here

```text
packs/<name>/pack.config    the pack's version, jobs and metrics
packs/<name>/linux/         scripts for Linux
packs/<name>/macos/         scripts for macOS
packs/<name>/windows/       scripts for Windows
```

Packs are released on their own, as packs releases tagged `packs-<date>`: each new pack version gets an archive per platform, listed in an index signed with the release key. A machine holds only the packs installed on it, and only its own platform's scripts.

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

**What it needs:**

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| Client tools on the Vigil machine | `psql` and `pg_isready`: Debian and Ubuntu `postgresql-client`, Fedora and RHEL `postgresql` | `psql` and `pg_isready`: Homebrew's `libpq` | `psql.exe` and `pg_isready.exe`: PostgreSQL's installer (its command line tools) or its zip of binaries. Found on the `PATH`, or under `Program Files\PostgreSQL\<version>\bin` |
| The server | PostgreSQL 14 or later for `postgres_activity` to `postgres_io`; any supported version for `postgres_status` and `postgres_size` | | |
| A role | `vigil_monitor`, read-only, in `pg_monitor` (step 1); `pg_hba.conf` must let it in from the Vigil machine | | |
| A secret | `POSTGRES_MONITOR_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |
| Where to connect | Each job's `env` lines: `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` | | |

The client must be on the `PATH` the Vigil service runs with, as well as yours. A package manager's `/usr/bin` is; Homebrew's `libpq` is not, as it is keg-only. Give such jobs an `env` line for it, such as `env = PATH=/opt/homebrew/opt/libpq/bin:/usr/bin:/bin`.

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

**Tested** on 2026-11-19 on the Fedora 44 test machine, against **PostgreSQL 14.25 and 18.1**, each a primary with a streaming replica (`compose.replication.yaml`), by `tests/integration/backends/scripts/run-replication.sh`: `service-packs.sh` through Vigil, **58 passed, 0 failed** on each, then the replica stopped and started. The full console output, with the versions of everything it ran: [PostgreSQL 18](../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-postgres-18-replication/console.txt), [PostgreSQL 14](../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-postgres-14-replication/console.txt). **On Windows**, every job on Windows PowerShell 5.1 and PowerShell 7, against PostgreSQL 18.1 with a replica on another machine, then through Vigil itself on Windows: [the console output](../tests/integration/backends/reports/runs/2026-11-19/windows/pack-postgres-windows/console.txt). From PostgreSQL 18, on Linux:

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

A MySQL or MariaDB server, on this machine or any it can reach (a container, another server, a managed service such as RDS or Cloud SQL), through the `mysql` client (MySQL's, or MariaDB's `mariadb`): a machine that runs Vigil but not the database needs only the client package. It logs in as a read-only user, never root. Linux, macOS and Windows.

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

**What it needs:**

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| A client on the Vigil machine | `mysql` or `mariadb`: Debian `default-mysql-client` or `mariadb-client`, Ubuntu `mysql-client`, Fedora and RHEL `mysql` or `mariadb` | Homebrew's `mysql-client` or `mariadb` | `mysql.exe` or `mariadb.exe`, from MySQL's or MariaDB's installer or zip. Found on the `PATH`, or under `Program Files\MySQL\MySQL Server <version>\bin` or `Program Files\MariaDB <version>\bin` |
| The server | Tested with MySQL 8.4 and MariaDB 11.4; meant for MySQL 8.0 and MariaDB 10.5 on | | |
| A user | `vigil_monitor`, with `PROCESS` and `REPLICATION CLIENT`, and on MariaDB `REPLICA MONITOR` (step 1); allowed in from the Vigil machine | | |
| A secret | `MYSQL_MONITOR_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |
| Where to connect | Each job's `env` lines: `MYSQL_HOST`, `MYSQL_TCP_PORT`, `MYSQL_USER` | | |

The client must be on the `PATH` the Vigil service runs with, as well as yours. A package manager's `/usr/bin` is; Homebrew's `mysql-client` is not, as it is keg-only. Give such jobs an `env` line for it, such as `env = PATH=/opt/homebrew/opt/mysql-client/bin:/usr/bin:/bin`.

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `mysql_status` | Up, connections and the limit, statements running and the longest, statements, slow ones, failed connection attempts, temporary tables spilled to disk | Yes | Yes | Yes |
| `mysql_activity` | The longest open transaction, transactions open on an idle connection and the longest, transactions waiting on a row lock and the longest wait | Yes | Yes | Yes |
| `mysql_replication` | On a replica: whether each replication thread runs, and the lag, per channel. On a source: replicas connected | Yes | Yes | Yes |
| `mysql_innodb` | Buffer pool hit rate and use, undo history waiting for purge, row lock waits and deadlocks | Yes | Yes | Yes |
| `mysql_size` | Each database's InnoDB tables on disk | Yes | Yes | Yes |

Each script reads MySQL's and MariaDB's own names for the same thing, so a dashboard works for both. It needs nothing from `performance_schema`, which MariaDB leaves off by default. Each script's header says what its metrics mean and how to read them. Two things the servers do that are worth knowing:

- On MariaDB `buffer_pool_hit_pct` can be missing, on a fresh server most of all: MariaDB counts read requests only in part, and while it shows more reads from disk than requests, no hit rate can be worked out.
- A source counts a replica whose machine stopped without closing the connection until that connection times out, so alert on each replica's own `io_running` and `mysql.up` too.

A server that does not answer reports `mysql.up` 0, and the run succeeds: that is a reading. The other jobs then print nothing and succeed. A refused login fails the run, and its log says why. For several servers, copy a job's section under a new name, as for postgres.

**Tested** on 2026-11-19 on the Fedora 44 test machine, against **MySQL 8.4.13 and MariaDB 11.4.13**, each a source with a replica replicating by GTID (`compose.mysql.yaml`), each with its own client, by `tests/integration/backends/scripts/run-replication.sh`: `service-packs.sh` through Vigil, **39 passed, 0 failed** on each, then the replica's applying thread stopped and started, and the replica itself. The full console output: [MySQL 8.4](../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-mysql-replication/console.txt), [MariaDB 11.4](../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-mariadb-replication/console.txt). **On Windows**, every job on Windows PowerShell 5.1 and PowerShell 7, with each vendor's Windows client, against a source and replica on another machine, then through Vigil itself on Windows: [MySQL 8.4](../tests/integration/backends/reports/runs/2026-11-19/windows/pack-mysql-windows/console.txt), [MariaDB 11.4](../tests/integration/backends/reports/runs/2026-11-19/windows/pack-mariadb-windows/console.txt). In CI, the same test runs against MySQL 8.4 and MariaDB 11.4, without a replica, on every change to Vigil itself. From MariaDB 11.4:

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

### redis

A Redis or Valkey server, on this machine or any it can reach (a container, another server, a managed service), from its `INFO`, as a user that may run `INFO` and `PING` and nothing else. On Linux and macOS through `redis-cli` or `valkey-cli`, whichever is there; on Windows the scripts speak the server's protocol themselves, with what ships with Windows, so there is nothing to install. Linux, macOS and Windows.

1. Create the user once, as an administrator (Redis 6 or later, or Valkey):

   ```text
   ACL SETUSER vigil_monitor on >... -@all +info +ping
   ```

   Then `ACL SAVE` if the server keeps its users in an ACL file, or `CONFIG REWRITE` if it keeps them in its configuration, so the user outlives a restart. It can read no key and change nothing.
2. Give Vigil its password: `vigil secret set REDIS_MONITOR_PASSWORD`, as the account Vigil runs as. The jobs pass it in `REDISCLI_AUTH`, which `redis-cli` and `valkey-cli` read for themselves: never on a command line.
3. `vigil pack enable redis`. The jobs connect to `127.0.0.1:6379` as `vigil_monitor`; for anything else, edit their `env` lines (`REDIS_HOST`, `REDIS_PORT`, `REDIS_USER`) in `vigil.config`.

A server with a password but no users of its own (`requirepass` only): set `REDIS_USER=default`. A server with no password at all: delete the jobs' `secret` lines, and they read it as its default user.

**TLS:** give each job `env = REDIS_TLS=1`, and `env = REDIS_CACERT=<a CA file>` unless the server's certificate is from a CA the machine already trusts. On Linux and macOS, `REDIS_CERT` and `REDIS_KEY` give a client certificate, for a server that asks for one. A certificate that cannot be trusted fails the run and says so. Know this: `redis-cli` and `valkey-cli` check that the certificate is from a trusted CA, but not that it names the server (we tried Redis 6.2 to 8.10 and Valkey 7.2 to 9.2), so give `REDIS_CACERT` a CA that signs only your own servers. On Windows, .NET checks the name too.

**What it needs:**

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| A client on the Vigil machine | `redis-cli` or `valkey-cli`: Debian and Ubuntu `redis-tools` or `valkey-tools`, Fedora `valkey`, RHEL 9 and its rebuilds `redis` or `valkey` | Homebrew's `redis` or `valkey` | None |
| The server | Redis 6.2 or later, or Valkey; tested with Redis 6.2, 7.4 and 8.10 and Valkey 7.2, 8.1 and 9.2 | | |
| A user | `vigil_monitor`, allowed `INFO` and `PING` only (step 1) | | |
| A secret | `REDIS_MONITOR_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |
| Where to connect | Each job's `env` lines: `REDIS_HOST`, `REDIS_PORT`, `REDIS_USER`; for TLS `REDIS_TLS`, `REDIS_CACERT` | | |

The client must be on the `PATH` the Vigil service runs with. Only `redis-cli` from Redis 7.4 and `valkey-cli` from Valkey 8.1 have a connect timeout: with an older client (Ubuntu 24.04's is 7.0), a server that drops packets rather than refusing the connection keeps the run waiting until the job's `max_runtime`, and the run times out instead of reading `up 0`.

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `redis_status` | Up, what it is (Redis or Valkey, its version, standalone, cluster or Sentinel), clients and the limit, blocked clients, refused connections, commands, lookups that hit and missed, evicted and expired keys, error replies | Yes | Yes | Yes |
| `redis_memory` | Memory used against `maxmemory` and the policy at the limit, memory from the system, the peak, fragmentation | Yes | Yes | Yes |
| `redis_replication` | On a primary: replicas connected, and each one's state and lag in bytes and seconds. On a replica: whether its link is up, when it last heard from the primary, and whether a full copy is under way | Yes | Yes | Yes |
| `redis_persistence` | Whether the last snapshot and append-only file writes worked, the snapshot's age and the changes since, how long the last fork stopped the server | Yes | Yes | Yes |
| `redis_keyspace` | Keys in each database, and those with a time to live, from the server's own counts: it never reads a key | Yes | Yes | Yes |

Each script's header says what its metrics mean and how to read them. Worth knowing:

- `hit_pct` is since the server started, so it moves slowly: graph `hits_count` and `misses_count` as rates to see the hit rate now.
- `fragmentation_ratio` is high on a server with little data, with no harm: judge it once there is data. Below 1, the system is swapping the server out.
- A cluster node is read as a server of its own. On a Sentinel, `redis_status` reports it (`mode=sentinel`) and the other jobs print nothing.

A server that does not answer reports `redis.up` 0, and the run succeeds: that is a reading. The other jobs then print nothing and succeed. A refused login, a user that may not run `INFO`, and a TLS handshake that fails, fail the run, and its log says why. A wrong password fails even where the server's default user is open and would answer. For several servers, copy a job's section under a new name, as for postgres.

**Tested** on 2026-11-20 on the Fedora 44 test machine, against **Redis 6.2.24, 7.4.12 and 8.10.3 and Valkey 7.2.16, 8.1.12 and 9.2.0**, each a primary with a replica and a TLS server beside it (`compose.redis.yaml`), each with its own client, by `tests/integration/backends/scripts/run-replication.sh redis <image>`: `service-packs.sh` through Vigil, **71 passed, 0 failed** on each, then the replica stopped and started. The full console output: [Redis 6.2](../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-redis-6-replication/console.txt), [Redis 7.4](../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-redis-7-replication/console.txt), [Redis 8.10](../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-redis-8-replication/console.txt), [Valkey 7.2](../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-valkey-7-replication/console.txt), [Valkey 8.1](../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-valkey-8-replication/console.txt), [Valkey 9.2](../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-valkey-9-replication/console.txt). **On Windows**, every job on Windows PowerShell 5.1 and PowerShell 7 against the same servers on the Fedora machine, then `Service-Packs.ps1` through Vigil itself on each: [Valkey 9.2](../tests/integration/backends/reports/runs/2026-11-20/windows/pack-valkey-windows/console.txt), [Redis 8.10](../tests/integration/backends/reports/runs/2026-11-20/windows/pack-redis-windows/console.txt). In CI, the same test runs against Valkey 9.2 and Redis 8.10, with the runner's own `redis-cli` (8.0.5 on 2026-11-20), on every change to Vigil itself. From Valkey 9.2, on Linux:

Twice its `maxmemory` written to a primary that evicts (`allkeys-lru`), with a client blocked on a list no one writes:

```text
  PASS  redis: status runs
        metric up 1
        metric info 1 server=valkey version=9.2.0 mode=standalone
        metric clients 2
        metric blocked_clients 1
        metric evicted_keys_count 15825
  PASS  redis: memory runs
        metric used_bytes 33560408
        metric max_bytes 33554432 policy=allkeys-lru
        metric used_pct 100
        metric fragmentation_ratio 1.72
```

Replication, from both sides, as the replica stops and starts again:

```text
# Both sides, streaming.
$ REDIS_PORT=16379 bash packs/redis/replication.sh
metric is_replica 0
metric replicas 1
metric online 1 replica=172.20.0.4_6379
metric lag_bytes 0 replica=172.20.0.4_6379
metric lag_seconds 1 replica=172.20.0.4_6379
$ REDIS_PORT=16380 bash packs/redis/replication.sh
metric is_replica 1
metric replicas 0
metric link_up 1
metric last_io_seconds 7
metric sync_in_progress 0

# The replica stops.
$ REDIS_PORT=16379 bash packs/redis/replication.sh
metric is_replica 0
metric replicas 0
$ REDIS_PORT=16380 bash packs/redis/status.sh
metric up 0

# The replica starts again, and catches up.
$ REDIS_PORT=16379 bash packs/redis/replication.sh
metric is_replica 0
metric replicas 1
metric online 1 replica=172.20.0.4_6379
metric lag_bytes 0 replica=172.20.0.4_6379
metric lag_seconds 1 replica=172.20.0.4_6379
```

**On macOS**, on the Intel Mac test machine under its bash 3.2 and awk, with clients built from their source: every job directly, then `service-packs.sh` through Vigil, **61 passed, 0 failed** on each, against a primary and a replica on the Fedora machine: `valkey-cli` 9.2.0 against [Valkey 9.2](../tests/integration/backends/reports/runs/2026-11-20/macos/pack-valkey-macos/console.txt), and `redis-cli` 7.2.17, which has no connect timeout, against [Redis 8.10](../tests/integration/backends/reports/runs/2026-11-20/macos/pack-redis-macos/console.txt). Those clients were built without TLS, so TLS was tested on Linux and Windows. Before that, the macOS scripts ran against replies captured from real servers and replayed by a stand-in client, and gave the same output, line for line, as the Linux scripts: [that run](../tests/integration/backends/reports/runs/2026-11-20/macos/pack-redis-macos-replay/console.txt).

### mssql

A Microsoft SQL Server, 2019, 2022 or 2025, on Linux or Windows, on this machine or any it can reach, from what it says about itself: its counters and its dynamic management views, read by one short query per job, as a login that can change nothing and read no table. Never a query's text, nor a host, program or login name. On Linux and macOS through `sqlcmd`, Microsoft's or the Go one; on Windows through .NET's own SQL Server client, so there is nothing to install. Linux, macOS and Windows.

1. Create the login once, as an administrator. On 2022 and 2025:

   ```sql
   CREATE LOGIN vigil_monitor WITH PASSWORD = '...';
   GRANT VIEW SERVER PERFORMANCE STATE, VIEW SERVER SECURITY STATE, VIEW ANY DATABASE, CONNECT ANY DATABASE TO vigil_monitor;
   ```

   On 2019, `GRANT VIEW SERVER STATE, VIEW ANY DATABASE, CONNECT ANY DATABASE TO vigil_monitor;`. `CONNECT ANY DATABASE` lets it open each database for its files and Query Store state, and read nothing in it. For `mssql_agent`, in `msdb`:

   ```sql
   USE msdb;
   CREATE USER vigil_monitor FOR LOGIN vigil_monitor;
   GRANT SELECT ON dbo.sysjobs TO vigil_monitor;
   GRANT SELECT ON dbo.sysjobhistory TO vigil_monitor;
   GRANT SELECT ON dbo.sysjobactivity TO vigil_monitor;
   GRANT SELECT ON dbo.syssessions TO vigil_monitor;
   ```

   `SQLAgentReaderRole` does not do: it works through Agent's procedures, and gives no `SELECT` on these. Without them, `mssql_agent` reports `readable 0` and nothing else. For an availability group's name in `mssql_replication`, `GRANT VIEW DEFINITION ON AVAILABILITY GROUP::[<name>] TO vigil_monitor`; without it, the group is tagged by its id. Logins are not copied between replicas: create it on each.
2. Give Vigil its password: `vigil secret set MSSQL_MONITOR_PASSWORD`, as the account Vigil runs as. The jobs pass it in `SQLCMDPASSWORD`, which both `sqlcmd`s read for themselves: never on a command line.
3. `vigil pack enable mssql`. The jobs connect to `localhost:1433` as `vigil_monitor`; for anything else, edit their `env` lines (`MSSQL_HOST`, `MSSQL_PORT`, `MSSQL_USER`) in `vigil.config`.

**Always encrypted, the certificate checked.** There is no setting that trusts a certificate unchecked. On Linux and macOS, the server's certificate must be from a CA the machine trusts, or from `MSSQL_CACERT`, a CA file, and must name `MSSQL_HOST`: Microsoft's `sqlcmd` matches names, not IP addresses, so connect by the name on the certificate, or give that name in `MSSQL_CERT_NAME`. On macOS the Go `sqlcmd` ignores `MSSQL_CACERT` and trusts the System keychain only: put your CA there (`sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <ca file>`), and the run says so when it cannot. On Windows, put your CA, or the server's own certificate, in the machine's Trusted Root store, and connect by a name it holds. A server still on SQL Server's own self-signed certificate is refused: give it a certificate of your own (`mssql-conf set network.tlscert`, or SQL Server Configuration Manager), which you should anyway. On Windows, `MSSQL_AUTH=windows` logs in as the account Vigil runs as, with no password: delete the jobs' `secret` lines.

**What it needs:**

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| A client on the Vigil machine | `sqlcmd`: Microsoft's `mssql-tools18` (it looks in `/opt/mssql-tools18/bin` too), or the Go one (`go-sqlcmd`) | The Go `sqlcmd`, from its [releases](https://github.com/microsoft/go-sqlcmd/releases) | None |
| The server | SQL Server 2019, 2022 or 2025, on Linux or Windows | | |
| A login | `vigil_monitor`, with what step 1 grants | | |
| A secret | `MSSQL_MONITOR_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |
| Where to connect | Each job's `env` lines: `MSSQL_HOST`, `MSSQL_PORT`, `MSSQL_USER`; `MSSQL_CACERT`, `MSSQL_CERT_NAME` | | |

| Job | Every | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- | --- |
| `mssql_status` | 1m | Up, what it is (release, build, CU, edition, Linux or Windows), uptime, CPUs, connections and the limit, a failover cluster and its node, Always On enabled, SQL Agent running | Yes | Yes | Yes |
| `mssql_performance` | 1m | Its counters: requests, transactions, compilations and recompilations, logins, errors, page life expectancy and buffer cache hits, pages read and written, lock waits and timeouts, deadlocks, page splits, full scans, memory grants pending, missing indexes | Yes | Yes | Yes |
| `mssql_activity` | 1m | Sessions by state, requests running and blocked, head blockers, the longest request and wait and what it waits on, the oldest open transaction, sessions asleep with a transaction open, the longest snapshot transaction | Yes | Yes | Yes |
| `mssql_cpu` | 1m | CPU used by SQL Server (and on Windows by the rest of the machine), tasks waiting for a CPU or a thread, worker threads against the most, pending I/O | Yes | Yes | Yes |
| `mssql_replication` | 1m | Always On: each replica's role, connection and health; each database's synchronization, send and redo queues and rates, and lag. Nothing with no availability group | Yes | Yes | Yes |
| `mssql_waits` | 5m | Where its time goes waiting, by kind (CPU, disk reads, log writes, locks, latches, memory, network, parallelism, replication), and the ten costliest wait types | Yes | Yes | Yes |
| `mssql_io` | 5m | Each database file's reads, writes, bytes and stall time, for latency, and its size (the 120 that waited longest) | Yes | Yes | Yes |
| `mssql_memory` | 5m | Memory aimed for and held, the process's and the machine's, the buffer pool, memory grants, the plan cache and its single-use plans, In-Memory OLTP, the biggest clerks, memory-low signals | Yes | Yes | Yes |
| `mssql_tempdb` | 5m | tempdb's size and free space, row versions, temporary tables, sorts and hashes, its log | Yes | Yes | Yes |
| `mssql_connections` | 5m | Connections encrypted or not, by how they log in (SQL, Kerberos, NTLM), sessions in each database: counts only | Yes | Yes | Yes |
| `mssql_databases` | 15m | Each database's state, recovery model, data and log size and use, what keeps its log from being reused, open transactions, compatibility level, Query Store state (the 75 biggest) | Yes | Yes | Yes |
| `mssql_health` | 15m | Days since each database's last good DBCC CHECKDB, virtual log files, files growing by percent or near their maximum, free space on each volume, Express's 10 GB limit, encryption (TDE), damaged pages | Yes | Yes | Yes |
| `mssql_config` | 15m | Settings at risk: max server memory left at its default, MAXDOP, cost threshold, xp_cmdshell, CLR, OLE automation, `sa` enabled, sysadmin logins, instant file initialization, locked pages | Yes | Yes | Yes |
| `mssql_backups` | 15m | Since each database's last full, differential and log backup; databases with none in 400 days | Yes | Yes | Yes |
| `mssql_agent` | 15m | SQL Agent's jobs: failed in the last 24 hours (each, by name), running now, the longest running | Yes | Yes | Yes |

Each script's header says what its metrics mean and how to read them. Worth knowing:

- The `_count` metrics are running totals since SQL Server started: graph them as rates. A file's read latency is the rate of `read_stall_ms_count` over that of `reads_count`.
- The jobs agree to the line on every platform: each runs the same query, which prints the finished metric lines.
- A tag keeps letters, digits, `_`, `.` and `-`; anything else in a database, file or job name becomes `_`.
- Every job waits at most 5 seconds for a lock, gives way in a deadlock, and reads without taking locks where SQL Server allows: it never holds up the server's own work.
- Lists are capped (75 databases, 120 files, 10 wait types, 50 jobs) so a big server stays under the 1000 lines Vigil takes from a run; `databases_not_shown` and `files_not_shown` count the rest.

A server that does not answer reports `mssql.up` 0, and the run succeeds: that is a reading. The other jobs then print nothing and succeed. A refused login, a certificate that cannot be trusted or names another host, and a failed query fail the run, and its log says why.

**Tested** on 2026-11-20 on the Fedora 44 test machine, against **SQL Server 2019 (CU32), 2022 (CU28) and 2025 (CU11)**, Developer edition in Docker, TLS only with a certificate from a test CA (`compose.mssql.yaml`), by `tests/integration/backends/scripts/run-mssql.sh <image>`: `service-packs.sh` through Vigil with the Go `sqlcmd` 1.10.0, **79 passed, 0 failed** on 2019 and on 2025, each the primary of a read-scale availability group whose secondary was then stopped and started, and **71 passed, 0 failed** on 2022 alone. On 2022 CU28 the secondary would not join an availability group in Docker on that machine (the join timed out while the secondary held a CPU), where 2019 and 2025, set up the same way, did; the replication job asks the same of all three. Every job, against 2022, printed the same lines with Microsoft's `sqlcmd` 18.7 as with the Go one. The full console output: [2019](../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-mssql-2019-replication/console.txt), [2022](../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-mssql-2022/console.txt), [2025](../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-mssql-2025-replication/console.txt). **On Windows**, every job on Windows PowerShell 5.1 and PowerShell 7 against SQL Server 2022 on the Fedora machine, printing the same lines as the Linux scripts, then `Service-Packs.ps1` through Vigil itself, **53 passed, 0 failed** on each: [the console output](../tests/integration/backends/reports/runs/2026-11-20/windows/pack-mssql-windows/console.txt). **On macOS**, on the Intel Mac test machine under its bash 3.2, with the Go `sqlcmd` 1.10.0 and the test CA in the System keychain: every job directly, then `service-packs.sh` through Vigil, **69 passed, 0 failed**, against SQL Server 2022 on the Fedora machine: [the console output](../tests/integration/backends/reports/runs/2026-11-20/macos/pack-mssql-macos/console.txt). In CI, the same test runs against SQL Server 2022, TLS only, on every change to Vigil itself. Lines from SQL Server 2025, with one session asleep in its open transaction and another blocked behind it:

```text
metric sessions 4 state=sleeping
metric requests 1
metric requests_blocked 1
metric head_blockers 1
metric longest_request_seconds 9
metric longest_wait_seconds 9.38 type=LCK_M_X
metric oldest_transaction_seconds 12
metric idle_in_transaction 1
metric idle_in_transaction_seconds 12
```

And from its availability group, as the primary sees it:

```text
metric primary 1 group=ag1 replica=mssql-primary
metric connected 1 group=ag1 replica=mssql-secondary
metric health 2 group=ag1 replica=mssql-secondary
metric sync_state 2 group=ag1 replica=mssql-secondary database=vigil_it
metric send_queue_bytes 61440 group=ag1 replica=mssql-secondary database=vigil_it
metric redo_queue_bytes 0 group=ag1 replica=mssql-secondary database=vigil_it
metric lag_seconds 0 group=ag1 replica=mssql-secondary database=vigil_it
```

### kafka

An Apache Kafka cluster, from 2.8 to 4.x, in KRaft mode or on ZooKeeper, on this machine or any it can reach. Through Kafka's admin API, the pack asks the cluster what any Kafka admin would, as a user that may only describe; through each broker's JMX, with a password and TLS, it reads the broker's own figures. It reports Kafka's, never the broker's JVM: heap, garbage collection, threads, CPU and open files are the [jvm pack](#jvm)'s. Linux, macOS and Windows. Its design: [`tools/kafka/DESIGN.md`](../tools/kafka/DESIGN.md).

**Two jars, both ours, and your Kafka library.** The pack runs Java, 11 or later, a JDK or a JRE:

- `_probe.jar`, the generic probe ([`tools/probe/DESIGN.md`](../tools/probe/DESIGN.md)), the same file every application pack carries, runs the four jobs that only read the brokers' JMX, from the pack's `_probe.tables`. They need no Kafka library.
- `_client.jar`, the pack's own, asks the admin API for the other fourteen. It needs Kafka's library, which is yours, not the pack's: `KAFKA_HOME`, a Kafka download (its `libs/`), or `KAFKA_LIBS`, a folder of its jars. Any `kafka-clients` from 3.x or 4.x; the newest Kafka download is best, whatever the cluster runs, since a newer library speaks to older brokers.
- Both are built when the pack is released, from the sources beside them (`_probe.java`, `_client.java`), the same bytes from the same source and `javac`, and each script checks the jars it runs against the SHA-256 it carries before running them, as the [jvm pack](#jvm) does. A copy of the pack straight from the repository has no jars, and its scripts say so.

1. Create the user once, as an administrator. With SCRAM:

   ```sh
   kafka-configs --bootstrap-server <broker> --alter --entity-type users --entity-name vigil_monitor \
     --add-config 'SCRAM-SHA-512=[password=...]'
   ```

   and give it only what it needs to describe the cluster, its topics, groups and transactions:

   ```sh
   kafka-acls --bootstrap-server <broker> --add --allow-principal User:vigil_monitor \
     --operation Describe --operation DescribeConfigs --cluster --topic '*'
   kafka-acls --bootstrap-server <broker> --add --allow-principal User:vigil_monitor \
     --operation Describe --group '*' --transactional-id '*'
   ```

   Not `Read`: that would let it read messages. Kafka hides from a user the topics it may not describe, so a user without these sees no topics at all, and the jobs say so in their log. Without an authorizer (no ACLs), any login will do.
2. Give Vigil its password: `vigil secret set KAFKA_MONITOR_PASSWORD`, as the account Vigil runs as. The client builds its configuration in memory: the password is never in a file or on a command line.
3. `vigil pack enable kafka`. The jobs connect to `localhost:9092` over `SASL_SSL` with SCRAM-SHA-512, as `vigil_monitor`. For anything else, edit their `env` lines in `vigil.config`: `KAFKA_BOOTSTRAP` (host:port, comma-separated), `KAFKA_SECURITY` (`PLAINTEXT`, `SSL`, `SASL_PLAINTEXT` or `SASL_SSL`), `KAFKA_SASL_MECHANISM` (`SCRAM-SHA-512`, `SCRAM-SHA-256` or `PLAIN`), `KAFKA_USER`, `KAFKA_CACERT` (a PEM file of the CAs that signed the brokers' certificates), `KAFKA_CERT` and `KAFKA_KEY` (a client certificate and its PKCS#8 key, for brokers that ask for one), `KAFKA_HOME` or `KAFKA_LIBS`. For Kerberos or OAuth, `KAFKA_CLIENT_CONFIG` names a client properties file of your own, whose settings come first.
4. For the brokers' own figures (`kafka_throughput`, `kafka_requests`, `kafka_controller`, `kafka_connections`, and the flushes and log cleaner of `kafka_logdirs`), give each broker's JMX in their `KAFKA_JMX` line: `jmxs=host:port` over TLS, `jmx=host:port` without, separated by `;`. With a JMX user (`KAFKA_JMX_USER`) and its password, add a secret line to those jobs, under their `env` lines, and give Vigil the password:

   ```ini
   secret = KAFKA_JMX_PASSWORD=secret:KAFKA_JMX_PASSWORD
   ```

   ```sh
   vigil secret set KAFKA_JMX_PASSWORD
   ```

   On the brokers, a JMX user that may only read is enough (`monitor readonly` in the access file): the jobs read attributes and run nothing. Kafka's start scripts take the JMX options from `KAFKA_JMX_OPTS` and the port from `JMX_PORT`, as the [jvm pack](#jvm) shows for any JVM: a password file, an access file, and TLS with `com.sun.management.jmxremote.ssl=true` and `registry.ssl=true`.

**The brokers' JVMs: the jvm pack.** Heap, garbage collection, threads, CPU and open files against the limit are any JVM's, and the [jvm pack](#jvm) reports them, so this one does not. Install it beside this one, and name each broker in `JVM_TARGETS` as Kafka names it, so a broker's Kafka metrics and its JVM's line up on one dashboard:

```ini
env = JVM_TARGETS=kafka-1: jmxs=broker1:9999; kafka-2: jmxs=broker2:9999; kafka-3: jmxs=broker3:9999
```

Open files near the limit stop a broker taking connections and writing segments: watch `jvm_process` `open_files` against `open_files_max` for each.

**The certificate is always checked**, against `KAFKA_CACERT` or Java's own CAs, and against the broker's name: connect by the name on its certificate. There is no setting that trusts a certificate unchecked. `kafka_tls` reads each broker's certificate whether it is trusted or not, to say how long it has, and reports `trusted 0` for one that is not.

**What it needs:**

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | Java 11 or later, a JDK or a JRE (`JAVA_HOME` or `java` on the PATH); for all but the four JMX jobs, Kafka's library (`KAFKA_HOME` or `KAFKA_LIBS`) | The same | The same |
| The cluster | Apache Kafka 2.8 to 4.x, KRaft or ZooKeeper | | |
| A user | `vigil_monitor`, with the ACLs step 1 grants | | |
| A secret | `KAFKA_MONITOR_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |
| For the JMX jobs | Each broker's JMX in `KAFKA_JMX`, and with a password, `KAFKA_JMX_PASSWORD` (step 4) | | |

| Job | Every | From | Reports |
| --- | --- | --- | --- |
| `kafka_status` | 1m | admin | Up, the cluster's id, KRaft or ZooKeeper, brokers and brokers fenced, the active controller |
| `kafka_replication` | 1m | admin | Partitions under-replicated, offline, under and at `min.insync.replicas`, not led by their preferred leader, with eligible leader replicas, being moved; by name, the topics with such partitions |
| `kafka_consumers` | 1m | admin | Each consumer group's lag on each topic, and its worst partition; partitions with no committed offset; each group's total |
| `kafka_quorum` | 2m | admin | KRaft's controller quorum: its leader and epoch, high watermark, voters and observers, and for each node how far behind it is and how long since it last fetched and caught up |
| `kafka_brokers` | 5m | admin | Each broker: listed or down, fenced, its rack, partitions it leads, replicas, replicas out of sync, partitions that prefer it as leader |
| `kafka_reassignment` | 5m | admin | Partition moves in progress: partitions, replicas being added and removed, each topic's |
| `kafka_groups` | 5m | admin | Every group by type (classic, consumer, share, streams) and state, each group's members, groups rebalancing, empty or dead |
| `kafka_topics` | 5m | admin | Topics, internal, with a single replica, compacted; each topic's partitions, replication factor, messages ever written (a running total) and messages it still holds |
| `kafka_logdirs` | 5m | admin, JMX | Each broker's log directories: size, partitions, offline, replicas being moved in; each broker's and topic's size on disk; with JMX, tiered storage, flush times and the log cleaner |
| `kafka_transactions` | 5m | admin | Transactions by state, those ongoing, those open longer than `KAFKA_TXN_LONG` (default 300 seconds): counts only |
| `kafka_config` | 15m | admin | Settings at risk: unclean leader election, topics created on demand, `min.insync.replicas`, replication factors (default, offsets, transactions), retention, listeners without TLS or a login, settings that differ between brokers, topics at risk |
| `kafka_security` | 15m | admin | ACLs by resource and permission, ACLs for every principal or every operation, users with SCRAM credentials, quotas: counts only |
| `kafka_features` | 15m | admin | The finalized features (`metadata.version` by name, when Kafka's server library is in `KAFKA_HOME`) against what the brokers support: an upgrade not finalized |
| `kafka_tls` | 1h | TLS | Each broker's certificate: days until it expires, trusted and naming the broker |
| `kafka_throughput` | 2m | JMX | Each broker's messages and bytes in and out, replication, produce and fetch requests and those that failed, bytes rejected, conversions, invalid records |
| `kafka_requests` | 2m | JMX | Produce, consumer fetch and follower fetch time (99th percentile), queue and remote time, requests served; request and response queues, purgatory; how idle the request handler and network threads are |
| `kafka_controller` | 2m | JMX | The active controller, and from it brokers, topics, partitions, offline partitions, leaders not where they prefer, metadata errors and lag, heartbeats timed out, leader elections (unclean ones too), its event queue |
| `kafka_connections` | 5m | JMX | Each broker's connections per listener, and logins that succeeded and failed |

Each script's header says what its metrics mean and how to read them. Worth knowing:

- **One JVM a run.** A job starts Java once, asks what it needs, and ends: no command-line tools, no text to parse.
- **What the library or the cluster does not have is left out, never a failure.** The KRaft quorum on ZooKeeper, transactions before 3.0, share and Streams groups before Kafka 4's library: the job says so in its log and prints the rest.
- The `_count` metrics are running totals: graph them as rates. `messages_count` is every message ever written to a topic, so its rate is the topic's write rate.
- Lists are capped (150 brokers, 150 group and topic pairs, 150 groups, 100 topics) so a big cluster stays under the 1000 lines Vigil takes from a run; the `_not_shown` metrics count the rest.
- `kraft.version` shows as behind on a cluster whose controllers are a fixed list (`controller.quorum.voters`): such a quorum cannot move to version 1, by design.

A cluster that cannot be reached reports `kafka.up` 0, and the run succeeds: that is a reading. The other jobs then print nothing and succeed. A refused login, a certificate that cannot be trusted, or a jar that does not match its digest fails the run, and its log says why; so does a JMX login refused, or a JMX certificate not trusted, for the jobs that read JMX.

**From 1.0.** `kafka_jvm` is gone: its JVM half is the jvm pack's, and its Kafka half (flush times, the log cleaner) is in `kafka_logdirs`. Where a job still runs it, `vigil pack update` keeps its script and says so (`dropped from the pack, still running: kafka_jvm`); `vigil pack disable kafka_jvm` stops it. Kafka's command-line tools are no longer run; `KAFKA_HOME` still names the Kafka download, now for its library. JMX takes a password and TLS, and `KAFKA_JMX` its targets as `jmxs=host:port` or `jmx=host:port` (a bare `host:port` still works, as `jmx=`). Java 11 or later, where 1.0 needed 17.

**Version 1.0, tested** on 2026-11-21 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-kafka.sh`, against clusters in Docker with SASL_SSL, SCRAM-SHA-512, a certificate from a test CA and the brokers' JMX open, made busy: a group that read part of a topic and stopped, one that keeps reading, a transaction held open, and a partition move held back by a throttle. `service-packs.sh` through Vigil, then every job as the busy cluster has it, with a broker stopped, and with it started again: **64 passed, 0 failed** against **Kafka 4.4.0**, three nodes in KRaft mode, with the 4.4.0 tools, the open transaction seen as `ongoing`, and later as `long_running`; **63 passed, 0 failed** against **Kafka 3.9.2**, three nodes in KRaft mode, with its own 3.9.2 tools; and **63 passed, 0 failed** against **Kafka 3.9.2 on ZooKeeper**, one broker (`--zookeeper`), so with no partition move and no broker stopped, with the 4.4.0 tools. In the 3.9.2 runs, and those of macOS and Windows below, the transaction did not stay open: the test then held it at Kafka's default timeout, a minute, and the broker ended it, so there `kafka_transactions` was seen to run and count, not to see one open. The full console output: [4.4.0](../tests/integration/backends/reports/runs/2026-11-21/fedora/pack-kafka-4.4.0/console.txt), [3.9.2](../tests/integration/backends/reports/runs/2026-11-21/fedora/pack-kafka-3.9.2/console.txt), [3.9.2 on ZooKeeper](../tests/integration/backends/reports/runs/2026-11-21/fedora/pack-kafka-3.9.2-zookeeper/console.txt). **On macOS**, on the Intel Mac test machine under its bash 3.2, with the 4.4.0 tools, against the 4.4.0 cluster on the Fedora machine through SSH tunnels: `service-packs.sh` through Vigil, **63 passed, 0 failed**: [the console output](../tests/integration/backends/reports/runs/2026-11-21/macos/pack-kafka-macos/console.txt). **On Windows**, against the same cluster the same way: every job directly, then `Service-Packs.ps1` through Vigil, **54 passed, 0 failed**, on Windows PowerShell 5.1 and PowerShell 7 on Windows 11 ([the console output](../tests/integration/backends/reports/runs/2026-11-21/windows/pack-kafka-windows/console.txt)), and on Windows PowerShell 5.1 on Windows Server 2025 ([the console output](../tests/integration/backends/reports/runs/2026-11-21/windows-server-2025/pack-kafka-windows/console.txt)). On Windows the password came from an `env:` reference: Windows refuses its data protection to a logon by SSH key, as the test machines' were.

### jvm

Java virtual machines: any Java application (Jenkins, Spring Boot, Elasticsearch, Keycloak, one of your own) through the JVM it runs on. The JVM, not the application: its process, memory, garbage collection, threads, JIT, classes, crashes, settings and security. Application servers and libraries (Tomcat, Jetty, connection pools) are for packs of their own, which report what is theirs and leave the JVM to this one. Linux, macOS and Windows; JVMs from Java 8.

Each script runs the pack's client, beside it, with Java 11 or later, a JDK or a JRE: one client for every platform, so each prints the same lines. It reaches each JVM in three tiers, and uses every one that reaches it:

| Tier | Needs | Reads |
| --- | --- | --- |
| 1. The operating system | Nothing | The process: up, memory, CPU, threads, open files, disk I/O, uptime; its startup options; crash reports and heap dumps on disk |
| 2. The JVM's own counters | The same machine, and Vigil running as root, an administrator or the JVM's own account. HotSpot JVMs (OpenJDK, Oracle, Temurin, Corretto, Zulu...), unless started with `-XX:-UsePerfData` | The `hsperfdata` file `jstat` reads: heap and pools, collections, threads, classes, the JIT, safepoints, promotion |
| 3. JMX | The JVM's JMX address, given in `JVM_TARGETS` | Everything else, on this machine or another |

So a JVM nobody set up is still watched: its process always, its counters when Vigil may read them. `jvm_status` says which tiers reach each JVM, and `jvm_discovery` lists the JVMs on the machine, and whether each is watched.

1. `vigil pack enable jvm`. With `JVM_TARGETS` empty, every JVM on this machine is watched, each named by its main class.
2. To name them, or to reach one over JMX, set `JVM_TARGETS` on the jobs' `env` lines: `name: key=value, ...; name: ...`, with `main=` (its main class or jar, or any text on its command line) or `pid=` (a pid file) to find it here, `jmx=host:port` or `jmxs=host:port` (JMX over TLS) for its JMX address, and `gclog=` for its GC log (written with `-Xlog:gc*:file=<path>`: plain `-Xlog:gc` leaves out ZGC's and Shenandoah's pauses; on Java 8, `-XX:+PrintGCDetails -XX:+PrintGCTimeStamps`):

   ```ini
   env = JVM_TARGETS=shop: main=com.acme.Shop, jmxs=localhost:9010, gclog=/var/log/shop/gc.log; jenkins: main=jenkins.war
   ```

   **The JMX address is the switch**: a JVM with one gets tier 3, one without gets tiers 1 and 2. A JVM with an address that does not answer reports `jmx_up 0`, which is worth an alert, and the other tiers still report. Vigil never looks for JMX ports by itself.
3. For JMX with a password (and it should have one), add a secret line to each job, under its `env` lines, and give Vigil the password, as the account Vigil runs as:

   ```ini
   secret = JVM_JMX_PASSWORD=secret:JVM_JMX_PASSWORD
   ```

   ```sh
   vigil secret set JVM_JMX_PASSWORD
   ```

   and the user in `JVM_JMX_USER`. With `jmxs=`, the JVM's certificate is checked against `JVM_CACERT` (a PEM file of CAs) or Java's own, and against its name: connect by the name on its certificate. No setting trusts a certificate unchecked.

**Turning JMX on, safely.** On the JVM, with a password, TLS, and only this machine's address when Vigil runs here:

```sh
java -Dcom.sun.management.jmxremote.port=9010 -Dcom.sun.management.jmxremote.rmi.port=9010 \
  -Dcom.sun.management.jmxremote.host=127.0.0.1 -Djava.rmi.server.hostname=localhost \
  -Dcom.sun.management.jmxremote.authenticate=true \
  -Dcom.sun.management.jmxremote.password.file=/etc/shop/jmx.password \
  -Dcom.sun.management.jmxremote.access.file=/etc/shop/jmx.access \
  -Dcom.sun.management.jmxremote.ssl=true -Dcom.sun.management.jmxremote.registry.ssl=true \
  -Djavax.net.ssl.keyStore=/etc/shop/jmx.p12 -Djavax.net.ssl.keyStorePassword=... ...
```

The password file holds `vigil <password>` and must be readable by the JVM's account alone; the access file gives the user its role. **`readonly` or `readwrite`**: JMX has only these two. A `readonly` user may read attributes, which is most of this pack. It may not run operations, which `jvm_deadlocks`, `jvm_contention`, `jvm_hot_threads`, `jvm_allocation`, `jvm_classloaders`, `jvm_native` and part of `jvm_threads` and `jvm_virtual_threads` need: with `readonly` they say so in their log, and print what they can. `readwrite` lets them run, and also lets the user run anything else a JVM offers over JMX (a heap dump, a setting changed): choose it knowing that.

**What it needs:**

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | Java 11 or later, a JDK or a JRE, `JAVA_HOME` or `java` on the PATH | The same | The same |
| For tier 2 | Vigil as root, or the JVM's account | Vigil as root, or the JVM's account | Vigil as an administrator, or the JVM's account |
| For tier 3 | Each JVM's JMX address in `JVM_TARGETS`, and with a password, a `secret` line and `vigil secret set JVM_JMX_PASSWORD` (step 3) | | |

| Job | Every | Tiers | Reports |
| --- | --- | --- | --- |
| `jvm_process` | 1m | 1 | Running, resident and virtual memory, CPU, threads, open files against the limit, uptime |
| `jvm_heap` | 1m | 2, 3 | Heap used, committed, maximum, used against the maximum |
| `jvm_gc` | 1m | 2, 3 | Collections and time per collector, the share of its life spent collecting |
| `jvm_threads` | 1m | 2, 3 | Live, daemon, peak, started; by state (JMX) |
| `jvm_deadlocks` | 1m | 3 | Deadlocked threads, each named with the lock it waits for and the thread that holds it |
| `jvm_pools` | 2m | 2, 3 | Each memory pool, and each as the last collection left it: old gen after a collection, the leak signal |
| `jvm_gc_cycles` | 2m | 3 | Pauses apart from concurrent work (ZGC, Shenandoah, G1's cycles) |
| `jvm_gc_last` | 2m | 3 | The last collection: how long, how long ago, what it freed and left |
| `jvm_allocation` | 2m | 3 | Allocation per second, over two seconds; the running total (Java 21 and later) |
| `jvm_os` | 2m | 3 | The JVM's and the system's CPU, load, memory, swap, open files against the limit |
| `jvm_status` | 5m | 1, 2, 3 | Up, which tiers reach it, version, vendor, VM, collectors, uptime, the heap's maximum |
| `jvm_metaspace` | 5m | 2, 3 | Metaspace and compressed class space against their limits |
| `jvm_codecache` | 5m | 2, 3 | The code cache by segment: when full, the JIT stops |
| `jvm_buffers` | 5m | 3 | Direct and mapped buffers: off-heap memory |
| `jvm_native_overhead` | 5m | 1 with 2 or 3 | Resident memory outside the heap: native leaks no Java figure shows |
| `jvm_gc_cpu` | 5m | 2, 3 | The GC threads' CPU against the process's (HotSpot 22 and later) |
| `jvm_promotion` | 5m | 2 | Promotion to old gen, tenuring, survivor overflow (Serial and Parallel) |
| `jvm_gclog` | 5m | GC log | Pauses in the last five minutes: count, longest, 99th percentile; full collections; allocation stalls |
| `jvm_virtual_threads` | 5m | 3 | Virtual threads' carriers; mounted and queued (Java 24 and later) |
| `jvm_classes` | 5m | 2, 3 | Classes loaded, ever loaded, unloaded |
| `jvm_jit` | 5m | 2, 3 | Time compiling, compilations, compiled code |
| `jvm_safepoints` | 5m | 2 | Time stopped at safepoints, and waiting for threads to stop |
| `jvm_io` | 5m | 1 | Disk reads and writes; open files by kind (Linux) |
| `jvm_crashes` | 5m | 1 | Crash reports, compiler replays and core dumps written |
| `jvm_oom` | 5m | 1 | Heap dumps written: out of memory |
| `jvm_mbeans` | 5m | 3 | MBean attributes you name in `JVM_MBEANS`, as numbers |
| `jvm_flags` | 15m | 1, 3 | No maximum heap, no heap dump or exit on out-of-memory, a removed collector, a heap over the machine's memory |
| `jvm_security` | 15m | 1, 3 | A debugger listening, beyond this machine too; JMX without a password or TLS; verification off |
| `jvm_startup` | 15m | 1, 2, 3 | When it started, how long the JVM took to start |
| `jvm_native` | 15m | 3 | Native memory by category, when the JVM tracks it |
| `jvm_tlab` | 15m | 2 | Allocation outside the threads' own buffers |
| `jvm_gclog_detail` | 15m | GC log | Pauses by length; humongous allocations, to-space exhaustion, evacuation and promotion failures |
| `jvm_contention` | 15m | 3 | Threads blocked, and the locks most waited for, with who holds them |
| `jvm_hot_threads` | 15m | 3 | The busiest threads by CPU, over two seconds |
| `jvm_classloaders` | 15m | 3 | Classloaders, and classes by loader type: redeploy leaks |
| `jvm_deopt` | 15m | 2 | Compilations thrown away and given up |
| `jvm_finalization` | 15m | 3 | Objects waiting to be finalized |
| `jvm_discovery` | 1h | 1, 2 | The JVMs on this machine, by main class and account, watched or not, counters readable or not |
| `jvm_container` | 1h | 3 | The CPUs and memory the JVM sees, against this machine's |
| `jvm_release_age` | 1h | 2, 3 | Its Java's feature release, long-term support or not, days since its release |
| `jvm_jfr` | 1h | 3 | Flight Recorder there, and its recordings |

Each script's header says what its metrics mean and how to read them. Worth knowing:

- **Nothing here pauses a JVM.** No heap dump, class histogram or thread dump with stacks: the jobs read counters, and make calls that are cheap on any heap.
- **A command line is read, never reported**: it can hold a password. The pack reads only the options it knows.
- **The client, compiled, and checked before it runs.** The client is one Java source file, `_client.java`. A JRE cannot run a source file, so the pack also carries it compiled, `_client.jar`, built from that source when the pack is released, and every script runs the jar. Before it does, it checks the jar against the SHA-256 the script carries, and a jar that does not match is not run: `_client.jar does not match the digest in this script`. The archive the jar comes in is checked against the signed pack index when the pack is installed. The jar is Java 11 bytecode, built so the same source gives the same bytes: each script names the `javac` that built it, so you can compile `_client.java` with that version (`tools/release/client-jar.sh`) and compare. A copy of the pack without the jar, straight from the repository, runs the source instead, which needs a JDK.
- **How long a run takes.** The client starts in about half a second from the jar, and in two or three seconds from the source, as Java compiles it each time; on Windows, PowerShell starts first. Then each JVM it reaches over JMX adds its own connection, more with TLS: on the Fedora test machine, the 41 jobs one after another against eight JVMs, six over JMX, took about three minutes in all. So only the cheap jobs run every minute; the rest every 2, 5 or 15 minutes, or each hour.
- **On Windows, an account CIM refuses** (one that is not an administrator, logged on over the network) still finds its own JVMs: Windows lists them without their command lines, and the pack reads each one's options and main class from its counters instead. Such a JVM has no disk reads and writes in `jvm_io`.
- `JVM_DUMP_DIRS` adds folders to look in for crash reports and heap dumps, for every JVM: the JVM's own `-XX:ErrorFile` and `-XX:HeapDumpPath`, and its working folder on Linux, are looked in already.

A JVM that is not running reports `running 0` (`jvm_process`) and `up 0` (`jvm_status`), and the run succeeds: that is a reading. A JMX login refused, or a certificate that cannot be trusted, fails the run, and its log says why.

**Tested** on 2026-11-22 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-jvm.sh`, with the client on Java 25.0.4, against eight JVMs made to misbehave (`Trouble.java`: a deadlock, leaked threads, a busy thread, blocked threads, leaking direct buffers and classloaders, an out-of-memory heap dump). Six were in Docker: **Java 8** with Parallel GC and JMX with a password but no TLS; **Java 11** tracking its native memory, **Java 17** with ZGC, **Java 21** with G1 and **Java 25** with Shenandoah and a debugger listening, each with JMX over TLS and a password; and a Java 21 with no JMX, run as root. Two ran on the machine itself on Java 25, one with JMX and one without. Beside them, a Java 17 crashed once, on purpose, for its crash report. `service-packs.sh` through Vigil, then every job: **93 passed, 0 failed**. That covers each tier alone and together, GC logs from Java 8, G1 and ZGC, a `readonly` JMX user, a wrong password, a certificate it cannot trust, JMX that does not answer and a JVM not running. Then from a container that sees the machine's processes as root, as Vigil running as root would, `jvm_discovery` and `jvm_heap` read the counters of all eight: [the console output](../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-jvm/console.txt). **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, Java 21), against a JVM of its own without JMX and the Fedora JVMs over JMX through SSH tunnels: every job directly, then `service-packs.sh` through Vigil, **64 passed, 0 failed**: [the console output](../tests/integration/backends/reports/runs/2026-11-22/macos/pack-jvm-macos/console.txt). **On Windows**, the same way with Java 21, `Service-Packs.ps1` through Vigil, **74 passed, 0 failed**: on Windows PowerShell 5.1 and PowerShell 7 on Windows 11 ([the console output](../tests/integration/backends/reports/runs/2026-11-22/windows/pack-jvm-windows/console.txt)), and on Windows PowerShell 5.1 on Windows Server 2025 ([the console output](../tests/integration/backends/reports/runs/2026-11-22/windows-server-2025/pack-jvm-windows/console.txt)). Both Windows machines ran it as an account that is not an administrator, logged on by SSH key. CIM refused that account, so the JVMs were found as above, without CIM. Windows also refuses its data protection to such a logon, so the password came from an `env:` reference.

**Version 1.1.0, on a JRE**, tested on 2026-11-22 the same way, against the same JVMs, then every job again on a JRE, from `_client.jar`.
- **On Fedora**, on Temurin's JRE 11, the oldest Java the client runs on, with the jar compiled by `tools/release/client-jar.sh` with `javac` 21: **106 passed, 0 failed**.
  - The jar built twice was the same, byte for byte, and its digest was in every script.
  - All 41 jobs ran from the jar, about three minutes in all, and every JVM was up.
  - Ten of the jobs printed the same lines, values apart, as the source does on a JDK.
  - A jar changed by one byte was refused, on the JRE and on a JDK, saying why. A script with no digest ran no jar. Without the jar, the JRE could not run the source, and Java said so.
  - [The console output](../tests/integration/backends/reports/runs/2026-11-22/fedora/pack-jvm-1.1.0/console.txt).
- **On macOS**, on the Intel Mac test machine, on Temurin's JRE 21: **77 passed, 0 failed**. [The console output](../tests/integration/backends/reports/runs/2026-11-22/macos/pack-jvm-1.1.0-macos/console.txt).
- **On Windows**, from a packs release built by `tools/release/packs.sh`, on Temurin's JRE 21: **86 passed, 0 failed** on each run.
  - Windows 11, on Windows PowerShell 5.1 and PowerShell 7: [the console output](../tests/integration/backends/reports/runs/2026-11-22/windows/pack-jvm-1.1.0-windows/console.txt).
  - Windows Server 2025, on Windows PowerShell 5.1: [the console output](../tests/integration/backends/reports/runs/2026-11-22/windows-server-2025/pack-jvm-1.1.0-windows/console.txt).

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
| `redis.up` | 1 | | 0 |
| `redis.clients_pct` | Below 70 | 70 to 90 | Above 90, or `rejected_connections_count` rising: clients are turned away |
| `redis.memory.used_pct` | Below 80, or steady at the limit on a cache meant to evict | 80 to 95 with policy `noeviction` | At 100 with policy `noeviction`: writes fail |
| `redis.replication.link_up` (a replica) | 1 | | 0: it serves older and older data |
| `redis.persistence.last_save_ok`, `aof_last_write_ok` | 1 | | 0: the disk is full or not writable, and the server refuses writes |

## Writing a pack

`tools/new-pack.sh <name>` starts one, and `tools/check-pack.sh --run <name>` says what is left to fix. [CONTRIBUTING.md](../CONTRIBUTING.md#your-first-pack) has the steps. In short:

- Use only what ships with the operating system: bash 3.2 and PowerShell 5.1.
- Print metrics as `metric <name> <value> [key=value ...]`, and use plain ASCII.
- Exit 0 when the script worked. A high reading is not a failure.
- Read data; never change the machine.
- Ship text you can read: scripts, and the source of anything they run. Nothing compiled goes in the repository. The one exception is a Java client (`_client.java`), since a JRE cannot run source: the release compiles it into `_client.jar` (`tools/release/client-jar.sh`), writes its digest into the scripts, and they check it before running it, as the jvm pack's do.
- Start with the same header as the other scripts: what it does, its metrics, an example of its output, what healthy and unhealthy look like, what it needs, its exit codes and the disclaimer.
- In `pack.config`, say what `vigil pack info` shows before anyone installs it: `works_with`, the servers it is meant for and tested with; `programs_linux`, `programs_macos` and `programs_windows`, the programs its scripts need on each; `docs`, its section here; and `needs`, what an administrator sets up first.

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../LICENSE) gives the full terms, and it takes precedence over this summary.
