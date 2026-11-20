#!/usr/bin/env bash
#
# replication.sh - a SQL Server's Always On availability groups
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
# Reports, for each availability group this server is part of, each
# replica's role, connection and health, and each database's synchronization
# and the log waiting to be sent and redone. A primary sees every replica; a
# secondary, itself. With no availability group, it prints nothing. One
# query, read-only, that never waits more than 5 seconds for a lock and
# gives way in a deadlock.
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
#   primary           1 for the primary replica, tagged group=<its name, where
#                     the login may see it; else its id> and replica=
#   connected         1 when the replica is connected
#   health            2 healthy, 1 partly, 0 not healthy
#   local             1 for this server
#   sync_state        each database: 2 synchronized, 1 synchronizing, 0 neither;
#                     tagged group=, replica= and database=
#   suspended         1 when its data movement is suspended
#   send_queue_bytes  log not yet sent to the secondary
#   send_rate_bytes   log sent a second
#   redo_queue_bytes  log received but not yet redone on the secondary
#   redo_rate_bytes   log redone a second
#   lag_seconds       how far the secondary is behind
#
# Example output (the rest are in the same form):
#   metric primary 1 group=ag1 replica=sql1
#   metric health 2 group=ag1 replica=sql2
#   metric sync_state 2 group=ag1 replica=sql2 database=shop
#   metric send_queue_bytes 0 group=ag1 replica=sql2 database=shop
#   metric lag_seconds 0 group=ag1 replica=sql2 database=shop
#
# Reading the results (starting points: tune them to the server):
#   Healthy  health 2; connected 1; sync_state 2 (synchronous) or 1
#            (asynchronous); queues near 0.
#   Watch    send_queue_bytes or redo_queue_bytes growing: the secondary
#            falls behind; lag_seconds rising.
#   Act      connected 0; health 0; suspended 1: that database is not
#            protected; primary changing when no one failed it over.
#
# Requires: bash, sqlcmd (mssql-tools18 or go-sqlcmd), and a login with what
#   packs/README.md says to grant
# Exit code: 0 on success, or when the server does not answer; 1 if the
#   server refuses the login, its certificate or the query, or sqlcmd is
#   missing

set -u

me=replication
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
-- Always On availability groups, from this server: each replica it knows
-- of, and each database's queues. Nothing with no availability group. A
-- group is named where this login may see its name (VIEW DEFINITION on the
-- group: sys.availability_groups shows nothing more without it); else by
-- its id.
-- A primary knows every replica; a secondary, itself.
INSERT @m (name, v, k1, t1, k2, t2)
SELECT x.name, x.v, 'group', ISNULL(g.name, CONVERT(nvarchar(36), s.group_id)), 'replica', r.replica_server_name
FROM sys.dm_hadr_availability_replica_states AS s
JOIN sys.availability_replicas AS r ON r.replica_id = s.replica_id
LEFT JOIN sys.availability_groups AS g ON g.group_id = s.group_id
CROSS APPLY (VALUES
    ('primary', CASE WHEN s.role = 1 THEN 1 ELSE 0 END),
    ('connected', CASE WHEN s.connected_state = 1 THEN 1 ELSE 0 END),
    -- 2 healthy, 1 partly, 0 not.
    ('health', ISNULL(s.synchronization_health, 0)),
    ('local', s.is_local)
) AS x(name, v)
ORDER BY ISNULL(g.name, CONVERT(nvarchar(36), s.group_id)), r.replica_server_name;
INSERT @m (name, v, k1, t1, k2, t2, k3, t3)
SELECT x.name, x.v, 'group', ISNULL(g.name, CONVERT(nvarchar(36), d.group_id)), 'replica', r.replica_server_name, 'database', DB_NAME(d.database_id)
FROM sys.dm_hadr_database_replica_states AS d
JOIN sys.availability_replicas AS r ON r.replica_id = d.replica_id
LEFT JOIN sys.availability_groups AS g ON g.group_id = d.group_id
CROSS APPLY (VALUES
    -- 2 synchronized, 1 synchronizing, 0 neither (or suspended).
    ('sync_state', CASE d.synchronization_state WHEN 2 THEN 2 WHEN 1 THEN 1 ELSE 0 END),
    ('suspended', CONVERT(int, d.is_suspended)),
    ('send_queue_bytes', ISNULL(d.log_send_queue_size, 0) * 1024.0),
    ('send_rate_bytes', ISNULL(d.log_send_rate, 0) * 1024.0),
    ('redo_queue_bytes', ISNULL(d.redo_queue_size, 0) * 1024.0),
    ('redo_rate_bytes', ISNULL(d.redo_rate, 0) * 1024.0),
    ('lag_seconds', ISNULL(d.secondary_lag_seconds, 0))
) AS x(name, v)
WHERE d.is_local = 0 OR NOT EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE role = 1 AND is_local = 1)
ORDER BY ISNULL(g.name, CONVERT(nvarchar(36), d.group_id)), r.replica_server_name, DB_NAME(d.database_id);
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
