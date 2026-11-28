# The oracle pack

Oracle Database 19c, 21c and 23ai, a container database (CDB) with its pluggable databases or a database that is not a CDB, on this machine or any it can reach. The pack reads whether the database answers and is open, and if not, why not; what it is; its sessions and processes against their limits; each PDB, open or not. Its workload, from the instance's own counters. What its sessions are doing now: blocked, at the head of a blocking chain, asleep with a transaction open. Where its time goes waiting. Every tablespace in every container, against the most it can grow to. The fast recovery area, the archiver and the redo logs. Its memory, and the PGA against the limit past which Oracle ends sessions. RMAN's backups and what failed. Invalid objects, corrupt blocks, files offline, accounts about to expire, Scheduler jobs that failed. And the alert log's last five minutes. Linux, macOS and Windows.

Oracle's trouble often arrives quietly. A tablespace fills until an insert fails with ORA-01653. A recovery area fills in ARCHIVELOG mode and the archiver stops, and with it every change. A session updates a row, goes to lunch with its transaction open, and everyone after it waits. A nightly RMAN job fails and nobody reads its log for a week. An ORA-00600 lands in the alert log at 3 a.m. Each of these is in what the database says about itself, and the pack reads it.

**It only reads, and never needs a paid option.** It logs in as a user with `CREATE SESSION` and `SELECT_CATALOG_ROLE`, Oracle's own read-only role for the data dictionary and the dynamic performance views; it reads none of the application's tables. It uses only Oracle's basic views (`V$SYSSTAT`, `V$SESSION`, `V$SYSTEM_WAIT_CLASS`, the `CDB_` dictionary views and the like): **nothing from the Diagnostics or Tuning Pack**, so no ASH, no AWR, no `V$SYSMETRIC`, and running it never makes a database owe Oracle a license.

**SQL*Plus, and the password never on a command line.** Each job hands one query to SQL*Plus, from Oracle Instant Client, the same query on Linux, macOS and Windows. The password goes to SQL*Plus on its standard input, never on its command line, where any account on the machine could see it. **Oracle Net's encryption and integrity checks are required**, by settings of the job's own (it never reads the machine's `sqlnet.ora`): a server that refuses them refuses the job, and the run says so.

1. **A read-only user**, once, as SYSDBA, in the CDB root. A common user, so it sees every PDB, with `CONTAINER_DATA=ALL` so the views show every container's rows:

   ```sql
   CREATE USER C##VIGIL_MONITOR IDENTIFIED BY "..." CONTAINER=ALL;
   GRANT CREATE SESSION, SELECT_CATALOG_ROLE TO C##VIGIL_MONITOR CONTAINER=ALL;
   ALTER USER C##VIGIL_MONITOR SET CONTAINER_DATA=ALL CONTAINER=CURRENT;
   -- For oracle_alerts: the alert log is not in SELECT_CATALOG_ROLE.
   GRANT SELECT ON SYS.V_$DIAG_ALERT_EXT TO C##VIGIL_MONITOR CONTAINER=ALL;
   ```

   In a database that is not a CDB (19c and before), the same without the `C##`, `CONTAINER=` and `CONTAINER_DATA`: `CREATE USER VIGIL_MONITOR ...`, and the jobs' `ORACLE_USER=VIGIL_MONITOR`.

2. **SQL*Plus** on the Vigil machine: [Oracle Instant Client](https://www.oracle.com/database/technologies/instant-client/downloads.html), its **Basic** (or Basic Light) and **SQL*Plus** packages, a free download with no account. Unzip both into one folder, and put it on the PATH of the account Vigil runs as, or set the jobs' `ORACLE_SQLPLUS` to its `sqlplus`. On Linux the scripts find Instant Client's libraries in its own folder themselves; it needs `libaio` (Fedora's and RHEL's `libaio`, Debian's and Ubuntu's `libaio1t64` or `libaio1`). **On an Intel Mac**, 19.16 is the last Instant Client, and it reads 23ai as well. **On Windows**, Instant Client needs the Microsoft Visual C++ Redistributable most machines already have.

3. `vigil pack enable oracle`, then in `vigil.config` set the jobs' `ORACLE_SERVICE` to the service of the CDB root (or of the database, if it is not a CDB), and the host and port:

   ```ini
   env = ORACLE_HOST=db1.example.com
   env = ORACLE_PORT=1521
   env = ORACLE_SERVICE=ORCLCDB
   ```

   and the password as a secret:

   ```sh
   vigil secret set ORACLE_MONITOR_PASSWORD
   ```

**The CDB root, not a PDB.** Connected to the root, the pack sees the instance and every PDB: each tablespace, each invalid object, each failed Scheduler job is tagged with its PDB (`pdb=`). Connected to a PDB, it would see that PDB alone.

**A wrong password fails the run, saying so** (ORA-01017), and so does a query Oracle refuses. A database that does not answer is a reading, `up 0`, with the reason: `no_listener` (nothing listens on the port), `service_unknown` (the listener knows no such service: a wrong `ORACLE_SERVICE`, or the database is down), `not_open` (mounted, or starting or stopping), `restricted` (logins restricted to DBAs), `timeout` or `unreachable`. The run succeeds. Without the alert log's grant, `oracle_alerts` reports `readable 0`, and the rest run as before.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `bash`, SQL*Plus (Instant Client Basic and SQL*Plus), `libaio` | `bash`, SQL*Plus (Instant Client 19.16 on Intel) | PowerShell 5.1 or 7, SQL*Plus (Instant Client) |
| Oracle Database | 19c, 21c or 23ai (any edition), reachable from the Vigil machine, Oracle Net's encryption not rejected | | |
| A user | `CREATE SESSION`, `SELECT_CATALOG_ROLE`, `CONTAINER_DATA=ALL`; and `SELECT` on `V_$DIAG_ALERT_EXT` for the alert log | | |
| A secret | `ORACLE_MONITOR_PASSWORD` | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `oracle_status` | Whether it answers (and if not, why not), its release, version, edition and role, open or not and how, uptime, ARCHIVELOG mode, CPUs, sessions and processes against their limits, each PDB open or not | minute |
| `oracle_performance` | The instance's own counters: executions, calls, commits and rollbacks, logons, parses (hard, failed), reads and writes, redo, network, disk sorts, long scans, deadlocks, lock timeouts; time in the database and on CPU; the machine's CPU; the buffer cache's hit ratio | minute |
| `oracle_activity` | User sessions by state, the active ones on CPU or by their wait's class, sessions blocked and at the head of a chain, the longest call, transactions and the oldest, sessions idle with a transaction open, long operations | minute |
| `oracle_waits` | Time waited by wait class, and the ten most costly wait events | 5 minutes |
| `oracle_tablespaces` | Every tablespace in every container (the 100 fullest) against the most it can grow to, autoextend counted, and online or not; data files against `db_files` | 5 minutes |
| `oracle_recovery` | The fast recovery area: its limit, what it holds, what could be freed, how full; Flashback Database; archive destinations in error; log switches in the last hour; redo groups active and not yet archived | 5 minutes |
| `oracle_memory` | The SGA and its targets, the buffer cache, the shared pool and its free memory; the PGA allocated and in use against its target and its hard limit, and how often the target was not enough | 5 minutes |
| `oracle_backups` | From RMAN's record in the control file: how long since the last full, incremental and archived log backup; RMAN jobs failed in 24 hours and running; the last backup's size and time | 15 minutes |
| `oracle_health` | Invalid objects in each PDB, corrupt blocks, data files needing recovery or offline, accounts expiring within 7 days, Scheduler jobs failed in 24 hours (by name) and broken | 15 minutes |
| `oracle_alerts` | The alert log's last 5 minutes: lines with an ORA- code, incidents (ORA-00600 and the like), each code and how often, "Checkpoint not complete" | 5 minutes |

Running totals (`_count`) restart when the instance restarts: graph them as a rate.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `oracle.up`.

```text
+--------------------------------------------------------------------------------------------------+
| oracle_status   oracle.<metric>   every 1m                                                       |
+----------------+---------------------------------------------------------------------------------+
| up             | 1 when it answers; else 0, tagged reason=<no_listener, service_unknown,         |
|                | not_open, restricted (logins restricted to DBAs), timeout or unreachable>       |
| info           | always 1, tagged release=<19, 21 or 23>, version=<its full version>,            |
|                | edition=<ee, se, xe, free>, cdb=<yes or no> and role=<primary, physical_standby |
|                | and the like>                                                                   |
| uptime_seconds | how long the instance has run                                                   |
| open           | 1 when the instance is open, tagged mode=<read_write, read_only, mounted>       |
| archivelog     | 1 in ARCHIVELOG mode                                                            |
| cpus           | the CPUs it sees                                                                |
| sessions       | sessions now                                                                    |
| sessions_max   | the most it allows (the sessions parameter)                                     |
| sessions_pct   | sessions, as a percent of the most                                              |
| processes      | processes now                                                                   |
| processes_max  | the most it allows (the processes parameter)                                    |
| processes_pct  | processes, as a percent of the most                                             |
| pdbs           | pluggable databases, the seed left out                                          |
| pdb_open       | 1 when open, tagged pdb= and mode=                                              |
+----------------+---------------------------------------------------------------------------------+
| GOOD  up 1; open 1 with mode=read_write (a primary); pdb_open 1 for each PDB.                    |
| WATCH sessions_pct or processes_pct above 80; uptime_seconds back near 0: it restarted.          |
| BAD   up 0; pdb_open 0 for a PDB that should be open; processes_pct near 100: new connections    |
|       are refused (ORA-00020); up 0 with reason=restricted when no one is doing maintenance.     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| oracle_performance   oracle.performance.<metric>   every 1m                                      |
+------------------------+-------------------------------------------------------------------------+
| executions_count       | SQL statements executed (a running total)                               |
| user_calls_count       | calls from clients (a running total)                                    |
| commits_count          | commits (a running total)                                               |
| rollbacks_count        | rollbacks (a running total)                                             |
| logons_count           | logons (a running total)                                                |
| logons_current         | sessions logged on now                                                  |
| parses_count           | statements parsed (a running total)                                     |
| hard_parses_count      | parsed from scratch, with no shared cursor (a running total)            |
| parse_failures_count   | parses that failed (a running total)                                    |
| logical_reads_count    | blocks read, from memory or disk (a running total)                      |
| physical_reads_count   | blocks read from disk (a running total)                                 |
| physical_writes_count  | blocks written to disk (a running total)                                |
| redo_bytes_count       | redo generated (a running total)                                        |
| bytes_received_count   | bytes from clients (a running total)                                    |
| bytes_sent_count       | bytes to clients (a running total)                                      |
| disk_sorts_count       | sorts too big for memory (a running total)                              |
| long_table_scans_count | whole scans of large tables (a running total)                           |
| deadlocks_count        | deadlocks (a running total)                                             |
| lock_timeouts_count    | lock requests that timed out (a running total)                          |
| open_cursors           | cursors open now                                                        |
| db_time_ms_count       | time sessions spent in the database, waiting or working, in ms (a       |
|                        | running total)                                                          |
| db_cpu_ms_count        | of that, on CPU (a running total)                                       |
| host_busy_ms_count     | the machine's CPUs busy, summed, in ms (a running total)                |
| host_idle_ms_count     | and idle (a running total)                                              |
| buffer_cache_hit_pct   | blocks found in memory, as a percent, since the instance started        |
+------------------------+-------------------------------------------------------------------------+
| GOOD  db_time_ms_count's rate steady with the workload; deadlocks_count flat.                    |
| WATCH hard_parses_count close to parses_count: statements are not shared (literals, not bind     |
|       variables); db_cpu_ms_count's rate a small share of db_time's: sessions mostly wait        |
|       (oracle_waits says on what).                                                               |
| BAD   deadlocks_count rising; db_time_ms_count's rate far above its usual. The _count totals     |
|       restart with the instance: graph them as a rate.                                           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| oracle_activity   oracle.activity.<metric>   every 1m                                            |
+-----------------------------+--------------------------------------------------------------------+
| sessions                    | user sessions, tagged state=<active, inactive, killed and the      |
|                             | like>                                                              |
| active                      | active ones, tagged class=<cpu, or the class of their wait:        |
|                             | user_i_o, concurrency, application...>                             |
| blocked                     | sessions waiting on another                                        |
| longest_blocked_seconds     | how long the longest of them has waited                            |
| head_blockers               | sessions that block others and wait on no one                      |
| longest_active_seconds      | how long the longest call running has run                          |
| transactions                | transactions open                                                  |
| oldest_transaction_seconds  | how long the oldest has been open                                  |
| idle_in_transaction         | sessions asleep with a transaction open                            |
| idle_in_transaction_seconds | how long the longest of them has slept                             |
| long_operations             | long operations (scans, sorts, backups) still running              |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  blocked and head_blockers 0; idle_in_transaction 0.                                        |
| WATCH oldest_transaction_seconds in minutes: it holds locks and undo; longest_active_seconds     |
|       growing past what the application runs.                                                    |
| BAD   head_blockers above 0 for minutes: one session holds up others, find it (V$SESSION's       |
|       BLOCKING_SESSION); idle_in_transaction above 0 for long: an application that did not       |
|       commit.                                                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| oracle_waits   oracle.waits.<metric>   cron 1/5 * * * *                                          |
+-------------------+------------------------------------------------------------------------------+
| wait_ms_count     | milliseconds waited, tagged class=<user_i_o, system_i_o, commit,             |
|                   | concurrency, application, configuration, network, scheduler, cluster,        |
|                   | other...> (a running total)                                                  |
| waits_count       | waits (a running total)                                                      |
| top_wait_ms_count | milliseconds waited on one of the ten most costly events, tagged event= (a   |
|                   | running total)                                                               |
| top_waits_count   | waits on that event (a running total)                                        |
+-------------------+------------------------------------------------------------------------------+
| GOOD  each class's rate steady with the workload.                                                |
| WATCH user_i_o rising: reads from disk (the data does not fit in the buffer cache, or the disk   |
|       is slow); commit rising: the redo log's disk is slow (log file sync); concurrency: latches |
|       and buffer contention.                                                                     |
| BAD   application rising: row locks (enq: TX - row lock contention): blocking, see               |
|       oracle_activity; configuration rising: log switches waiting or space (oracle_recovery).    |
|       The totals restart with the instance: graph them as a rate.                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| oracle_tablespaces   oracle.tablespace.<metric>   cron 2/5 * * * *                               |
+---------------+----------------------------------------------------------------------------------+
| tablespaces   | tablespaces, every container                                                     |
| used_pct      | used, as a percent of the most it can grow to, tagged pdb=, tablespace= and      |
|               | kind=<permanent, undo or temporary>                                              |
| used_bytes    | used                                                                             |
| max_bytes     | the most it can grow to                                                          |
| online        | 1 when online                                                                    |
| datafiles     | data files                                                                       |
| datafiles_max | the most allowed (db_files)                                                      |
| ..._not_shown | past 100 of a list (tablespaces), how many were left out                         |
+---------------+----------------------------------------------------------------------------------+
| GOOD  used_pct below 80 for permanent tablespaces; online 1.                                     |
| WATCH used_pct above 85, or rising steadily; datafiles near datafiles_max.                       |
| BAD   used_pct above 95: inserts fail with ORA-01653 or ORA-01654 (unable to extend); online 0   |
|       for a tablespace in use. Undo and temporary tablespaces fill and empty with the workload.  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| oracle_recovery   oracle.recovery.<metric>   cron 3/5 * * * *                                    |
+--------------------------+-----------------------------------------------------------------------+
| fra_limit_bytes          | the fast recovery area's limit (db_recovery_file_dest_size); 0 with   |
|                          | none                                                                  |
| fra_used_bytes           | what it holds                                                         |
| fra_reclaimable_bytes    | what could be deleted (backed up, or obsolete)                        |
| fra_used_pct             | used and not reclaimable, as a percent of the limit                   |
| flashback_on             | 1 when Flashback Database is on                                       |
| archive_dest_errors      | archive destinations in error                                         |
| archive_dest_error       | one of them: 1, tagged dest=                                          |
| log_switches_1h          | redo log switches in the last hour                                    |
| redo_groups              | redo log groups                                                       |
| redo_group_bytes         | the size of the largest                                               |
| redo_groups_active       | groups still needed for crash recovery (their checkpoint is not done) |
| redo_groups_not_archived | in ARCHIVELOG mode, groups switched out and not yet archived          |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  fra_used_pct below 80; archive_dest_errors 0; log_switches_1h a few (Oracle suggests about |
|       four an hour).                                                                             |
| WATCH fra_used_pct above 80; log_switches_1h in the dozens: the redo logs are small for the      |
|       load; redo_groups_not_archived above 0 for more than a switch or two.                      |
| BAD   fra_used_pct near 100 in ARCHIVELOG mode: the archiver stops and so does every change      |
|       (ORA-00257); archive_dest_errors above 0.                                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| oracle_memory   oracle.memory.<metric>   cron 4/5 * * * *                                        |
+----------------------------+---------------------------------------------------------------------+
| sga_bytes                  | the SGA                                                             |
| sga_target_bytes           | sga_target (0: not set)                                             |
| memory_target_bytes        | memory_target (0: not set)                                          |
| buffer_cache_bytes         | the buffer cache                                                    |
| shared_pool_bytes          | the shared pool                                                     |
| shared_pool_free_bytes     | free in it                                                          |
| pga_allocated_bytes        | PGA allocated                                                       |
| pga_inuse_bytes            | PGA in use                                                          |
| pga_target_bytes           | pga_aggregate_target                                                |
| pga_limit_bytes            | pga_aggregate_limit                                                 |
| pga_limit_pct              | PGA allocated, as a percent of the limit                            |
| pga_over_allocations_count | times the PGA had to go past its target (a running total)           |
+----------------------------+---------------------------------------------------------------------+
| GOOD  pga_limit_pct below 70; pga_over_allocations_count flat.                                   |
| WATCH pga_over_allocations_count rising: pga_aggregate_target is too small;                      |
|       shared_pool_free_bytes falling toward 0 with hard parses rising.                           |
| BAD   pga_limit_pct near 100: Oracle ends the sessions using the most PGA (ORA-04036);           |
|       shared_pool_free_bytes near 0 with ORA-04031 in the alert log.                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| oracle_backups   oracle.backups.<metric>   cron 12/15 * * * *                                    |
+-------------------------+------------------------------------------------------------------------+
| full_age_seconds        | since the last full backup completed; -1 none                          |
| incremental_age_seconds | since the last incremental backup; -1 none                             |
| archivelog_age_seconds  | since the last archived log backup; -1 none                            |
| failed_24h              | RMAN jobs that failed, or completed with errors, in the last 24 hours  |
| running                 | RMAN jobs running now                                                  |
| last_bytes              | the last database backup's size                                        |
| last_seconds            | how long it took                                                       |
+-------------------------+------------------------------------------------------------------------+
| GOOD  full_age_seconds (or incremental_age_seconds, with incremental level 0 and 1) within your  |
|       schedule; archivelog_age_seconds within an hour or so; failed_24h 0.                       |
| WATCH ages growing past the schedule; last_seconds growing night after night.                    |
| BAD   failed_24h above 0; full_age_seconds and incremental_age_seconds both -1: there is no      |
|       backup RMAN knows of.                                                                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| oracle_health   oracle.health.<metric>   cron 8/15 * * * *                                       |
+-------------------------+------------------------------------------------------------------------+
| invalid_objects         | invalid objects, tagged pdb=                                           |
| corrupt_blocks          | blocks known to be corrupt (V$DATABASE_BLOCK_CORRUPTION: found by RMAN |
|                         | or by a read)                                                          |
| datafiles_need_recovery | data files that need media recovery                                    |
| datafiles_offline       | data files not online                                                  |
| accounts_expiring       | open accounts, not Oracle's own, whose password expires within 7 days  |
|                         | or is in its grace period                                              |
| scheduler_failed_24h    | Scheduler job runs that failed in the last 24 hours                    |
| job_failed_24h          | a job that failed in them: its failures, tagged pdb= and               |
|                         | job=<owner.name> (the 10 with the most)                                |
| scheduler_broken        | Scheduler jobs broken (stopped after failing too often)                |
+-------------------------+------------------------------------------------------------------------+
| GOOD  corrupt_blocks 0; datafiles_need_recovery and datafiles_offline 0; scheduler_failed_24h 0. |
| WATCH invalid_objects growing after a deployment; accounts_expiring above 0: an application's    |
|       login about to lock it out.                                                                |
| BAD   corrupt_blocks above 0: run RMAN VALIDATE and recover the blocks; datafiles_need_recovery  |
|       above 0; scheduler_broken above 0.                                                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| oracle_alerts   oracle.alerts.<metric>   cron 0/5 * * * *                                        |
+-------------------------+------------------------------------------------------------------------+
| readable                | 1 when this user may read the alert log, else 0                        |
| errors                  | lines with an ORA- code in the last 5 minutes                          |
| incidents               | of them, critical errors with an incident (ORA-00600, ORA-07445 and    |
|                         | the like)                                                              |
| error_count             | of them, by code, tagged code=<ORA- and five digits>                   |
| checkpoint_not_complete | "Checkpoint not complete" in the last 5 minutes: changes waited for a  |
|                         | redo log                                                               |
+-------------------------+------------------------------------------------------------------------+
| GOOD  readable 1; errors 0; incidents 0.                                                         |
| WATCH errors above 0: read them in the alert log; checkpoint_not_complete above 0: the redo logs |
|       are too small or too few.                                                                  |
| BAD   incidents above 0: an ORA-00600 or ORA-07445, open a service request; error_count with     |
|       code=ORA-01653, ORA-01654 or ORA-01688 (unable to extend), ORA-00257 (archiver stuck),     |
|       ORA-04031 (shared pool) or ORA-00060 (deadlock).                                           |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what a 23ai database in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `oracle.up` | 1 | | 0 for more than a few minutes: read its `reason` | 1; `up 0 reason=no_listener` for a port nothing listened on, `service_unknown` for a service the listener did not know and for the database shut down, `not_open` mounted, `restricted` with logins restricted: the run succeeding each time |
| `oracle.pdb_open` (by `pdb`) | 1 | | 0 for a PDB that should be open | 1; `0 ... mode=mounted` with the PDB closed, the CDB still `up 1` |
| `oracle.sessions_pct`, `processes_pct` | Below 70 | Past 80 | Past 95: new connections refused (ORA-00020) | 39.75 and 49.5 on 23ai Free |
| `oracle.activity.head_blockers`, `blocked` | 0 | Above 0 | Above 0 for minutes: find the head of the chain | 1 and 1: one session holding a row, another waiting for it (`active 1 class=application`, `longest_blocked_seconds 20.58`) |
| `oracle.activity.idle_in_transaction`, `oldest_transaction_seconds` | 0; seconds | A transaction open for minutes | Idle in a transaction for long: an application that did not commit | 1, 23 s idle (the oldest transaction 24 s): the session holding the row |
| `oracle.tablespace.used_pct` (by `pdb`, `tablespace`) | Below 80 | Past 85 | Past 95 (permanent): inserts fail with ORA-01653 or ORA-01654 | 90.63 for a 10 MB tablespace filled until an insert failed with ORA-01653 |
| `oracle.recovery.fra_used_pct` | Below 80 | Past 80 | Past 95 in ARCHIVELOG mode: the archiver stops, and so does every change (ORA-00257) | 89.98 with the area shrunk on purpose; Oracle's own warning, ORA-19815, in the alert log |
| `oracle.recovery.archive_dest_errors` | 0 | | Above 0 | 0 |
| `oracle.recovery.log_switches_1h` | A few an hour | Dozens: the redo logs are small for the load | | 6, switched on purpose, and 6 "Checkpoint not complete" in the alert log with them |
| `oracle.memory.pga_limit_pct` | Below 70 | Past 80 | Near 100: Oracle ends the sessions using the most PGA (ORA-04036) | 19.08 |
| `oracle.backups.full_age_seconds`, `archivelog_age_seconds` | Within your schedule | Past it | -1, or far past it: the backups stopped | 49 and 42 seconds, just after RMAN backed up the database and the archived logs |
| `oracle.backups.failed_24h` | 0 | | Above 0 | 1, a backup sent to a folder that was not there (ORA-19504) |
| `oracle.health.scheduler_failed_24h`, `job_failed_24h` (by `job`) | 0 | | Above 0 | 1, `job=VIGIL_APP.NIGHTLY_LOAD`, a job that raised an error |
| `oracle.health.invalid_objects` (by `pdb`) | Steady | Rising after a deployment | | 1, a view whose table was dropped |
| `oracle.health.accounts_expiring` | 0 | Above 0: a login about to lock an application out | | 1, a password with a 3-day lifetime |
| `oracle.health.corrupt_blocks` | 0 | | Above 0: RMAN VALIDATE, and recover the blocks | Not caused |
| `oracle.alerts.incidents` | 0 | | Above 0: an ORA-00600 or ORA-07445; open a service request | 4: ORA-00800 incidents Oracle Free files at each start in a container |
| `oracle.alerts.error_count` (by `code`) | None | Any | ORA-01653/01654 (space), ORA-00257 (archiver), ORA-04031 (shared pool), ORA-00060 (deadlock) | `code=ORA-01653`, `ORA-00060` (the deadlock made on purpose), `ORA-19815`, `ORA-12012` (the failed job) |
| `oracle.performance.deadlocks_count` | Flat | | Rising | 1, two sessions that deadlocked on purpose |

## How it was tested

<!-- tested:start -->
<!-- tested:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
