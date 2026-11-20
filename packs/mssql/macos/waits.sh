#!/usr/bin/env bash
#
# waits.sh - where a SQL Server spends its time waiting
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Reports the time SQL Server's tasks spent waiting, since it started, by
# kind, and its ten most costly wait types. Waits that are idle by design
# are left out. One query, read-only, that never waits more than 5 seconds
# for a lock and gives way in a deadlock.
#
# Connects to MSSQL_HOST and MSSQL_PORT as MSSQL_USER, with the password in
# SQLCMDPASSWORD, all set by the job; never on a command line. Always
# encrypted, the server's certificate checked against the system's CAs or
# MSSQL_CACERT, a CA file, and against the server's name: give MSSQL_HOST
# the name on the certificate (Microsoft's sqlcmd does not match an IP
# address), or MSSQL_CERT_NAME. On macOS the Go sqlcmd ignores MSSQL_CACERT,
# and trusts the System keychain only: put your CA there. Uses sqlcmd:
# Microsoft's (mssql-tools18) or the Go one (go-sqlcmd).
#
# Metrics:
#   wait_ms_count      milliseconds waited, tagged kind=<cpu, disk_read,
#                      log_write, lock, latch, memory, network, parallelism,
#                      replication, external or other> (a running total)
#   top_wait_ms_count  milliseconds waited by one of the ten most costly types,
#                      tagged type= (a running total)
#   top_waits_count    waits of that type (a running total)
#
# Example output (the rest are in the same form):
#   metric wait_ms_count 1409 kind=disk_read
#   metric wait_ms_count 9655 kind=lock
#   metric wait_ms_count 871 kind=log_write
#   metric top_wait_ms_count 8257 type=LCK_M_U
#   metric top_waits_count 13 type=LCK_M_U
#
# Reading the results (starting points: tune them to the server):
#   Healthy  each kind's rate steady with the workload.
#   Watch    disk_read rising: the data does not fit in memory, or the disk
#            is slow; log_write rising: the log's disk is slow; lock rising:
#            blocking; network: a client reads its results slowly.
#   Act      cpu (signal waits) a large share of the total: the CPUs are
#            saturated. The totals restart with the server: graph them as a
#            rate, and compare kinds.
#
# Requires: bash, sqlcmd (mssql-tools18 or go-sqlcmd), and a login with what
#   packs/README.md says to grant
# Exit code: 0 on success, or when the server does not answer; 1 if the
#   server refuses the login, its certificate or the query, or sqlcmd is
#   missing

set -u

me=waits
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
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NOCOUNT ON;
-- Any error ends the whole query, so a run never prints half its readings.
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 5000;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET DEADLOCK_PRIORITY LOW;
-- Each reading: a metric name, its value, and up to six tags whose values
-- the footer makes safe.
DECLARE @m TABLE (seq int IDENTITY PRIMARY KEY, name varchar(64) NOT NULL, v decimal(38, 2) NOT NULL,
    k1 varchar(32) NULL, t1 nvarchar(256) NULL, k2 varchar(32) NULL, t2 nvarchar(256) NULL,
    k3 varchar(32) NULL, t3 nvarchar(256) NULL, k4 varchar(32) NULL, t4 nvarchar(256) NULL,
    k5 varchar(32) NULL, t5 nvarchar(256) NULL, k6 varchar(32) NULL, t6 nvarchar(256) NULL);
DECLARE @now datetime2 = SYSDATETIME();
-- SQL Server's own counters, their names trimmed: the object without its
-- "SQLServer:" or "MSSQL$<instance>:" prefix.
DECLARE @pc TABLE (obj nvarchar(128) NOT NULL, counter nvarchar(128) NOT NULL, inst nvarchar(128) NOT NULL, value bigint NOT NULL);
INSERT @pc SELECT SUBSTRING(RTRIM(object_name), CHARINDEX(N':', object_name) + 1, 128), RTRIM(counter_name), RTRIM(instance_name), cntr_value
    FROM sys.dm_os_performance_counters;
-- Where SQL Server spends its time waiting, since it started (running
-- totals: graph them as rates). Waits that are idle by design are left out.
DECLARE @w TABLE (wait_type nvarchar(60) PRIMARY KEY, ms bigint, signal_ms bigint, n bigint);
INSERT @w SELECT wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count
FROM sys.dm_os_wait_stats
WHERE waiting_tasks_count > 0 AND wait_type NOT IN (
    N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP', N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER',
    N'CHECKPOINT_QUEUE', N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE', N'CXCONSUMER',
    N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE', N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL',
    N'DISPATCHER_QUEUE_SEMAPHORE', N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
    N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'HADR_LOGCAPTURE_WAIT', N'HADR_NOTIFICATION_DEQUEUE',
    N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE', N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE',
    N'MEMORY_ALLOCATION_EXT', N'ONDEMAND_TASK_QUEUE', N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE',
    N'PARALLEL_REDO_TRAN_LIST', N'PARALLEL_REDO_WORKER_SYNC', N'PARALLEL_REDO_WORKER_WAIT_WORK',
    N'PREEMPTIVE_OS_FLUSHFILEBUFFERS', N'PREEMPTIVE_XE_GETTARGETSTATE', N'PVS_PREALLOCATE', N'PWAIT_ALL_COMPONENTS_INITIALIZED',
    N'PWAIT_DIRECTLOGCONSUMER_GETNEXT', N'PWAIT_EXTENSIBILITY_CLEANUP_TASK', N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
    N'QDS_ASYNC_QUEUE', N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'QDS_SHUTDOWN_QUEUE', N'REDO_THREAD_PENDING_WORK',
    N'REQUEST_FOR_DEADLOCK_SEARCH', N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP',
    N'SLEEP_DCOMSTARTUP', N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY', N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP', N'SLEEP_PHYSMASTERDBREADY',
    N'SLEEP_SYSTEMTASK', N'SLEEP_TASK', N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT', N'SOS_WORK_DISPATCHER',
    N'SP_SERVER_DIAGNOSTICS_SLEEP', N'SQLTRACE_BUFFER_FLUSH', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES',
    N'STARTUP_DEPENDENCY_MANAGER', N'VDI_CLIENT_OTHER', N'WAIT_FOR_RESULTS', N'WAITFOR', N'WAITFOR_TASKSHUTDOWN',
    N'WAIT_XTP_RECOVERY', N'WAIT_XTP_HOST_WAIT', N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'WAIT_XTP_CKPT_CLOSE',
    N'XE_DISPATCHER_JOIN', N'XE_DISPATCHER_WAIT', N'XE_LIVE_TARGET_TVF', N'XE_TIMER_EVENT');
-- By kind: what the wait means for someone looking into "why is it slow".
INSERT @m (name, v, k1, t1)
SELECT 'wait_ms_count', SUM(x.ms), 'kind', x.kind FROM (
    SELECT signal_ms AS ms, N'cpu' AS kind FROM @w
    UNION ALL
    SELECT ms - signal_ms, CASE
        WHEN wait_type LIKE N'PAGEIOLATCH%' OR wait_type IN (N'IO_COMPLETION', N'ASYNC_IO_COMPLETION', N'BACKUPIO') THEN N'disk_read'
        WHEN wait_type IN (N'WRITELOG', N'LOGBUFFER', N'LOG_RATE_GOVERNOR') THEN N'log_write'
        WHEN wait_type LIKE N'LCK[_]M[_]%' THEN N'lock'
        WHEN wait_type LIKE N'PAGELATCH%' OR wait_type LIKE N'LATCH[_]%' THEN N'latch'
        WHEN wait_type LIKE N'RESOURCE_SEMAPHORE%' OR wait_type = N'CMEMTHREAD' THEN N'memory'
        WHEN wait_type IN (N'ASYNC_NETWORK_IO', N'NET_WAITFOR_PACKET') THEN N'network'
        WHEN wait_type LIKE N'CXPACKET' OR wait_type LIKE N'CXSYNC%' OR wait_type = N'EXCHANGE' THEN N'parallelism'
        WHEN wait_type LIKE N'HADR[_]SYNC[_]COMMIT' OR wait_type LIKE N'HADR[_]%' THEN N'replication'
        WHEN wait_type = N'SOS_SCHEDULER_YIELD' OR wait_type = N'THREADPOOL' THEN N'cpu'
        WHEN wait_type LIKE N'PREEMPTIVE[_]%' THEN N'external'
        ELSE N'other' END
    FROM @w
    UNION ALL
    -- Every kind, so a graph has each line from the start.
    SELECT 0, k FROM (VALUES (N'cpu'), (N'disk_read'), (N'log_write'), (N'lock'), (N'latch'), (N'memory'), (N'network'),
        (N'parallelism'), (N'replication'), (N'external'), (N'other')) AS k(k)
) AS x GROUP BY x.kind ORDER BY x.kind;
-- The ten wait types that have cost the most.
INSERT @m (name, v, k1, t1)
SELECT TOP (10) 'top_wait_ms_count', ms, 'type', wait_type FROM @w ORDER BY ms DESC;
INSERT @m (name, v, k1, t1)
SELECT TOP (10) 'top_waits_count', n, 'type', wait_type FROM @w ORDER BY ms DESC;
-- The readings as metric lines, in the order they were taken. A tag value
-- keeps A-Z, a-z, 0-9, _, . and - (first in the brackets: LIKE takes a - at
-- the end as a range), and has anything else as _, one for each
-- character, so every client prints the same line; an empty one is "none".
-- At most 1000 lines: Vigil reads no more from one run.
WITH n AS (SELECT TOP (256) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_columns)
SELECT TOP (1000) CONVERT(varchar(1000), 'metric ' + m.name + ' '
    + CASE WHEN m.v = ROUND(m.v, 0) THEN CONVERT(varchar(40), CONVERT(decimal(38, 0), m.v))
        WHEN RIGHT(CONVERT(varchar(40), m.v), 1) = '0' THEN LEFT(CONVERT(varchar(40), m.v), LEN(CONVERT(varchar(40), m.v)) - 1)
        ELSE CONVERT(varchar(40), m.v) END
    + ISNULL(' ' + m.k1 + '=' + s1.x, '') + ISNULL(' ' + m.k2 + '=' + s2.x, '') + ISNULL(' ' + m.k3 + '=' + s3.x, '')
    + ISNULL(' ' + m.k4 + '=' + s4.x, '') + ISNULL(' ' + m.k5 + '=' + s5.x, '') + ISNULL(' ' + m.k6 + '=' + s6.x, ''))
FROM @m AS m
CROSS APPLY (SELECT x = CASE WHEN m.t1 IS NULL THEN NULL WHEN LEN(m.t1) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t1, n.i, 1) COLLATE Latin1_General_BIN LIKE '[-A-Za-z0-9_.]' THEN SUBSTRING(m.t1, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t1 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s1
CROSS APPLY (SELECT x = CASE WHEN m.t2 IS NULL THEN NULL WHEN LEN(m.t2) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t2, n.i, 1) COLLATE Latin1_General_BIN LIKE '[-A-Za-z0-9_.]' THEN SUBSTRING(m.t2, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t2 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s2
CROSS APPLY (SELECT x = CASE WHEN m.t3 IS NULL THEN NULL WHEN LEN(m.t3) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t3, n.i, 1) COLLATE Latin1_General_BIN LIKE '[-A-Za-z0-9_.]' THEN SUBSTRING(m.t3, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t3 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s3
CROSS APPLY (SELECT x = CASE WHEN m.t4 IS NULL THEN NULL WHEN LEN(m.t4) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t4, n.i, 1) COLLATE Latin1_General_BIN LIKE '[-A-Za-z0-9_.]' THEN SUBSTRING(m.t4, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t4 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s4
CROSS APPLY (SELECT x = CASE WHEN m.t5 IS NULL THEN NULL WHEN LEN(m.t5) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t5, n.i, 1) COLLATE Latin1_General_BIN LIKE '[-A-Za-z0-9_.]' THEN SUBSTRING(m.t5, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t5 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s5
CROSS APPLY (SELECT x = CASE WHEN m.t6 IS NULL THEN NULL WHEN LEN(m.t6) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t6, n.i, 1) COLLATE Latin1_General_BIN LIKE '[-A-Za-z0-9_.]' THEN SUBSTRING(m.t6, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t6 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s6
ORDER BY m.seq;
SQL

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
        :
        exit 0
        ;;
esac
# On macOS the Go client checks certificates against the keychain only, and
# ignores SSL_CERT_FILE: say so, rather than leave MSSQL_CACERT a mystery.
case $(uname -s):${MSSQL_CACERT-}:$why in
    Darwin:?*:*x509*) why="$why(on macOS the Go sqlcmd ignores MSSQL_CACERT: trust the CA in the System keychain)" ;;
esac
echo "$me: the query failed: $why" >&2
exit 1
