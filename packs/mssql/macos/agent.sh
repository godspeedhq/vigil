#!/usr/bin/env bash
#
# agent.sh - a SQL Server's Agent jobs
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
# Reports SQL Agent's jobs, from msdb: how many there are, those that failed
# in the last 24 hours, those running now and how long the longest has run.
# Reading them needs SELECT on four of msdb's tables (packs/README.md):
# without it, readable 0 and nothing else. One query, read-only, that never
# waits more than 5 seconds for a lock and gives way in a deadlock.
#
# Connects to MSSQL_HOST and MSSQL_PORT as MSSQL_USER, with the password in
# SQLCMDPASSWORD, all set by the job; never on a command line. Always
# encrypted, the server's certificate checked against the system's CAs or
# MSSQL_CACERT, a CA file, and against the server's name: give MSSQL_HOST
# the name on the certificate (Microsoft's sqlcmd does not match an IP
# address), or MSSQL_CERT_NAME. Uses sqlcmd: Microsoft's (mssql-tools18) or
# the Go one (go-sqlcmd).
#
# Metrics:
#   readable                 1 when this login may read Agent's jobs, else 0
#   jobs                     Agent jobs
#   jobs_enabled             those enabled
#   failed_24h               job runs that failed in the last 24 hours
#   job_failed_24h           a job that failed in them: its failures, tagged
#                            job=
#   running                  jobs running now
#   longest_running_seconds  how long the longest has run
#
# Example output (the rest are in the same form):
#   metric readable 1
#   metric jobs 6
#   metric failed_24h 1
#   metric job_failed_24h 1 job=nightly_index_maintenance
#   metric running 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  readable 1; failed_24h 0.
#   Watch    longest_running_seconds longer than the job usually takes.
#   Act      failed_24h above 0: see which in job_failed_24h; readable 0:
#            grant what packs/README.md says.
#
# Requires: bash, sqlcmd (mssql-tools18 or go-sqlcmd), and a login with what
#   packs/README.md says to grant
# Exit code: 0 on success, or when the server does not answer; 1 if the
#   server refuses the login, its certificate or the query, or sqlcmd is
#   missing

set -u

me=agent
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
-- SQL Agent's jobs, from msdb: those that failed in the last 24 hours,
-- those running now, and how long the longest has run. Reading them needs
-- SELECT on four of msdb's tables (packs/README.md): without it, readable 0
-- and nothing else. SQLAgentReaderRole does not give it: it works through
-- Agent's procedures.
IF HAS_PERMS_BY_NAME(N'msdb.dbo.sysjobs', N'OBJECT', N'SELECT') = 1
    AND HAS_PERMS_BY_NAME(N'msdb.dbo.sysjobhistory', N'OBJECT', N'SELECT') = 1
    AND HAS_PERMS_BY_NAME(N'msdb.dbo.sysjobactivity', N'OBJECT', N'SELECT') = 1
    AND HAS_PERMS_BY_NAME(N'msdb.dbo.syssessions', N'OBJECT', N'SELECT') = 1
BEGIN
    INSERT @m (name, v) VALUES ('readable', 1);
    DECLARE @h TABLE (job_id uniqueidentifier, finished datetime, status int);
    INSERT @h SELECT job_id,
        DATEADD(second, (run_time / 10000) * 3600 + (run_time / 100 % 100) * 60 + run_time % 100
            + (run_duration / 10000) * 3600 + (run_duration / 100 % 100) * 60 + run_duration % 100,
            CONVERT(datetime, CONVERT(char(8), run_date), 112)),
        run_status
    FROM msdb.dbo.sysjobhistory WHERE step_id = 0 AND run_date >= CONVERT(int, CONVERT(char(8), DATEADD(day, -2, @now), 112));
    INSERT @m (name, v) SELECT 'jobs', COUNT(*) FROM msdb.dbo.sysjobs;
    INSERT @m (name, v) SELECT 'jobs_enabled', COUNT(*) FROM msdb.dbo.sysjobs WHERE enabled = 1;
    INSERT @m (name, v) SELECT 'failed_24h', COUNT(*) FROM @h WHERE status = 0 AND finished > DATEADD(hour, -24, @now);
    -- Each job that failed in the last 24 hours, the 50 most recent.
    INSERT @m (name, v, k1, t1)
    SELECT TOP (50) 'job_failed_24h', COUNT(*), 'job', j.name FROM @h AS h JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
    WHERE h.status = 0 AND h.finished > DATEADD(hour, -24, @now) GROUP BY j.name ORDER BY MAX(h.finished) DESC;
    -- Running now: started in Agent's current session, not finished.
    DECLARE @a TABLE (job_id uniqueidentifier, started datetime);
    INSERT @a SELECT a.job_id, a.start_execution_date FROM msdb.dbo.sysjobactivity AS a
    WHERE a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL;
    INSERT @m (name, v) SELECT 'running', COUNT(*) FROM @a;
    INSERT @m (name, v) SELECT 'longest_running_seconds', ISNULL(MAX(DATEDIFF_BIG(second, started, @now)), 0) FROM @a WHERE started IS NOT NULL;
END
ELSE
    INSERT @m (name, v) VALUES ('readable', 0);
-- The readings as metric lines, in the order they were taken. A tag value
-- keeps A-Z, a-z, 0-9, _, . and -, and has anything else as _, one for each
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
CROSS APPLY (SELECT x = CASE WHEN m.t1 IS NULL THEN NULL WHEN LEN(m.t1) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t1, n.i, 1) COLLATE Latin1_General_BIN LIKE '[A-Za-z0-9_.-]' THEN SUBSTRING(m.t1, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t1 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s1
CROSS APPLY (SELECT x = CASE WHEN m.t2 IS NULL THEN NULL WHEN LEN(m.t2) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t2, n.i, 1) COLLATE Latin1_General_BIN LIKE '[A-Za-z0-9_.-]' THEN SUBSTRING(m.t2, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t2 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s2
CROSS APPLY (SELECT x = CASE WHEN m.t3 IS NULL THEN NULL WHEN LEN(m.t3) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t3, n.i, 1) COLLATE Latin1_General_BIN LIKE '[A-Za-z0-9_.-]' THEN SUBSTRING(m.t3, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t3 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s3
CROSS APPLY (SELECT x = CASE WHEN m.t4 IS NULL THEN NULL WHEN LEN(m.t4) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t4, n.i, 1) COLLATE Latin1_General_BIN LIKE '[A-Za-z0-9_.-]' THEN SUBSTRING(m.t4, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t4 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s4
CROSS APPLY (SELECT x = CASE WHEN m.t5 IS NULL THEN NULL WHEN LEN(m.t5) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t5, n.i, 1) COLLATE Latin1_General_BIN LIKE '[A-Za-z0-9_.-]' THEN SUBSTRING(m.t5, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t5 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s5
CROSS APPLY (SELECT x = CASE WHEN m.t6 IS NULL THEN NULL WHEN LEN(m.t6) = 0 THEN 'none' ELSE (SELECT CASE WHEN SUBSTRING(m.t6, n.i, 1) COLLATE Latin1_General_BIN LIKE '[A-Za-z0-9_.-]' THEN SUBSTRING(m.t6, n.i, 1) ELSE '_' END FROM n WHERE n.i <= LEN(m.t6 + N'.') - 1 ORDER BY n.i FOR XML PATH(''), TYPE).value('.', 'varchar(256)') END) AS s6
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
echo "$me: the query failed: $why" >&2
exit 1
