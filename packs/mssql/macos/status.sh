#!/usr/bin/env bash
#
# status.sh - a SQL Server's health
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
# Reports whether the server answers and what it is, how long it has run,
# its CPUs, its connections against the limit, and whether it is clustered,
# has Always On, and runs SQL Agent. One query, read-only, that never waits
# more than 5 seconds for a lock and gives way in a deadlock.
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
#   up               1 when the server answers, else 0
#   info             always 1, tagged release=<2019, 2022 or 2025>, version=<its
#                    build>, update=<its CU>, edition=<developer, enterprise,
#                    standard, express or web> and os=<linux or windows>
#   uptime_seconds   how long it has run
#   cpus             the CPUs it sees
#   schedulers       the schedulers it runs work on
#   connections      user connections now
#   connections_max  the most it allows
#   clustered        1 in a failover cluster instance
#   cluster_node     in a failover cluster: always 1, tagged node=<the node it
#                    runs on now>
#   hadr_enabled     1 when Always On availability groups are enabled
#   agent_running    SQL Agent: 1 running, 0 stopped; left out where there is
#                    none (Express)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric info 1 release=2022 version=16.0.4325.4 update=CU28 edition=developer os=linux
#   metric uptime_seconds 593
#   metric connections 2
#   metric agent_running 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  up 1; agent_running 1 where Agent runs the backups.
#   Watch    connections growing toward connections_max; uptime_seconds back
#            near 0: it restarted.
#   Act      up 0; agent_running 0 on a server whose backups Agent
#            schedules; cluster_node changing when no one moved it: it
#            failed over.
#
# Requires: bash, sqlcmd (mssql-tools18 or go-sqlcmd), and a login with what
#   packs/README.md says to grant
# Exit code: 0 on success, server up or down; 1 if the server refuses the
#   login, its certificate or the query, or sqlcmd is missing

set -u

me=status
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
-- What the server is, how long it has run, and its connections.
DECLARE @major int = CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @edition nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));
INSERT @m (name, v) VALUES ('up', 1);
INSERT @m (name, v, k1, t1, k2, t2, k3, t3, k4, t4, k5, t5)
SELECT 'info', 1,
    'release', CASE @major WHEN 15 THEN N'2019' WHEN 16 THEN N'2022' WHEN 17 THEN N'2025' ELSE CONVERT(nvarchar(10), @major) END,
    'version', CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')),
    'update', ISNULL(CONVERT(nvarchar(128), SERVERPROPERTY('ProductUpdateLevel')), CONVERT(nvarchar(128), SERVERPROPERTY('ProductLevel'))),
    -- 2025 names Developer "Enterprise Developer Edition": the kind first.
    'edition', CASE WHEN @edition LIKE N'%Developer%' THEN N'developer' WHEN @edition LIKE N'%Express%' THEN N'express'
        WHEN @edition LIKE N'%Evaluation%' THEN N'evaluation' ELSE LOWER(LEFT(@edition, CHARINDEX(N' ', @edition + N' ') - 1)) END,
    'os', LOWER((SELECT TOP (1) host_platform FROM sys.dm_os_host_info));
INSERT @m (name, v) SELECT 'uptime_seconds', DATEDIFF_BIG(second, sqlserver_start_time, @now) FROM sys.dm_os_sys_info;
INSERT @m (name, v) SELECT 'cpus', cpu_count FROM sys.dm_os_sys_info;
INSERT @m (name, v) SELECT 'schedulers', COUNT(*) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE';
INSERT @m (name, v) SELECT 'connections', value FROM @pc WHERE obj = N'General Statistics' AND counter = N'User Connections';
INSERT @m (name, v) VALUES ('connections_max', @@MAX_CONNECTIONS);
INSERT @m (name, v) VALUES ('clustered', ISNULL(CONVERT(int, SERVERPROPERTY('IsClustered')), 0));
INSERT @m (name, v) VALUES ('hadr_enabled', ISNULL(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), 0));
-- A failover cluster's current node.
IF CONVERT(int, SERVERPROPERTY('IsClustered')) = 1
    INSERT @m (name, v, k1, t1) VALUES ('cluster_node', 1, 'node', CONVERT(nvarchar(128), SERVERPROPERTY('ComputerNamePhysicalNetBIOS')));
-- SQL Agent runs the scheduled backups; Express has none.
INSERT @m (name, v) SELECT TOP (1) 'agent_running', CASE WHEN status_desc = N'Running' THEN 1 ELSE 0 END
    FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%';
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
        echo 'metric up 0'
        exit 0
        ;;
esac
echo "$me: the query failed: $why" >&2
exit 1
