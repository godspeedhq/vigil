#!/usr/bin/env bash
#
# activity.sh - what a SQL Server is doing now
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
# Reports user sessions by state, requests running and blocked, the sessions
# at the head of a blocking chain, the longest request and wait, the oldest
# open transaction, sessions asleep with a transaction open, and the longest
# snapshot transaction. Its own session is left out. One query, read-only,
# that never waits more than 5 seconds for a lock and gives way in a
# deadlock.
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
#   sessions                     user sessions, tagged state=<running, sleeping,
#                                dormant or preconnect>
#   requests                     requests running now
#   requests_blocked             requests waiting on another session
#   head_blockers                sessions that block others and wait on no one
#   longest_request_seconds      how long the longest request has run
#   longest_wait_seconds         the longest wait now, tagged type=<its wait
#                                type, or none>
#   oldest_transaction_seconds   how long the oldest open transaction has been
#                                open
#   idle_in_transaction          sessions asleep with a transaction open
#   idle_in_transaction_seconds  how long the longest of them has slept
#   longest_snapshot_seconds     how long the longest snapshot transaction has
#                                run
#
# Example output (the rest are in the same form):
#   metric sessions 1 state=sleeping
#   metric requests_blocked 0
#   metric head_blockers 0
#   metric longest_wait_seconds 0 type=none
#   metric oldest_transaction_seconds 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  requests_blocked and head_blockers 0; idle_in_transaction 0.
#   Watch    oldest_transaction_seconds in minutes: it holds locks and keeps
#            the log from being reused; longest_snapshot_seconds growing:
#            tempdb's version store grows with it.
#   Act      head_blockers above 0 for minutes: one session holds up others,
#            find it; idle_in_transaction above 0 for long: an application
#            that did not commit.
#
# Requires: bash, sqlcmd (mssql-tools18 or go-sqlcmd), and a login with what
#   packs/README.md says to grant
# Exit code: 0 on success, or when the server does not answer; 1 if the
#   server refuses the login, its certificate or the query, or sqlcmd is
#   missing

set -u

me=activity
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
-- What the server is doing now: sessions, requests, blocking, and the oldest
-- work. Its own session, and SQL Server's internal ones, are left out.
DECLARE @s TABLE (session_id int PRIMARY KEY, status nvarchar(30), open_tran int, last_end datetime);
INSERT @s SELECT session_id, status, open_transaction_count, last_request_end_time
    FROM sys.dm_exec_sessions WHERE is_user_process = 1 AND session_id <> @@SPID;
DECLARE @r TABLE (session_id int PRIMARY KEY, blocked_by int, start_time datetime, wait_type nvarchar(60), wait_ms bigint);
INSERT @r SELECT r.session_id, r.blocking_session_id, r.start_time, r.wait_type, r.wait_time
    FROM sys.dm_exec_requests AS r JOIN @s AS s ON s.session_id = r.session_id
    -- A request that waits for work by design is not stuck.
    WHERE ISNULL(r.wait_type, N'') NOT IN (N'WAITFOR', N'BROKER_RECEIVE_WAITFOR', N'XE_LIVE_TARGET_TVF');

INSERT @m (name, v, k1, t1)
SELECT 'sessions', SUM(CASE WHEN s.session_id IS NULL THEN 0 ELSE 1 END), 'state', st.state
FROM (VALUES (N'running'), (N'sleeping'), (N'dormant'), (N'preconnect')) AS st(state)
LEFT JOIN @s AS s ON s.status = st.state
GROUP BY st.state;
INSERT @m (name, v) SELECT 'requests', COUNT(*) FROM @r WHERE start_time IS NOT NULL;
INSERT @m (name, v) SELECT 'requests_blocked', COUNT(*) FROM @r WHERE blocked_by <> 0;
-- A head blocker blocks others and waits on no one.
INSERT @m (name, v)
SELECT 'head_blockers', COUNT(DISTINCT b.blocked_by) FROM @r AS b
WHERE b.blocked_by <> 0 AND NOT EXISTS (SELECT 1 FROM @r AS h WHERE h.session_id = b.blocked_by AND h.blocked_by <> 0);
INSERT @m (name, v)
SELECT 'longest_request_seconds', ISNULL(MAX(DATEDIFF_BIG(second, start_time, @now)), 0) FROM @r WHERE start_time IS NOT NULL;
-- The longest wait now, and what it waits on.
INSERT @m (name, v, k1, t1)
SELECT TOP (1) 'longest_wait_seconds', w.wait_ms / 1000.0, 'type', w.wait_type
FROM (SELECT wait_ms, wait_type FROM @r WHERE wait_type IS NOT NULL
      UNION ALL SELECT 0, N'none') AS w
ORDER BY w.wait_ms DESC;
-- The oldest transaction a user session holds open.
INSERT @m (name, v)
SELECT 'oldest_transaction_seconds', ISNULL(MAX(DATEDIFF_BIG(second, t.transaction_begin_time, @now)), 0)
FROM sys.dm_tran_session_transactions AS st
JOIN sys.dm_tran_active_transactions AS t ON t.transaction_id = st.transaction_id
JOIN @s AS s ON s.session_id = st.session_id WHERE t.transaction_begin_time IS NOT NULL;
-- Asleep with a transaction open: an application that did not commit, and
-- the classic cause of blocking.
INSERT @m (name, v) SELECT 'idle_in_transaction', COUNT(*) FROM @s WHERE status = N'sleeping' AND open_tran > 0;
INSERT @m (name, v)
SELECT 'idle_in_transaction_seconds', ISNULL(MAX(DATEDIFF_BIG(second, last_end, @now)), 0)
FROM @s WHERE status = N'sleeping' AND open_tran > 0 AND last_end IS NOT NULL;
-- Snapshot transactions keep row versions in tempdb for as long as they run.
INSERT @m (name, v)
SELECT 'longest_snapshot_seconds', ISNULL(MAX(elapsed_time_seconds), 0) FROM sys.dm_tran_active_snapshot_database_transactions;
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
echo "$me: the query failed: $why" >&2
exit 1
