"""Writes packs/mssql: pack.config, and each job's script for Linux and macOS
(bash, sqlcmd) and Windows (PowerShell, SqlClient), from the job SQL in
r64sql/ and the documentation below. Every script runs the same query, which
prints finished metric lines, so the platforms agree by construction."""
import os
import sys
import textwrap

repo, sqldir = sys.argv[1], sys.argv[2]
out = os.path.join(repo, 'packs', 'mssql')

NOTICE = [
    'Copyright (c) Bankole Ogundero and the Vigil contributors',
    'SPDX-License-Identifier: Apache-2.0',
    '',
    'Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or',
    'implied. Run it at your own risk: review it first, and test it before you',
    'rely on it. In no event shall the authors or copyright holders be liable',
    'for any claim, damages or other liability arising from its use. See the',
    'LICENSE file for the full terms.',
]

CONNECT_SH = (
    "Connects to MSSQL_HOST and MSSQL_PORT as MSSQL_USER, with the password in "
    "SQLCMDPASSWORD, all set by the job; never on a command line. Always "
    "encrypted, the server's certificate checked against the system's CAs or "
    "MSSQL_CACERT, a CA file, and against the server's name: give MSSQL_HOST "
    "the name on the certificate (Microsoft's sqlcmd does not match an IP "
    "address), or MSSQL_CERT_NAME. Uses sqlcmd: Microsoft's (mssql-tools18) "
    "or the Go one (go-sqlcmd).")
CONNECT_PS = (
    "Connects to MSSQL_HOST and MSSQL_PORT as MSSQL_USER, with the password in "
    "SQLCMDPASSWORD, all set by the job; never on a command line; or, with "
    "MSSQL_AUTH=windows, as the account Vigil runs as, with no password. "
    "Always encrypted, the server's certificate checked against Windows' "
    "trusted CAs and the server's name: put your CA, or the server's own "
    "certificate, in the machine's Trusted Root store. It uses .NET's own SQL "
    "Server client: there is nothing to install.")
READONLY = (
    "One query, read-only, that never waits more than 5 seconds for a lock "
    "and gives way in a deadlock.")

# name, metric_name, schedule, files?, title, what, metrics, example, healthy, watch, act
JOBS = [
    dict(job='status', metric_name='mssql', when='run_every   = 1m', title='a SQL Server\'s health',
         what="Reports whether the server answers and what it is, how long it has run, its CPUs, its "
              "connections against the limit, and whether it is clustered, has Always On, and runs SQL Agent.",
         metrics=[
             ('up', '1 when the server answers, else 0'),
             ('info', 'always 1, tagged release=<2019, 2022 or 2025>, version=<its build>, update=<its CU>, edition=<developer, enterprise, standard, express or web> and os=<linux or windows>'),
             ('uptime_seconds', 'how long it has run'),
             ('cpus', 'the CPUs it sees'),
             ('schedulers', 'the schedulers it runs work on'),
             ('connections', 'user connections now'),
             ('connections_max', 'the most it allows'),
             ('clustered', '1 in a failover cluster instance'),
             ('cluster_node', 'in a failover cluster: always 1, tagged node=<the node it runs on now>'),
             ('hadr_enabled', '1 when Always On availability groups are enabled'),
             ('agent_running', 'SQL Agent: 1 running, 0 stopped; left out where there is none (Express)'),
         ],
         example=['metric up 1', 'metric info 1 release=2022 version=16.0.4325.4 update=CU28 edition=developer os=linux',
                  'metric uptime_seconds 593', 'metric connections 2', 'metric agent_running 0'],
         healthy="up 1; agent_running 1 where Agent runs the backups.",
         watch="connections growing toward connections_max; uptime_seconds back near 0: it restarted.",
         act="up 0; agent_running 0 on a server whose backups Agent schedules; cluster_node changing when no "
             "one moved it: it failed over."),
    dict(job='performance', metric_name='mssql.performance', when='run_every   = 1m', title="a SQL Server's workload counters",
         what="Reports SQL Server's own counters: requests, transactions, compilations, logins, errors, the buffer "
              "pool's page life and hit ratio, I/O, locks and deadlocks, page splits, scans, memory grants, and the "
              "indexes the optimizer wished it had.",
         metrics=[
             ('batch_requests_count', 'requests run (a running total)'),
             ('compilations_count', 'query plans compiled (a running total)'),
             ('recompilations_count', 'plans compiled again (a running total)'),
             ('transactions_count', 'transactions started, all databases (a running total)'),
             ('logins_count', 'logins (a running total)'),
             ('logouts_count', 'logouts (a running total)'),
             ('processes_blocked', 'sessions waiting on another now'),
             ('errors_count', 'errors raised (a running total)'),
             ('page_life_expectancy_seconds', 'how long a page stays in the buffer pool'),
             ('lazy_writes_count', 'pages written to free memory (a running total)'),
             ('checkpoint_pages_count', 'pages written by checkpoints (a running total)'),
             ('page_reads_count', 'pages read from disk (a running total)'),
             ('page_writes_count', 'pages written to disk (a running total)'),
             ('lock_waits_count', 'lock requests that had to wait (a running total)'),
             ('lock_timeouts_count', 'lock requests that gave up (a running total)'),
             ('deadlocks_count', 'deadlocks (a running total)'),
             ('page_splits_count', 'index pages split in two (a running total)'),
             ('full_scans_count', 'whole tables or indexes scanned (a running total)'),
             ('memory_grants_pending', 'queries waiting for memory to run'),
             ('memory_grants_outstanding', 'queries holding memory to run'),
             ('buffer_cache_hit_pct', 'pages found in memory, as a percent'),
             ('missing_indexes', "indexes the optimizer wished for since the server started"),
             ('missing_index_top_impact_pct', 'the most one of them would improve its queries, as a percent'),
         ],
         example=['metric batch_requests_count 569', 'metric page_life_expectancy_seconds 593',
                  'metric deadlocks_count 0', 'metric memory_grants_pending 0', 'metric buffer_cache_hit_pct 100'],
         healthy="memory_grants_pending 0; deadlocks_count flat; page_life_expectancy_seconds steady.",
         watch="page_life_expectancy_seconds falling: memory is short for the data; compilations_count close "
               "to batch_requests_count: plans are not reused; lock_timeouts_count rising.",
         act="memory_grants_pending above 0 for minutes: queries wait for memory; deadlocks_count rising. "
             "The _count totals restart with the server: graph them as a rate."),
    dict(job='activity', metric_name='mssql.activity', when='run_every   = 1m', title='what a SQL Server is doing now',
         what="Reports user sessions by state, requests running and blocked, the sessions at the head of a "
              "blocking chain, the longest request and wait, the oldest open transaction, sessions asleep with a "
              "transaction open, and the longest snapshot transaction. Its own session is left out.",
         metrics=[
             ('sessions', 'user sessions, tagged state=<running, sleeping, dormant or preconnect>'),
             ('requests', 'requests running now'),
             ('requests_blocked', 'requests waiting on another session'),
             ('head_blockers', 'sessions that block others and wait on no one'),
             ('longest_request_seconds', 'how long the longest request has run'),
             ('longest_wait_seconds', 'the longest wait now, tagged type=<its wait type, or none>'),
             ('oldest_transaction_seconds', 'how long the oldest open transaction has been open'),
             ('idle_in_transaction', 'sessions asleep with a transaction open'),
             ('idle_in_transaction_seconds', 'how long the longest of them has slept'),
             ('longest_snapshot_seconds', 'how long the longest snapshot transaction has run'),
         ],
         example=['metric sessions 1 state=sleeping', 'metric requests_blocked 0', 'metric head_blockers 0',
                  'metric longest_wait_seconds 0 type=none', 'metric oldest_transaction_seconds 0'],
         healthy="requests_blocked and head_blockers 0; idle_in_transaction 0.",
         watch="oldest_transaction_seconds in minutes: it holds locks and keeps the log from being reused; "
               "longest_snapshot_seconds growing: tempdb's version store grows with it.",
         act="head_blockers above 0 for minutes: one session holds up others, find it; idle_in_transaction "
             "above 0 for long: an application that did not commit."),
    dict(job='cpu', metric_name='mssql.cpu', when='run_every   = 1m', title="a SQL Server's CPU and threads",
         what="Reports the CPU SQL Server used, from its own minute-by-minute record, and on Windows the rest "
              "of the machine's; tasks ready to run that wait for a CPU or a thread; disk I/O pending on its "
              "schedulers; and its worker threads against the most it may have.",
         metrics=[
             ('sql_pct', 'CPU used by SQL Server, as a percent of the machine'),
             ('other_pct', "CPU used by everything else (Windows only: on Linux SQL Server cannot tell)"),
             ('runnable_tasks', 'tasks ready to run that wait for a CPU'),
             ('work_queued', 'tasks waiting for a worker thread'),
             ('pending_disk_io', 'disk reads and writes not yet done'),
             ('workers', 'worker threads now'),
             ('workers_max', 'the most it may have'),
             ('workers_pct', 'workers as a percent of the most'),
         ],
         example=['metric sql_pct 1', 'metric runnable_tasks 0', 'metric work_queued 0', 'metric workers 72',
                  'metric workers_pct 28.13'],
         healthy="runnable_tasks near 0; work_queued 0; workers_pct below 70.",
         watch="runnable_tasks steadily above the CPUs: CPU pressure; other_pct high: something else on the "
               "machine competes for it.",
         act="work_queued above 0, or workers_pct near 100: new queries cannot start (thread starvation)."),
    dict(job='replication', metric_name='mssql.replication', when='run_every   = 1m', title="a SQL Server's Always On availability groups",
         what="Reports, for each availability group this server is part of, each replica's role, connection "
              "and health, and each database's synchronization and the log waiting to be sent and redone. "
              "A primary sees every replica; a secondary, itself. With no availability group, it prints nothing.",
         metrics=[
             ('primary', '1 for the primary replica, tagged group= and replica='),
             ('connected', '1 when the replica is connected'),
             ('health', "2 healthy, 1 partly, 0 not healthy"),
             ('local', '1 for this server'),
             ('sync_state', "each database: 2 synchronized, 1 synchronizing, 0 neither; tagged group=, replica= and database="),
             ('suspended', '1 when its data movement is suspended'),
             ('send_queue_bytes', 'log not yet sent to the secondary'),
             ('send_rate_bytes', 'log sent a second'),
             ('redo_queue_bytes', 'log received but not yet redone on the secondary'),
             ('redo_rate_bytes', 'log redone a second'),
             ('lag_seconds', 'how far the secondary is behind'),
         ],
         example=['metric primary 1 group=ag1 replica=sql1', 'metric health 2 group=ag1 replica=sql2',
                  'metric sync_state 2 group=ag1 replica=sql2 database=shop', 'metric send_queue_bytes 0 group=ag1 replica=sql2 database=shop',
                  'metric lag_seconds 0 group=ag1 replica=sql2 database=shop'],
         healthy="health 2; connected 1; sync_state 2 (synchronous) or 1 (asynchronous); queues near 0.",
         watch="send_queue_bytes or redo_queue_bytes growing: the secondary falls behind; lag_seconds rising.",
         act="connected 0; health 0; suspended 1: that database is not protected; primary changing when no "
             "one failed it over."),
    dict(job='waits', metric_name='mssql.waits', when='cron        = 1/5 * * * *', title='where a SQL Server spends its time waiting',
         what="Reports the time SQL Server's tasks spent waiting, since it started, by kind, and its ten most "
              "costly wait types. Waits that are idle by design are left out.",
         metrics=[
             ('wait_ms_count', "milliseconds waited, tagged kind=<cpu, disk_read, log_write, lock, latch, memory, network, parallelism, replication, external or other> (a running total)"),
             ('top_wait_ms_count', 'milliseconds waited by one of the ten most costly types, tagged type= (a running total)'),
             ('top_waits_count', 'waits of that type (a running total)'),
         ],
         example=['metric wait_ms_count 1409 kind=disk_read', 'metric wait_ms_count 9655 kind=lock',
                  'metric wait_ms_count 871 kind=log_write', 'metric top_wait_ms_count 8257 type=LCK_M_U',
                  'metric top_waits_count 13 type=LCK_M_U'],
         healthy="each kind's rate steady with the workload.",
         watch="disk_read rising: the data does not fit in memory, or the disk is slow; log_write rising: the "
               "log's disk is slow; lock rising: blocking; network: a client reads its results slowly.",
         act="cpu (signal waits) a large share of the total: the CPUs are saturated. The totals restart with "
             "the server: graph them as a rate, and compare kinds."),
    dict(job='io', metric_name='mssql.io', when='cron        = 2/5 * * * *', title="a SQL Server's reads and writes, file by file", files=True,
         what="Reports each database file's reads, writes, bytes and the time spent waiting on them, since "
              "SQL Server started, and its size. The 120 files that have waited longest.",
         metrics=[
             ('reads_count', 'reads, tagged database=, file= and kind=<data or log> (a running total)'),
             ('writes_count', 'writes (a running total)'),
             ('read_bytes_count', 'bytes read (a running total)'),
             ('written_bytes_count', 'bytes written (a running total)'),
             ('read_stall_ms_count', 'milliseconds spent waiting on reads (a running total)'),
             ('write_stall_ms_count', 'milliseconds spent waiting on writes (a running total)'),
             ('size_bytes', 'the file\'s size on disk'),
             ('files_not_shown', 'files beyond the 120 reported'),
         ],
         example=['metric reads_count 74 database=master file=master kind=data',
                  'metric read_stall_ms_count 124 database=master file=master kind=data',
                  'metric write_stall_ms_count 277 database=master file=mastlog kind=log',
                  'metric size_bytes 4915200 database=master file=master kind=data'],
         healthy="latency (the stall's rate over the reads' or writes') below 10 ms for data, 2 ms for a log.",
         watch="read latency 10 to 20 ms; a log's write latency above 5 ms.",
         act="read latency above 20 ms, or a log's write latency above 10 ms, for long: the disk is the "
             "bottleneck."),
    dict(job='memory', metric_name='mssql.memory', when='cron        = 3/5 * * * *', title="a SQL Server's memory",
         what="Reports the memory SQL Server aims for and holds, the process's and the machine's, the buffer "
              "pool, memory granted to queries, the plan cache and its single-use plans, In-Memory OLTP, the "
              "clerks that hold the most, and whether SQL Server or the machine runs low.",
         metrics=[
             ('target_bytes', 'the memory SQL Server aims for'),
             ('total_bytes', 'the memory it holds'),
             ('process_bytes', 'physical memory the process uses'),
             ('process_low', '1 when SQL Server finds its memory low'),
             ('system_total_bytes', "the machine's (or container's) memory"),
             ('system_available_bytes', 'memory free on it'),
             ('system_low', '1 when the machine signals low memory'),
             ('buffer_pool_bytes', 'data pages held in memory'),
             ('memory_grants_bytes', 'memory granted to running queries'),
             ('plan_cache_bytes', 'cached query plans'),
             ('single_use_plan_bytes', 'ad hoc plans used once only'),
             ('xtp_bytes', 'In-Memory OLTP'),
             ('clerk_bytes', 'the five memory clerks that hold the most, tagged clerk='),
         ],
         example=['metric target_bytes 1033936896', 'metric total_bytes 329564160', 'metric process_low 0',
                  'metric plan_cache_bytes 64167936', 'metric clerk_bytes 50241536 clerk=sqlbufferpool'],
         healthy="total_bytes at target_bytes; process_low and system_low 0.",
         watch="single_use_plan_bytes a large share of plan_cache_bytes: turn on optimize for ad hoc "
               "workloads; system_available_bytes low.",
         act="process_low or system_low 1: SQL Server, or the machine, is short of memory."),
    dict(job='tempdb', metric_name='mssql.tempdb', when='cron        = 4/5 * * * *', title="a SQL Server's tempdb",
         what="Reports tempdb's data size and free space, and what fills it: row versions, temporary tables "
              "and table variables, and SQL Server's own sorts and hashes; its log, and its data files.",
         metrics=[
             ('size_bytes', "tempdb's data files"),
             ('free_bytes', 'space free in them'),
             ('free_pct', 'free as a percent'),
             ('version_store_bytes', 'row versions, for snapshot isolation and online index builds'),
             ('user_objects_bytes', 'temporary tables and table variables'),
             ('internal_objects_bytes', 'sorts, hashes and spools'),
             ('log_used_pct', 'its log in use, as a percent'),
             ('data_files', 'its data files'),
         ],
         example=['metric size_bytes 33554432', 'metric free_bytes 28901376', 'metric free_pct 86.13',
                  'metric version_store_bytes 0', 'metric data_files 4'],
         healthy="free_pct above 20.",
         watch="version_store_bytes growing: a long transaction keeps old row versions (mssql_activity "
               "longest_snapshot_seconds); free_pct below 20.",
         act="free_pct near 0: queries that need tempdb fail."),
    dict(job='connections', metric_name='mssql.connections', when='cron        = 0/5 * * * *', title='how clients connect to a SQL Server',
         what="Reports user connections, encrypted or not and by how they log in, and sessions in each "
              "database: counts only, never a host, a program or a login name.",
         metrics=[
             ('connections', 'connections, tagged encrypted=<yes or no>'),
             ('connections_by_auth', 'connections, tagged auth=<sql, kerberos or ntlm>'),
             ('sessions', 'user sessions in the 50 databases with the most, tagged database='),
         ],
         example=['metric connections 2 encrypted=yes', 'metric connections 0 encrypted=no',
                  'metric connections_by_auth 1 auth=sql', 'metric sessions 1 database=master'],
         healthy="encrypted=no 0 where clients should encrypt.",
         watch="auth=ntlm where Kerberos is expected: a missing SPN, quietly slower and weaker.",
         act="encrypted=no above 0 on a server that must encrypt every connection."),
    dict(job='databases', metric_name='mssql.database', when='cron        = 6/15 * * * *', title="a SQL Server's databases",
         what="Reports each database's state, recovery model, size, its log's size and use and what keeps "
              "the log from being reused, open transactions, compatibility level against the server's, and "
              "Query Store's state. The 75 biggest.",
         metrics=[
             ('databases', 'databases on the server'),
             ('databases_not_shown', 'databases beyond the 75 reported'),
             ('online', '1 when online, tagged database='),
             ('state', "0 online, 1 restoring, 2 recovering, 3 recovery pending, 4 suspect, 5 emergency, 6 offline; tagged state="),
             ('read_only', '1 when read-only'),
             ('recovery', 'always 1, tagged model=<full, bulk_logged or simple>'),
             ('data_bytes', 'its data files'),
             ('log_bytes', 'its log'),
             ('log_used_bytes', 'its log in use'),
             ('log_used_pct', 'its log in use, as a percent'),
             ('log_reuse_waiting', '1 when something keeps the log from being reused, tagged reason=<log_backup, active_transaction, replication and the like, or nothing>'),
             ('active_transactions', 'transactions open in it'),
             ('compatibility_level', 'its compatibility level'),
             ('compatibility_behind', "1 when below the server's own"),
             ('query_store', '0 off, 1 read only (often full), 2 read and write, 3 in error'),
         ],
         example=['metric online 1 database=shop', 'metric recovery 1 database=shop model=full',
                  'metric log_used_pct 11 database=shop', 'metric log_reuse_waiting 0 database=shop reason=nothing',
                  'metric query_store 2 database=shop'],
         healthy="online 1; log_used_pct below 70; log_reuse_waiting 0 or reason=log_backup between log backups.",
         watch="log_used_pct above 70 and rising; query_store 1 where it should record; compatibility_behind 1 "
               "after an upgrade.",
         act="online 0 or state 4 (suspect); log_used_pct near 100: writes stop when the log cannot grow; "
             "log_reuse_waiting with reason=active_transaction for long."),
    dict(job='health', metric_name='mssql.health', when='cron        = 8/15 * * * *', title="what keeps a SQL Server's databases safe", files=True,
         what="Reports each database's days since its last good integrity check (DBCC CHECKDB) and its "
              "virtual log files; files growing by a percentage, and those near their maximum size; free "
              "space on each volume that holds a database file; Express edition's 10 GB limit; encryption "
              "(TDE); and pages SQL Server found damaged.",
         metrics=[
             ('checkdb_age_days', 'days since the last DBCC CHECKDB that found nothing, tagged database=; -1 never'),
             ('vlfs', 'virtual log files in its log'),
             ('pct_growth_files', 'files that grow by a percentage'),
             ('max_size_used_pct', 'a file with a maximum size: how much of it is used, tagged database=, file= and kind='),
             ('volume_total_bytes', 'a volume with database files, tagged volume='),
             ('volume_free_bytes', 'space free on it'),
             ('volume_free_pct', 'free as a percent'),
             ('express_limit_used_pct', "Express edition: a database's data against its 10 GB limit"),
             ('encryption_state', 'with transparent data encryption: 3 encrypted, 2 encrypting, 4 changing its key, 5 decrypting, 1 not yet'),
             ('suspect_pages', 'pages found damaged (bad checksum, torn page, I/O error) and not yet repaired'),
         ],
         example=['metric checkdb_age_days 3 database=shop', 'metric vlfs 4 database=shop',
                  'metric volume_free_pct 55.26 volume=/var/opt/mssql/', 'metric suspect_pages 0'],
         healthy="checkdb_age_days 0 to 7; suspect_pages 0; volume_free_pct above 20.",
         watch="checkdb_age_days above 7, or -1; vlfs in the thousands; pct_growth_files above 0.",
         act="suspect_pages above 0: run DBCC CHECKDB and restore what it finds; max_size_used_pct or "
             "express_limit_used_pct near 100: writes fail; volume_free_pct below 10."),
    dict(job='config', metric_name='mssql.config', when='cron        = 10/15 * * * *', title="a SQL Server's risky settings",
         what="Reports settings that are risky or rarely suit at their default, as numbers to compare across "
              "servers and watch for change: memory, parallelism, features that run code outside SQL Server, "
              "the sa login and sysadmin logins, instant file initialization and locked pages.",
         metrics=[
             ('max_server_memory_mb', "max server memory"),
             ('max_server_memory_default', '1 when left at its default, so SQL Server may take the machine\'s memory'),
             ('maxdop', 'max degree of parallelism (0: all CPUs)'),
             ('cost_threshold', 'cost threshold for parallelism'),
             ('optimize_for_ad_hoc', '1 when optimize for ad hoc workloads is on'),
             ('xp_cmdshell', '1 when xp_cmdshell is on'),
             ('clr_enabled', '1 when CLR is on'),
             ('ole_automation', '1 when OLE Automation Procedures are on'),
             ('remote_admin_connections', '1 when the dedicated admin connection takes remote clients'),
             ('sa_enabled', '1 when the sa login is enabled'),
             ('sysadmins', 'enabled logins in the sysadmin role'),
             ('instant_file_init', '1 when instant file initialization is on (Windows)'),
             ('locked_pages', '1 when its memory is locked in place'),
         ],
         example=['metric max_server_memory_default 1', 'metric maxdop 0', 'metric cost_threshold 5',
                  'metric xp_cmdshell 0', 'metric sa_enabled 1'],
         healthy="max_server_memory_default 0; xp_cmdshell, clr_enabled and ole_automation 0 unless needed.",
         watch="cost_threshold 5 (the default) on a busy server; sysadmins growing.",
         act="xp_cmdshell 1 where nothing needs it; sa_enabled 1 with a weak password; any of them changing "
             "when no one meant to."),
    dict(job='backups', metric_name='mssql.backups', when='cron        = 12/15 * * * *', title="how long since a SQL Server's databases were backed up",
         what="Reports, from msdb's history, how long since each database's last full and differential "
              "backup, and for a database whose log needs backing up (full or bulk-logged recovery), its log; "
              "and how many databases have no full backup in 400 days.",
         metrics=[
             ('full_age_seconds', 'since the last full backup, tagged database=; -1 none in 400 days'),
             ('diff_age_seconds', 'since the last differential backup; -1 none'),
             ('log_age_seconds', 'since the last log backup (full or bulk-logged recovery); -1 none'),
             ('never_backed_up', 'databases with no full backup in 400 days'),
         ],
         example=['metric full_age_seconds 86210 database=shop', 'metric diff_age_seconds -1 database=shop',
                  'metric log_age_seconds 912 database=shop', 'metric never_backed_up 0'],
         healthy="full_age_seconds within your schedule (a day or a week); log_age_seconds within minutes "
                 "to an hour.",
         watch="log_age_seconds growing past your schedule: the log grows and the data you can lose with it.",
         act="never_backed_up above 0; full_age_seconds -1 or far past the schedule: the backups stopped."),
    dict(job='agent', metric_name='mssql.agent', when='cron        = 14/15 * * * *', title="a SQL Server's Agent jobs",
         what="Reports SQL Agent's jobs, from msdb: how many there are, those that failed in the last 24 "
              "hours, those running now and how long the longest has run. Reading them needs msdb's "
              "SQLAgentReaderRole: without it, readable 0 and nothing else.",
         metrics=[
             ('readable', '1 when this login may read Agent\'s jobs, else 0'),
             ('jobs', 'Agent jobs'),
             ('jobs_enabled', 'those enabled'),
             ('failed_24h', 'job runs that failed in the last 24 hours'),
             ('job_failed_24h', 'a job that failed in them: its failures, tagged job='),
             ('running', 'jobs running now'),
             ('longest_running_seconds', 'how long the longest has run'),
         ],
         example=['metric readable 1', 'metric jobs 6', 'metric failed_24h 1',
                  'metric job_failed_24h 1 job=nightly_index_maintenance', 'metric running 0'],
         healthy="readable 1; failed_24h 0.",
         watch="longest_running_seconds longer than the job usually takes.",
         act="failed_24h above 0: see which in job_failed_24h; readable 0: grant the role (packs/README.md)."),
]


def wrap(text, width, first='', rest=''):
    return textwrap.wrap(text, width, initial_indent=first, subsequent_indent=rest, break_on_hyphens=False) or [first]


def metrics_doc(metrics, indent):
    w = max(len(n) for n, _ in metrics) + 2
    lines = []
    for n, d in metrics:
        lines += wrap(d, 78 - len(indent), first=(indent + '  ' + n).ljust(len(indent) + 2 + w), rest=' ' * (len(indent) + 2 + w))
    return lines


def doc(j, ps):
    """The header's text, as lines without a comment marker."""
    c = []
    c += wrap(j['what'] + ' ' + READONLY, 74)
    c += ['']
    c += wrap(CONNECT_PS if ps else CONNECT_SH, 74)
    c += ['', 'Metrics:']
    c += metrics_doc(j['metrics'], '')
    c += ['', 'Example output (the rest are in the same form):']
    c += ['  ' + e for e in j['example']]
    c += ['', 'Reading the results (starting points: tune them to the server):']
    c += wrap(j['healthy'], 74, first='  Healthy  ', rest=' ' * 11)
    c += wrap(j['watch'], 74, first='  Watch    ', rest=' ' * 11)
    c += wrap(j['act'], 74, first='  Act      ', rest=' ' * 11)
    c += ['']
    if ps:
        c += ['Requires: Windows PowerShell 5.1 or PowerShell 7, and a login with what',
              '  packs/README.md says to grant']
    else:
        c += ['Requires: bash, sqlcmd (mssql-tools18 or go-sqlcmd), and a login with what',
              '  packs/README.md says to grant']
    first = ('Exit code: 0 on success, server up or down; 1 if' if j['job'] == 'status'
             else 'Exit code: 0 on success, or when the server does not answer; 1 if')
    why = 'the server refuses the login, its certificate or the query' + ('' if ps else ', or sqlcmd is missing')
    c += wrap(first + ' ' + why, 74, rest='  ')
    return c


def sql_for(j):
    parts = ['_head.sql'] + (['_files.sql'] if j.get('files') else []) + [j['job'] + '.sql', '_foot.sql']
    text = ''.join(open(os.path.join(sqldir, p), encoding='utf-8').read() for p in parts)
    # Nothing that would end the bash heredoc or the PowerShell here-string.
    assert not any(l == 'SQL' or l.startswith("'@") for l in text.split('\n')) and '\t' not in text
    return text.rstrip('\n') + '\n'


SH_BODY = r'''set -u

me=@JOB@
client=$(command -v sqlcmd) || client=/opt/mssql-tools18/bin/sqlcmd
[ -x "$client" ] || { echo "$me: sqlcmd not found: install Microsoft's (mssql-tools18) or the Go one (go-sqlcmd)" >&2; exit 1; }
[ -n "${SQLCMDPASSWORD-}" ] || { echo "$me: no password: the job's secret line gives SQLCMDPASSWORD" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-mssql.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# Where the server is, and how its certificate is checked. The password
# stays in SQLCMDPASSWORD, which both clients read for themselves; the CA
# file goes to them as SSL_CERT_FILE, which both honour. -Nm: encrypted,
# always; there is no setting that trusts a certificate unchecked.
args=(-S "tcp:${MSSQL_HOST:-localhost},${MSSQL_PORT:-1433}" -U "${MSSQL_USER:-vigil_monitor}" -d master -Nm -l 10 -t 60 -h -1 -W -b)
[ -n "${MSSQL_CERT_NAME-}" ] && args+=(-F "$MSSQL_CERT_NAME")
if [ -n "${MSSQL_CACERT-}" ]; then
    [ -r "$MSSQL_CACERT" ] || { echo "$me: cannot read MSSQL_CACERT: $MSSQL_CACERT" >&2; exit 1; }
    export SSL_CERT_FILE=$MSSQL_CACERT
fi

# The query, which prints finished metric lines, so every platform's
# script prints the same.
cat > "$work/q.sql" << 'SQL'
@SQL@SQL

if "$client" "${args[@]}" -i "$work/q.sql" > "$work/out" 2> "$work/err"; then
    grep '^metric ' "$work/out"
    exit 0
fi
# The Go client says some things twice: each line once.
why=$(cat "$work/out" "$work/err" | tr -d '\r' | grep -v '^$' | awk '!seen[$0]++' | head -n 3 | tr '\n' ' ')
# It could not be reached at all: a reading, not a failure. A refused
# login, a certificate it cannot trust and a failed query are failures.
case $why in
    *[Ll]ogin\ failed* | *SSL* | *TLS* | *[Cc]ertificate* | *x509* | *Msg\ [0-9]*) ;;
    *[Cc]onnection\ refused* | *[Nn]o\ route* | *i/o\ timeout* | *[Ll]ogin\ timeout\ expired* | *network-related* | *TCP\ Provider* | *no\ such\ host* | *[Nn]ame\ or\ service\ not\ known* | *server\ was\ not\ found*)
        @DOWN@
        exit 0
        ;;
esac
echo "$me: the query failed: $why" >&2
exit 1
'''

PS_BODY = r'''$ErrorActionPreference = 'Stop'
$me = '@JOB@'

# The query, which prints finished metric lines, so every platform's script
# prints the same.
$sql = @'
@SQL@'@

if ($env:MSSQL_CACERT) { [Console]::Error.WriteLine("${me}: MSSQL_CACERT is for Linux and macOS: on Windows, put the CA in the machine's Trusted Root store"); exit 1 }
if ($env:MSSQL_CERT_NAME) { [Console]::Error.WriteLine("${me}: MSSQL_CERT_NAME is for Linux and macOS: on Windows, connect by the name on the certificate"); exit 1 }
$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$hostName = if ($env:MSSQL_HOST) { $env:MSSQL_HOST } else { 'localhost' }
$port = if ($env:MSSQL_PORT) { $env:MSSQL_PORT } else { '1433' }
$b['Data Source'] = "tcp:$hostName,$port"
$b['Initial Catalog'] = 'master'
# Encrypted, always, the certificate checked: there is no setting that
# trusts one unchecked.
$b['Encrypt'] = $true
$b['TrustServerCertificate'] = $false
$b['Connect Timeout'] = 10
$b['Application Name'] = 'vigil'
$b['Pooling'] = $false
if ($env:MSSQL_AUTH -eq 'windows') { $b['Integrated Security'] = $true }
else {
    if (-not $env:SQLCMDPASSWORD) { [Console]::Error.WriteLine("${me}: no password: the job's secret line gives SQLCMDPASSWORD, or set MSSQL_AUTH=windows"); exit 1 }
    $b['User ID'] = if ($env:MSSQL_USER) { $env:MSSQL_USER } else { 'vigil_monitor' }
    $b['Password'] = $env:SQLCMDPASSWORD
}
$conn = New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
$lines = New-Object 'System.Collections.Generic.List[string]'
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = 60
    $r = $cmd.ExecuteReader()
    while ($r.Read()) { $lines.Add([string]$r.GetValue(0)) }
    $r.Close()
}
catch {
    $e = $_.Exception
    while ($e.InnerException -and -not ($e -is [System.Data.SqlClient.SqlException])) { $e = $e.InnerException }
    $why = ($e.Message -replace '\s+', ' ').Trim()
    # It could not be reached at all: a reading, not a failure. A refused
    # login, a certificate it cannot trust and a failed query are failures.
    if ($why -notmatch 'Login failed|certificate|SSL|TLS' -and $why -match 'network-related|could not open a connection|actively refused|timeout period elapsed|No such host|was not found|not accessible') {
@DOWNPS@        exit 0
    }
    [Console]::Error.WriteLine("${me}: the query failed: $why")
    exit 1
}
finally { $conn.Dispose() }
foreach ($l in $lines) { if ($l.StartsWith('metric ')) { Write-Output $l } }
exit 0
'''


def sh_script(j):
    head = ['#!/usr/bin/env bash', '#', '# %s.sh - %s' % (j['job'], j['title']), '#']
    head += [('# ' + n).rstrip() for n in NOTICE] + ['#']
    head += [('# ' + l).rstrip() for l in doc(j, False)]
    body = SH_BODY.replace('@JOB@', j['job']).replace('@SQL@', sql_for(j))
    body = body.replace('@DOWN@', "echo 'metric up 0'" if j['job'] == 'status' else ':')
    return '\n'.join(head) + '\n\n' + body


def ps_script(j):
    head = ['#Requires -Version 5.1', '', '<#', '.SYNOPSIS', '    %s.ps1 - %s, on Windows' % (j['job'], j['title']), '.NOTES']
    head += [('    ' + n).rstrip() for n in NOTICE]
    head += ['.DESCRIPTION']
    head += [('    ' + l).rstrip() for l in doc(j, True)]
    head += ['#>']
    body = PS_BODY.replace('@JOB@', j['job']).replace('@SQL@', sql_for(j))
    body = body.replace('@DOWNPS@', "        Write-Output 'metric up 0'\n" if j['job'] == 'status' else '')
    return '\n'.join(head) + '\n\n' + body


def pack_config():
    p = ['# mssql - Microsoft SQL Server 2019, 2022 and 2025, on Linux or Windows, on',
         '# this machine or any it can reach: whether it answers and what it is, its',
         '# workload, sessions and blocking, CPU and threads, Always On, waits, I/O',
         '# per file, memory, tempdb, connections, each database, what keeps them safe,',
         '# risky settings, backups and Agent jobs. Linux, macOS and Windows. See',
         '# SPECIFICATION.md section 18.10 for this format.',
         '#',
         '# The jobs that run every 5 or 15 minutes each have minutes of their own',
         '# (cron, local time), so few runs start together.',
         '#',
         '# Off until enabled: vigil pack enable mssql. It logs in as a read-only',
         '# login; create one once, as an administrator (packs/README.md has it all):',
         "#   CREATE LOGIN vigil_monitor WITH PASSWORD = '...';",
         '#   GRANT VIEW SERVER PERFORMANCE STATE, VIEW SERVER SECURITY STATE,',
         '#     VIEW ANY DATABASE, CONNECT ANY DATABASE TO vigil_monitor;',
         '# (2019: VIEW SERVER STATE in place of the first two), and give Vigil its',
         '# password:',
         '#   vigil secret set MSSQL_MONITOR_PASSWORD',
         '# For another host or port, edit the env lines of the jobs vigil pack enable',
         '# writes into the configuration.',
         '#']
    p += [('# ' + n).rstrip() for n in NOTICE]
    p += ['',
          '[pack]',
          'version     = 1.0.0',
          '# vigil: the oldest Vigil this pack runs on. vigil pack update refuses the',
          '# pack on an older one.',
          'vigil       = 0.3.0',
          'description = Microsoft SQL Server: up, workload, sessions and blocking, CPU, Always On, waits, I/O, memory, tempdb, connections, databases, integrity, settings, backups, Agent jobs',
          '# What vigil pack info shows besides: the servers it is meant for, the',
          '# programs its scripts need on each platform, and where it is explained.',
          'works_with  = SQL Server 2019, 2022 and 2025, on Linux or Windows',
          'programs_linux = sqlcmd (mssql-tools18 or go-sqlcmd)',
          'programs_macos = sqlcmd (mssql-tools18 or go-sqlcmd)',
          'docs        = https://github.com/godspeedhq/vigil/blob/main/packs/README.md#mssql',
          "needs       = a read-only login, as an administrator: CREATE LOGIN vigil_monitor WITH PASSWORD = '...'; GRANT VIEW SERVER PERFORMANCE STATE, VIEW SERVER SECURITY STATE, VIEW ANY DATABASE, CONNECT ANY DATABASE TO vigil_monitor (2019: VIEW SERVER STATE, VIEW ANY DATABASE, CONNECT ANY DATABASE)",
          "needs       = for mssql_agent, in msdb: CREATE USER vigil_monitor FOR LOGIN vigil_monitor; ALTER ROLE SQLAgentReaderRole ADD MEMBER vigil_monitor",
          '']
    for j in JOBS:
        names = [n for n, _ in j['metrics']]
        p += ['[job.%s]' % j['job'],
              'metric_name = %s' % j['metric_name'],
              'metrics     = %s' % ', '.join(names),
              j['when'],
              'max_runtime = %s' % ('1m' if j['job'] in ('databases', 'health', 'io', 'backups') else '30s'),
              'env         = MSSQL_HOST=localhost',
              'env         = MSSQL_PORT=1433',
              'env         = MSSQL_USER=vigil_monitor',
              'secret      = SQLCMDPASSWORD=secret:MSSQL_MONITOR_PASSWORD',
              '']
    return '\n'.join(p).rstrip('\n') + '\n'


os.makedirs(os.path.join(out, 'linux'), exist_ok=True)
os.makedirs(os.path.join(out, 'macos'), exist_ok=True)
os.makedirs(os.path.join(out, 'windows'), exist_ok=True)
open(os.path.join(out, 'pack.config'), 'w', encoding='utf-8', newline='\n').write(pack_config())
for j in JOBS:
    s = sh_script(j)
    for os_ in ('linux', 'macos'):
        open(os.path.join(out, os_, j['job'] + '.sh'), 'w', encoding='utf-8', newline='\n').write(s)
    open(os.path.join(out, 'windows', j['job'] + '.ps1'), 'w', encoding='utf-8', newline='\n').write(ps_script(j))
print('wrote', len(JOBS), 'jobs')
