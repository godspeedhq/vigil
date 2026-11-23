# The mssql pack

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

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| A client on the Vigil machine | `sqlcmd`: Microsoft's `mssql-tools18` (it looks in `/opt/mssql-tools18/bin` too), or the Go one (`go-sqlcmd`) | The Go `sqlcmd`, from its [releases](https://github.com/microsoft/go-sqlcmd/releases) | None |
| The server | SQL Server 2019, 2022 or 2025, on Linux or Windows | | |
| A login | `vigil_monitor`, with what step 1 grants | | |
| A secret | `MSSQL_MONITOR_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |
| Where to connect | Each job's `env` lines: `MSSQL_HOST`, `MSSQL_PORT`, `MSSQL_USER`; `MSSQL_CACERT`, `MSSQL_CERT_NAME` | | |

## Its jobs

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


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `mssql.up`.

```text
+--------------------------------------------------------------------------------------------------+
| mssql_status   mssql.<metric>   every 1m                                                         |
+-----------------+--------------------------------------------------------------------------------+
| up              | 1 when the server answers, else 0                                              |
| info            | always 1, tagged release=<2019, 2022 or 2025>, version=<its build>,            |
|                 | update=<its CU>, edition=<developer, enterprise, standard, express or web> and |
|                 | os=<linux or windows>                                                          |
| uptime_seconds  | how long it has run                                                            |
| cpus            | the CPUs it sees                                                               |
| schedulers      | the schedulers it runs work on                                                 |
| connections     | user connections now                                                           |
| connections_max | the most it allows                                                             |
| clustered       | 1 in a failover cluster instance                                               |
| cluster_node    | in a failover cluster: always 1, tagged node=<the node it runs on now>         |
| hadr_enabled    | 1 when Always On availability groups are enabled                               |
| agent_running   | SQL Agent: 1 running, 0 stopped; left out where there is none (Express)        |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  up 1; agent_running 1 where Agent runs the backups.                                        |
| WATCH connections growing toward connections_max; uptime_seconds back near 0: it restarted.      |
| BAD   up 0; agent_running 0 on a server whose backups Agent schedules; cluster_node changing     |
|       when no one moved it: it failed over.                                                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_performance   mssql.performance.<metric>   every 1m                                        |
+------------------------------+-------------------------------------------------------------------+
| batch_requests_count         | requests run (a running total)                                    |
| compilations_count           | query plans compiled (a running total)                            |
| recompilations_count         | plans compiled again (a running total)                            |
| transactions_count           | transactions started, all databases (a running total)             |
| logins_count                 | logins (a running total)                                          |
| logouts_count                | logouts (a running total)                                         |
| processes_blocked            | sessions waiting on another now                                   |
| errors_count                 | errors raised (a running total)                                   |
| page_life_expectancy_seconds | how long a page stays in the buffer pool                          |
| lazy_writes_count            | pages written to free memory (a running total)                    |
| checkpoint_pages_count       | pages written by checkpoints (a running total)                    |
| page_reads_count             | pages read from disk (a running total)                            |
| page_writes_count            | pages written to disk (a running total)                           |
| lock_waits_count             | lock requests that had to wait (a running total)                  |
| lock_timeouts_count          | lock requests that gave up (a running total)                      |
| deadlocks_count              | deadlocks (a running total)                                       |
| page_splits_count            | index pages split in two (a running total)                        |
| full_scans_count             | whole tables or indexes scanned (a running total)                 |
| memory_grants_pending        | queries waiting for memory to run                                 |
| memory_grants_outstanding    | queries holding memory to run                                     |
| buffer_cache_hit_pct         | pages found in memory, as a percent                               |
| missing_indexes              | indexes the optimizer wished for since the server started         |
| missing_index_top_impact_pct | the most one of them would improve its queries, as a percent      |
+------------------------------+-------------------------------------------------------------------+
| GOOD  memory_grants_pending 0; deadlocks_count flat; page_life_expectancy_seconds steady.        |
| WATCH page_life_expectancy_seconds falling: memory is short for the data; compilations_count     |
|       close to batch_requests_count: plans are not reused; lock_timeouts_count rising.           |
| BAD   memory_grants_pending above 0 for minutes: queries wait for memory; deadlocks_count        |
|       rising. The _count totals restart with the server: graph them as a rate.                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_activity   mssql.activity.<metric>   every 1m                                              |
+-----------------------------+--------------------------------------------------------------------+
| sessions                    | user sessions, tagged state=<running, sleeping, dormant or         |
|                             | preconnect>                                                        |
| requests                    | requests running now                                               |
| requests_blocked            | requests waiting on another session                                |
| head_blockers               | sessions that block others and wait on no one                      |
| longest_request_seconds     | how long the longest request has run                               |
| longest_wait_seconds        | the longest wait now, tagged type=<its wait type, or none>         |
| oldest_transaction_seconds  | how long the oldest open transaction has been open                 |
| idle_in_transaction         | sessions asleep with a transaction open                            |
| idle_in_transaction_seconds | how long the longest of them has slept                             |
| longest_snapshot_seconds    | how long the longest snapshot transaction has run                  |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  requests_blocked and head_blockers 0; idle_in_transaction 0.                               |
| WATCH oldest_transaction_seconds in minutes: it holds locks and keeps the log from being reused; |
|       longest_snapshot_seconds growing: tempdb's version store grows with it.                    |
| BAD   head_blockers above 0 for minutes: one session holds up others, find it;                   |
|       idle_in_transaction above 0 for long: an application that did not commit.                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_cpu   mssql.cpu.<metric>   every 1m                                                        |
+-----------------+--------------------------------------------------------------------------------+
| sql_pct         | CPU used by SQL Server, as a percent of the machine; left out in its first     |
|                 | minute, before it records any                                                  |
| other_pct       | CPU used by everything else (Windows only: on Linux SQL Server cannot tell)    |
| runnable_tasks  | tasks ready to run that wait for a CPU                                         |
| work_queued     | tasks waiting for a worker thread                                              |
| pending_disk_io | disk reads and writes not yet done                                             |
| workers         | worker threads now                                                             |
| workers_max     | the most it may have                                                           |
| workers_pct     | workers as a percent of the most                                               |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  runnable_tasks near 0; work_queued 0; workers_pct below 70.                                |
| WATCH runnable_tasks steadily above the CPUs: CPU pressure; other_pct high: something else on    |
|       the machine competes for it.                                                               |
| BAD   work_queued above 0, or workers_pct near 100: new queries cannot start (thread             |
|       starvation).                                                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_replication   mssql.replication.<metric>   every 1m                                        |
+------------------+-------------------------------------------------------------------------------+
| primary          | 1 for the primary replica, tagged group=<its name, where the login may see    |
|                  | it; else its id> and replica=                                                 |
| connected        | 1 when the replica is connected                                               |
| health           | 2 healthy, 1 partly, 0 not healthy                                            |
| local            | 1 for this server                                                             |
| sync_state       | each database: 2 synchronized, 1 synchronizing, 0 neither; tagged group=,     |
|                  | replica= and database=                                                        |
| suspended        | 1 when its data movement is suspended                                         |
| send_queue_bytes | log not yet sent to the secondary                                             |
| send_rate_bytes  | log sent a second                                                             |
| redo_queue_bytes | log received but not yet redone on the secondary                              |
| redo_rate_bytes  | log redone a second                                                           |
| lag_seconds      | how far the secondary is behind                                               |
+------------------+-------------------------------------------------------------------------------+
| GOOD  health 2; connected 1; sync_state 2 (synchronous) or 1 (asynchronous); queues near 0.      |
| WATCH send_queue_bytes or redo_queue_bytes growing: the secondary falls behind; lag_seconds      |
|       rising.                                                                                    |
| BAD   connected 0; health 0; suspended 1: that database is not protected; primary changing when  |
|       no one failed it over.                                                                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_waits   mssql.waits.<metric>   cron 1/5 * * * *                                            |
+-------------------+------------------------------------------------------------------------------+
| wait_ms_count     | milliseconds waited, tagged kind=<cpu, disk_read, log_write, lock, latch,    |
|                   | memory, network, parallelism, replication, external or other> (a running     |
|                   | total)                                                                       |
| top_wait_ms_count | milliseconds waited by one of the ten most costly types, tagged type= (a     |
|                   | running total)                                                               |
| top_waits_count   | waits of that type (a running total)                                         |
+-------------------+------------------------------------------------------------------------------+
| GOOD  each kind's rate steady with the workload.                                                 |
| WATCH disk_read rising: the data does not fit in memory, or the disk is slow; log_write rising:  |
|       the log's disk is slow; lock rising: blocking; network: a client reads its results slowly. |
| BAD   cpu (signal waits) a large share of the total: the CPUs are saturated. The totals restart  |
|       with the server: graph them as a rate, and compare kinds.                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_io   mssql.io.<metric>   cron 2/5 * * * *                                                  |
+----------------------+---------------------------------------------------------------------------+
| reads_count          | reads, tagged database=, file= and kind=<data or log> (a running total)   |
| writes_count         | writes (a running total)                                                  |
| read_bytes_count     | bytes read (a running total)                                              |
| written_bytes_count  | bytes written (a running total)                                           |
| read_stall_ms_count  | milliseconds spent waiting on reads (a running total)                     |
| write_stall_ms_count | milliseconds spent waiting on writes (a running total)                    |
| size_bytes           | the file's size on disk                                                   |
| ..._not_shown        | past 100 of a list (files), how many were left out                        |
+----------------------+---------------------------------------------------------------------------+
| GOOD  latency (the stall's rate over the reads' or writes') below 10 ms for data, 2 ms for a     |
|       log.                                                                                       |
| WATCH read latency 10 to 20 ms; a log's write latency above 5 ms.                                |
| BAD   read latency above 20 ms, or a log's write latency above 10 ms, for long: the disk is the  |
|       bottleneck.                                                                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_memory   mssql.memory.<metric>   cron 3/5 * * * *                                          |
+------------------------+-------------------------------------------------------------------------+
| target_bytes           | the memory SQL Server aims for                                          |
| total_bytes            | the memory it holds                                                     |
| process_bytes          | physical memory the process uses                                        |
| process_low            | 1 when SQL Server finds its memory low                                  |
| system_total_bytes     | the machine's (or container's) memory                                   |
| system_available_bytes | memory free on it                                                       |
| system_low             | 1 when the machine signals low memory                                   |
| buffer_pool_bytes      | data pages held in memory                                               |
| memory_grants_bytes    | memory granted to running queries                                       |
| plan_cache_bytes       | cached query plans                                                      |
| single_use_plan_bytes  | ad hoc plans used once only                                             |
| xtp_bytes              | In-Memory OLTP                                                          |
| clerk_bytes            | the five memory clerks that hold the most, tagged clerk=                |
+------------------------+-------------------------------------------------------------------------+
| GOOD  total_bytes at target_bytes; process_low and system_low 0.                                 |
| WATCH single_use_plan_bytes a large share of plan_cache_bytes: turn on optimize for ad hoc       |
|       workloads; system_available_bytes low.                                                     |
| BAD   process_low or system_low 1: SQL Server, or the machine, is short of memory.               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_tempdb   mssql.tempdb.<metric>   cron 4/5 * * * *                                          |
+------------------------+-------------------------------------------------------------------------+
| size_bytes             | tempdb's data files                                                     |
| free_bytes             | space free in them                                                      |
| free_pct               | free as a percent                                                       |
| version_store_bytes    | row versions, for snapshot isolation and online index builds            |
| user_objects_bytes     | temporary tables and table variables                                    |
| internal_objects_bytes | sorts, hashes and spools                                                |
| log_used_pct           | its log in use, as a percent                                            |
| data_files             | its data files                                                          |
+------------------------+-------------------------------------------------------------------------+
| GOOD  free_pct above 20.                                                                         |
| WATCH version_store_bytes growing: a long transaction keeps old row versions (mssql_activity     |
|       longest_snapshot_seconds); free_pct below 20.                                              |
| BAD   free_pct near 0: queries that need tempdb fail.                                            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_connections   mssql.connections.<metric>   cron 0/5 * * * *                                |
+---------------------+----------------------------------------------------------------------------+
| connections         | connections, tagged encrypted=<yes or no>                                  |
| connections_by_auth | connections, tagged auth=<sql, kerberos or ntlm>                           |
| sessions            | user sessions in the 50 databases with the most, tagged database=          |
+---------------------+----------------------------------------------------------------------------+
| GOOD  encrypted=no 0 where clients should encrypt.                                               |
| WATCH auth=ntlm where Kerberos is expected: a missing SPN, quietly slower and weaker.            |
| BAD   encrypted=no above 0 on a server that must encrypt every connection.                       |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_databases   mssql.database.<metric>   cron 6/15 * * * *                                    |
+----------------------+---------------------------------------------------------------------------+
| databases            | databases on the server                                                   |
| online               | 1 when online, tagged database=                                           |
| state                | 0 online, 1 restoring, 2 recovering, 3 recovery pending, 4 suspect, 5     |
|                      | emergency, 6 offline; tagged state=                                       |
| read_only            | 1 when read-only                                                          |
| recovery             | always 1, tagged model=<full, bulk_logged or simple>                      |
| data_bytes           | its data files                                                            |
| log_bytes            | its log                                                                   |
| log_used_bytes       | its log in use                                                            |
| log_used_pct         | its log in use, as a percent                                              |
| log_reuse_waiting    | 1 when something keeps the log from being reused, tagged                  |
|                      | reason=<log_backup, active_transaction, replication and the like, or      |
|                      | nothing>                                                                  |
| active_transactions  | transactions open in it                                                   |
| compatibility_level  | its compatibility level                                                   |
| compatibility_behind | 1 when below the server's own                                             |
| query_store          | 0 off, 1 read only (often full), 2 read and write, 3 in error             |
| ..._not_shown        | past 100 of a list (databases), how many were left out                    |
+----------------------+---------------------------------------------------------------------------+
| GOOD  online 1; log_used_pct below 70; log_reuse_waiting 0 or reason=log_backup between log      |
|       backups.                                                                                   |
| WATCH log_used_pct above 70 and rising; query_store 1 where it should record;                    |
|       compatibility_behind 1 after an upgrade.                                                   |
| BAD   online 0 or state 4 (suspect); log_used_pct near 100: writes stop when the log cannot      |
|       grow; log_reuse_waiting with reason=active_transaction for long.                           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_health   mssql.health.<metric>   cron 8/15 * * * *                                         |
+------------------------+-------------------------------------------------------------------------+
| checkdb_age_days       | days since the last DBCC CHECKDB that found nothing, tagged database=;  |
|                        | -1 never                                                                |
| vlfs                   | virtual log files in its log                                            |
| pct_growth_files       | files that grow by a percentage                                         |
| max_size_used_pct      | a file with a maximum size: how much of it is used, tagged database=,   |
|                        | file= and kind=                                                         |
| volume_total_bytes     | a volume with database files, tagged volume=                            |
| volume_free_bytes      | space free on it                                                        |
| volume_free_pct        | free as a percent                                                       |
| express_limit_used_pct | Express edition: a database's data against its 10 GB limit              |
| encryption_state       | with transparent data encryption: 3 encrypted, 2 encrypting, 4 changing |
|                        | its key, 5 decrypting, 1 not yet                                        |
| suspect_pages          | pages found damaged (bad checksum, torn page, I/O error) and not yet    |
|                        | repaired                                                                |
+------------------------+-------------------------------------------------------------------------+
| GOOD  checkdb_age_days 0 to 7; suspect_pages 0; volume_free_pct above 20.                        |
| WATCH checkdb_age_days above 7, or -1; vlfs in the thousands; pct_growth_files above 0.          |
| BAD   suspect_pages above 0: run DBCC CHECKDB and restore what it finds; max_size_used_pct or    |
|       express_limit_used_pct near 100: writes fail; volume_free_pct below 10.                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_config   mssql.config.<metric>   cron 10/15 * * * *                                        |
+---------------------------+----------------------------------------------------------------------+
| max_server_memory_mb      | max server memory                                                    |
| max_server_memory_default | 1 when left at its default, so SQL Server may take the machine's     |
|                           | memory                                                               |
| maxdop                    | max degree of parallelism (0: all CPUs)                              |
| cost_threshold            | cost threshold for parallelism                                       |
| optimize_for_ad_hoc       | 1 when optimize for ad hoc workloads is on                           |
| xp_cmdshell               | 1 when xp_cmdshell is on                                             |
| clr_enabled               | 1 when CLR is on                                                     |
| ole_automation            | 1 when OLE Automation Procedures are on                              |
| remote_admin_connections  | 1 when the dedicated admin connection takes remote clients           |
| sa_enabled                | 1 when the sa login is enabled                                       |
| sysadmins                 | enabled logins in the sysadmin role                                  |
| instant_file_init         | 1 when instant file initialization is on (Windows)                   |
| locked_pages              | 1 when its memory is locked in place                                 |
+---------------------------+----------------------------------------------------------------------+
| GOOD  max_server_memory_default 0; xp_cmdshell, clr_enabled and ole_automation 0 unless needed.  |
| WATCH cost_threshold 5 (the default) on a busy server; sysadmins growing.                        |
| BAD   xp_cmdshell 1 where nothing needs it; sa_enabled 1 with a weak password; any of them       |
|       changing when no one meant to.                                                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_backups   mssql.backups.<metric>   cron 12/15 * * * *                                      |
+------------------+-------------------------------------------------------------------------------+
| full_age_seconds | since the last full backup, tagged database=; -1 none in 400 days             |
| diff_age_seconds | since the last differential backup; -1 none                                   |
| log_age_seconds  | since the last log backup (full or bulk-logged recovery); -1 none             |
| never_backed_up  | databases with no full backup in 400 days                                     |
+------------------+-------------------------------------------------------------------------------+
| GOOD  full_age_seconds within your schedule (a day or a week); log_age_seconds within minutes to |
|       an hour.                                                                                   |
| WATCH log_age_seconds growing past your schedule: the log grows and the data you can lose with   |
|       it.                                                                                        |
| BAD   never_backed_up above 0; full_age_seconds -1 or far past the schedule: the backups         |
|       stopped.                                                                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mssql_agent   mssql.agent.<metric>   cron 14/15 * * * *                                          |
+-------------------------+------------------------------------------------------------------------+
| readable                | 1 when this login may read Agent's jobs, else 0                        |
| jobs                    | Agent jobs                                                             |
| jobs_enabled            | those enabled                                                          |
| failed_24h              | job runs that failed in the last 24 hours                              |
| job_failed_24h          | a job that failed in them: its failures, tagged job=                   |
| running                 | jobs running now                                                       |
| longest_running_seconds | how long the longest has run                                           |
+-------------------------+------------------------------------------------------------------------+
| GOOD  readable 1; failed_24h 0.                                                                  |
| WATCH longest_running_seconds longer than the job usually takes.                                 |
| BAD   failed_24h above 0: see which in job_failed_24h; readable 0: grant what packs/README.md    |
|       says.                                                                                      |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, not rules: Vigil runs the jobs and delivers what they print, and the alerts are yours, in the backend you already use. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Give most alerts a few minutes, since a request blocked for a few seconds, or a secondary catching up after a restart, is healthy. The last column is what the test servers showed, in [the 2025 run's console output](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-mssql-2025-replication/console.txt) and the others under **Tested** below: most of it caused on purpose, and where we caused nothing, it says so. Everything not here (the workload, waits, file I/O, the plan cache, sizes) is for dashboards.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `mssql.up` | 1 | | 0: the server does not answer | 0 for the secondary, stopped, and with the job pointed at a port where nothing listens |
| `mssql.database.online`, `mssql.database.state` | 1, and `state` 0 | | `online` 0 when no one took it offline or is restoring it; `state` 3 (recovery pending) or 4 (suspect) always | Not caused: `online 1` and `state 0` for every database |
| `mssql.database.log_used_pct` | Below 70 | Above 70 and rising | Above 90 and the log cannot grow (a maximum size, or the disk full): writes stop | Not caused: 9 for the test's database; 79 at most, tempdb's own, on Windows |
| `mssql.database.log_reuse_waiting` | 0, or 1 with `reason=log_backup` between log backups | `reason=log_backup` past your log backup schedule | `reason=active_transaction`, `replication` or `availability_replica` for long, with `log_used_pct` rising | Not caused: `reason=nothing`, even with the test's transaction open |
| `mssql.backups.full_age_seconds`, `mssql.backups.never_backed_up` | Within your schedule (a day, or a week); 0 | Past the schedule | `full_age_seconds` -1 or twice the schedule, or `never_backed_up` above 0: the backups stopped, or never started | `never_backed_up 3`: master, model and msdb, which the test never backed up; the test's database 47 seconds after its backup |
| `mssql.backups.log_age_seconds` (full or bulk-logged recovery) | Within your log backup schedule (minutes to an hour) | Past the schedule: the log grows, and so does what you can lose | -1, or hours past the schedule | 47 seconds after the test's log backup; -1 for `model`, in full recovery and never backed up |
| `mssql.health.checkdb_age_days` | 0 to 7 | Above 7, or -1 (never): damage could go unseen | | 0 for the test's database, which the test checked; -1 for master, model and msdb |
| `mssql.health.suspect_pages` | 0 | | Any: pages are damaged. Run DBCC CHECKDB and restore what it finds | Not caused: 0 |
| `mssql.health.volume_free_pct` | Above 20 | Below 20 | Below 10: files cannot grow | Not caused: 52.82 to 52.93 |
| `mssql.health.max_size_used_pct`, `express_limit_used_pct` | Below 80 | Above 80 | Above 95: writes fail | Not caused: `max_size_used_pct 0`; the test's servers are Developer edition, not Express |
| `mssql.replication.connected`, `mssql.replication.health` | 1, and `health` 2 | `health` 1 (partly) for a few minutes | `connected` 0 or `health` 0: a replica is gone | `connected 0` and `health 0` for the secondary, stopped; 1 and 2 again once it started |
| `mssql.replication.sync_state`, `suspended` | `sync_state` 2 (synchronous commit) or 1 (asynchronous); `suspended` 0 | A synchronous replica at 1 for a few minutes | `sync_state` 0, or `suspended` 1: that database is not protected | `sync_state 0` with the secondary stopped, 2 again once it caught up; `suspended` stayed 0 |
| `mssql.replication.send_queue_bytes`, `redo_queue_bytes`, `lag_seconds` | Near 0 | Rising for 15 minutes or more: the secondary falls behind | Rising for an hour, or `lag_seconds` past the data you can afford to lose. A secondary that is not connected reads 0: alert on `connected` too | `send_queue_bytes` 61,440 at most and `lag_seconds` 0; with the secondary stopped, the queue read 0 |
| `mssql.activity.requests_blocked`, `head_blockers`, `longest_wait_seconds` | 0 | Above 0 for a few minutes | Still so after 10 minutes, or many requests blocked: one session holds up others, find it | `requests_blocked 1` and `head_blockers 1`, the wait `LCK_M_X` at 9.13 to 19.54 seconds: a session holding a row lock, and another waiting on it |
| `mssql.activity.idle_in_transaction_seconds`, `oldest_transaction_seconds` | Seconds | Minutes: it holds locks and keeps the log from being reused | An hour or more, or with `log_used_pct` rising: an application that did not commit | 12 to 19 seconds: the test's session asleep in its open transaction |
| `mssql.performance.deadlocks_count` (as a rate) | 0 | Any | Rising | Not caused on purpose: 0 on every run but 2025's, which counted 1 |
| `mssql.performance.memory_grants_pending`; `mssql.memory.process_low`, `system_low` | 0 | `memory_grants_pending` above 0 for a few minutes | `process_low` or `system_low` 1, or `memory_grants_pending` above 0 for 15 minutes: queries wait for memory | Not caused: 0 |
| `mssql.cpu.work_queued`, `workers_pct` | 0, and below 70 | `workers_pct` above 70 | `work_queued` above 0 for a few minutes, or `workers_pct` above 90: new queries cannot start | Not caused: `work_queued` 0, `workers_pct` 13.67 to 34.38 |
| `mssql.agent.failed_24h`, `job_failed_24h`, `readable` | `failed_24h` 0; `readable` 1 | `readable` 0: the login cannot read Agent's jobs, so failures go unseen | `failed_24h` above 0: see which in `job_failed_24h` | `failed_24h 1` and `job_failed_24h 1 job=vigil_it_failing`, the job the test made to fail; `readable 0` before the test gave its grants |
| `mssql.config.xp_cmdshell`, `clr_enabled`, `ole_automation`, `sa_enabled`, `sysadmins`; `mssql.connections.connections` with `encrypted=no` | 0; `sysadmins` steady | Any 1 where nothing needs it, `sysadmins` growing, or any of them changing when no one meant to: a risk to decide on, not an outage | | `sa_enabled 1` and `sysadmins 1`: the containers' own `sa`, which the test sets them up with; the rest 0 |

## How it was tested

**Tested** on 2026-11-20 on the Fedora 44 test machine, against **SQL Server 2019 (CU32), 2022 (CU28) and 2025 (CU11)**, Developer edition in Docker, TLS only with a certificate from a test CA (`compose.mssql.yaml`), by `tests/integration/backends/scripts/run-mssql.sh <image>`: `service-packs.sh` through Vigil with the Go `sqlcmd` 1.10.0, **79 passed, 0 failed** on 2019 and on 2025, each the primary of a read-scale availability group whose secondary was then stopped and started, and **71 passed, 0 failed** on 2022 alone. On 2022 CU28 the secondary would not join an availability group in Docker on that machine (the join timed out while the secondary held a CPU), where 2019 and 2025, set up the same way, did; the replication job asks the same of all three. Every job, against 2022, printed the same lines with Microsoft's `sqlcmd` 18.7 as with the Go one. The full console output: [2019](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-mssql-2019-replication/console.txt), [2022](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-mssql-2022/console.txt), [2025](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-mssql-2025-replication/console.txt). **On Windows**, every job on Windows PowerShell 5.1 and PowerShell 7 against SQL Server 2022 on the Fedora machine, printing the same lines as the Linux scripts, then `Service-Packs.ps1` through Vigil itself, **53 passed, 0 failed** on each: [the console output](../../tests/integration/backends/reports/runs/2026-11-20/windows/pack-mssql-windows/console.txt). **On macOS**, on the Intel Mac test machine under its bash 3.2, with the Go `sqlcmd` 1.10.0 and the test CA in the System keychain: every job directly, then `service-packs.sh` through Vigil, **69 passed, 0 failed**, against SQL Server 2022 on the Fedora machine: [the console output](../../tests/integration/backends/reports/runs/2026-11-20/macos/pack-mssql-macos/console.txt). In CI, the same test runs against SQL Server 2022, TLS only, on every change to Vigil itself. Lines from SQL Server 2025, with one session asleep in its open transaction and another blocked behind it:

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

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
