# The mysql pack

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

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| A client on the Vigil machine | `mysql` or `mariadb`: Debian `default-mysql-client` or `mariadb-client`, Ubuntu `mysql-client`, Fedora and RHEL `mysql` or `mariadb` | Homebrew's `mysql-client` or `mariadb` | `mysql.exe` or `mariadb.exe`, from MySQL's or MariaDB's installer or zip. Found on the `PATH`, or under `Program Files\MySQL\MySQL Server <version>\bin` or `Program Files\MariaDB <version>\bin` |
| The server | Tested with MySQL 8.4 and MariaDB 11.4; meant for MySQL 8.0 and MariaDB 10.5 on | | |
| A user | `vigil_monitor`, with `PROCESS` and `REPLICATION CLIENT`, and on MariaDB `REPLICA MONITOR` (step 1); allowed in from the Vigil machine | | |
| A secret | `MYSQL_MONITOR_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |
| Where to connect | Each job's `env` lines: `MYSQL_HOST`, `MYSQL_TCP_PORT`, `MYSQL_USER` | | |

The client must be on the `PATH` the Vigil service runs with, as well as yours. A package manager's `/usr/bin` is; Homebrew's `mysql-client` is not, as it is keg-only. Give such jobs an `env` line for it, such as `env = PATH=/opt/homebrew/opt/mysql-client/bin:/usr/bin:/bin`.

## Its jobs

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


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `mysql.up`.

```text
+--------------------------------------------------------------------------------------------------+
| mysql_status   mysql.<metric>   every 1m                                                         |
+------------------------+-------------------------------------------------------------------------+
| up                     | 1 when the server answers, else 0                                       |
| connections            | client connections now                                                  |
| max_connections        | the server's limit                                                      |
| connections_pct        | connections as a percent of the limit                                   |
| running                | client connections running a statement now, leaving out this one and    |
|                        | replication threads                                                     |
| longest_query_seconds  | the longest statement running now (replication threads left out)        |
| queries_count          | statements run (a running total)                                        |
| slow_queries_count     | statements over long_query_time (a running total)                       |
| aborted_connects_count | failed connection attempts (a running total)                            |
| tmp_disk_tables_count  | temporary tables that spilled to disk (a running total)                 |
+------------------------+-------------------------------------------------------------------------+
| GOOD  up 1; connections_pct below 70; running a handful; no statement running for minutes.       |
| WATCH connections_pct 70 to 90; running in the tens for long: the server is busy, or statements  |
|       queue on locks; slow_queries_count or tmp_disk_tables_count rising faster than usual.      |
| BAD   up 0; connections_pct above 90, and new connections will soon be refused;                  |
|       aborted_connects_count rising fast: bad passwords, or a full server. The _count totals     |
|       restart with the server: graph them as a rate.                                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mysql_activity   mysql.activity.<metric>   every 1m                                              |
+--------------------------------+-----------------------------------------------------------------+
| longest_transaction_seconds    | the longest open transaction now                                |
| idle_in_transaction            | transactions open on a connection that is doing nothing         |
| longest_idle_in_transaction_se | the longest of those idle times                                 |
| conds                          |                                                                 |
| waiting                        | transactions waiting on a row lock                              |
| longest_wait_seconds           | the longest row lock wait now                                   |
+--------------------------------+-----------------------------------------------------------------+
| GOOD  waiting at 0, or briefly above it; no transaction open for minutes; no connection idle in  |
|       a transaction for more than a few seconds.                                                 |
| WATCH longest_wait_seconds above a few seconds, again and again: statements queue behind each    |
|       other's row locks.                                                                         |
| BAD   longest_wait_seconds nearing innodb_lock_wait_timeout (50 s by default), when statements   |
|       start failing; a transaction idle for minutes holds its locks and lets the undo history    |
|       grow (mysql_innodb history_list_count): find it in information_schema.INNODB_TRX and fix   |
|       the application, or lower wait_timeout.                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mysql_replication   mysql.replication.<metric>   every 1m                                        |
+-------------+------------------------------------------------------------------------------------+
| is_replica  | 1 when it replicates from a source, else 0                                         |
| io_running  | (replica) 1 while the thread receiving from the source runs, tagged channel=<name, |
|             | or default>                                                                        |
| sql_running | (replica) 1 while the thread applying the changes runs, tagged channel=<name, or   |
|             | default>                                                                           |
| lag_seconds | (replica) how far behind the source it is (Seconds_Behind_Source), tagged          |
|             | channel=<name, or default>; left out while the applying thread is stopped, when    |
|             | the server cannot tell                                                             |
| replicas    | (source) replicas connected to it now; one whose machine stopped without closing   |
|             | its connection still counts until the source's connection to it times out          |
+-------------+------------------------------------------------------------------------------------+
| GOOD  on a replica, io_running 1 and sql_running 1, and lag_seconds a few seconds at most; on a  |
|       source, replicas as many as you run.                                                       |
| WATCH lag_seconds rising during heavy writes and not falling after them: the replica applies     |
|       more slowly than the source writes.                                                        |
| BAD   io_running 0: the replica cannot reach or log in to its source; sql_running 0: applying    |
|       stopped on an error (SHOW REPLICA STATUS says which); either way it falls further behind.  |
|       replicas below what you run, on the source: one is not connected. Alert on each replica's  |
|       own io_running and mysql.up as well: they say at once what the source may learn only       |
|       minutes later.                                                                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mysql_innodb   mysql.innodb.<metric>   cron 4/5 * * * *                                          |
+----------------------+---------------------------------------------------------------------------+
| buffer_pool_hit_pct  | reads served from the buffer pool, since the server started; left out     |
|                      | while the server's counters cannot give it (MariaDB counts read requests  |
|                      | only in part, and on a fresh server can show more reads from disk than    |
|                      | requests)                                                                 |
| buffer_pool_used_pct | pages of the buffer pool in use                                           |
| history_list_count   | undo log entries waiting for purge                                        |
| row_lock_waits_count | times a statement waited for a row lock (a running total)                 |
| deadlocks_count      | deadlocks InnoDB detected (a running total)                               |
+----------------------+---------------------------------------------------------------------------+
| GOOD  buffer_pool_hit_pct above 99 on a busy server; history_list_count in the thousands at      |
|       most, and falling back after bursts.                                                       |
| WATCH buffer_pool_used_pct at 100 with the hit rate falling: the working set no longer fits      |
|       (innodb_buffer_pool_size). history_list_count climbing for hours: purge cannot keep up, or |
|       a long transaction holds it back (mysql_activity).                                         |
| BAD   history_list_count in the millions: queries slow down as they read old row versions; end   |
|       the transaction holding it back. deadlocks_count rising: transactions take their locks in  |
|       different orders (SHOW ENGINE INNODB STATUS shows the last one). The _count totals restart |
|       with the server: graph them as a rate.                                                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mysql_size   mysql.database.<metric>   cron 8/15 * * * *                                         |
+------------+-------------------------------------------------------------------------------------+
| size_bytes | a database's InnoDB tables on disk, tagged database=<name>                          |
+------------+-------------------------------------------------------------------------------------+
| GOOD  growth in line with the data the database takes in.                                        |
| WATCH a database growing much faster than usual.                                                 |
| BAD   growth that will fill the disk soon: compare with the disk's free space (the base pack's   |
|       disk job).                                                                                 |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, not rules: Vigil runs the jobs and delivers what they print, and the alerts are yours, in the backend you already use. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Give most alerts a few minutes, since a lock held for a moment or a burst of writes that a replica soon catches up on is healthy. The last column is what the test servers showed, in the console output of [MySQL 8.4](../../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-mysql-replication/console.txt) and [MariaDB 11.4](../../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-mariadb-replication/console.txt), and on Windows ([MySQL 8.4](../../tests/integration/backends/reports/runs/2026-11-19/windows/pack-mysql-windows/console.txt), [MariaDB 11.4](../../tests/integration/backends/reports/runs/2026-11-19/windows/pack-mariadb-windows/console.txt)): most of it caused on purpose, and where we caused nothing, it says so. Everything not here (statements, temporary tables on disk, row lock waits, `is_replica`) is for dashboards.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `mysql.up` | 1 | | 0: the server does not answer | 0 for the replica, stopped, on MySQL and MariaDB |
| `mysql.connections_pct` | Below 70 | 70 to 90 | Above 90: new connections will soon be refused | Not caused: 2 on Linux, 1 on Windows |
| `mysql.replication.sql_running` (on a replica) | 1 | | 0: applying stopped, often on an error (`SHOW REPLICA STATUS` says which), and the replica falls behind | 0 with the replica's applying thread stopped, on MySQL and MariaDB |
| `mysql.replication.io_running` (on a replica) | 1 | | 0: the replica cannot reach or log in to its source | Not caused: 1 in every run, even with the applying thread stopped |
| `mysql.replication.lag_seconds` (on a replica) | A few seconds at most | Rising for 15 minutes or more, or not falling after heavy writes | Still rising after an hour, or more than your application can stand | Not caused: 0. Missing while the applying thread was stopped, so alert on `sql_running` too |
| `mysql.replication.replicas` (on a source) | As many as you run | | Fewer than you run: a replica is not connected. It can take minutes to fall, so alert on each replica's own `mysql.up` and `io_running` too | Still 1 with the replica stopped: the source counts it until their connection times out |
| `mysql.activity.waiting`, `longest_wait_seconds` | 0, or briefly more | `longest_wait_seconds` above a few seconds, again and again: statements queue on each other's row locks | Near `innodb_lock_wait_timeout` (50 seconds by default): statements start failing | `waiting 1`, for 9 seconds on MySQL and 8 on MariaDB, behind a row the test held |
| `mysql.activity.idle_in_transaction`, `longest_idle_in_transaction_seconds` | 0, or a few seconds | Over a minute | Several minutes: it holds its locks and lets the undo history grow | `idle_in_transaction 1`, for 10 seconds on MySQL and 9 on MariaDB: the transaction the test held open |
| `mysql.activity.longest_transaction_seconds` | Seconds | Minutes, and longer than any job you expect: it holds back purge | | 10 on both: the transaction the test held open |
| `mysql.innodb.history_list_count` | Thousands at most, falling back after bursts | Rising for hours: purge cannot keep up, or a long transaction holds it back | In the millions: queries slow down; end the transaction holding it back | Not caused: 8 on MySQL, 0 on MariaDB |
| `mysql.innodb.deadlocks_count` (as a rate) | 0, or rare | Above its usual | Rising, and staying up: transactions take their locks in different orders (`SHOW ENGINE INNODB STATUS` shows the last one) | One made on purpose on each: `the deadlock counted` passed (the console does not print the count) |
| `mysql.longest_query_seconds` | Seconds | Minutes, where statements usually take seconds | | 8 on MySQL, 6 on MariaDB: the statement waiting for the held row |
| `mysql.running` | A handful | Far above its usual for 15 minutes or more: the server is busy, or statements queue on locks | | 1 while a statement waited for the held row; 0 on Windows |
| `mysql.aborted_connects_count` (as a rate) | Near 0 | Above its usual | Rising fast: bad passwords, someone guessing, or a full server | Not caused: 0 in every run |
| `mysql.slow_queries_count` (as a rate) | Steady | Rising faster than usual | | Not caused: 0, and 1 by the end of the MySQL run on Windows |
| `mysql.innodb.buffer_pool_hit_pct`, `buffer_pool_used_pct` | Hit rate above 99 on a busy server | `buffer_pool_used_pct` at 100 and the hit rate falling: the working set no longer fits | | Not caused: 94 and 49 on a fresh MySQL. On MariaDB no hit rate at all (used 14), as its counters could not give one yet |
| `mysql.database.size_bytes` | Growth in line with the data taken in | Growing much faster than usual | Growth that will fill the disk soon: compare with the base pack's disk job | Not caused: 114,688 bytes for `orders` on MySQL, 65,536 on MariaDB |

## How it was tested

**Tested** on 2026-11-19 on the Fedora 44 test machine, against **MySQL 8.4.13 and MariaDB 11.4.13**, each a source with a replica replicating by GTID (`compose.mysql.yaml`), each with its own client, by `tests/integration/backends/scripts/run-replication.sh`: `service-packs.sh` through Vigil, **39 passed, 0 failed** on each, then the replica's applying thread stopped and started, and the replica itself. The full console output: [MySQL 8.4](../../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-mysql-replication/console.txt), [MariaDB 11.4](../../tests/integration/backends/reports/runs/2026-11-19/fedora/pack-mariadb-replication/console.txt). **On Windows**, every job on Windows PowerShell 5.1 and PowerShell 7, with each vendor's Windows client, against a source and replica on another machine, then through Vigil itself on Windows: [MySQL 8.4](../../tests/integration/backends/reports/runs/2026-11-19/windows/pack-mysql-windows/console.txt), [MariaDB 11.4](../../tests/integration/backends/reports/runs/2026-11-19/windows/pack-mariadb-windows/console.txt). In CI, the same test runs against MySQL 8.4 and MariaDB 11.4, without a replica, on every change to Vigil itself. From MariaDB 11.4:

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

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
