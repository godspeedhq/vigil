#!/usr/bin/env bash
#
# config.sh - a SQL Server's risky settings
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
# Reports settings that are risky or rarely suit at their default, as
# numbers to compare across servers and watch for change: memory,
# parallelism, features that run code outside SQL Server, the sa login and
# sysadmin logins, instant file initialization and locked pages. One query,
# read-only, that never waits more than 5 seconds for a lock and gives way
# in a deadlock.
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
#   max_server_memory_mb       max server memory
#   max_server_memory_default  1 when left at its default, so SQL Server may
#                              take the machine's memory
#   maxdop                     max degree of parallelism (0: all CPUs)
#   cost_threshold             cost threshold for parallelism
#   optimize_for_ad_hoc        1 when optimize for ad hoc workloads is on
#   xp_cmdshell                1 when xp_cmdshell is on
#   clr_enabled                1 when CLR is on
#   ole_automation             1 when OLE Automation Procedures are on
#   remote_admin_connections   1 when the dedicated admin connection takes
#                              remote clients
#   sa_enabled                 1 when the sa login is enabled
#   sysadmins                  enabled logins in the sysadmin role
#   instant_file_init          1 when instant file initialization is on
#                              (Windows)
#   locked_pages               1 when its memory is locked in place
#
# Example output (the rest are in the same form):
#   metric max_server_memory_default 1
#   metric maxdop 0
#   metric cost_threshold 5
#   metric xp_cmdshell 0
#   metric sa_enabled 1
#
# Reading the results (starting points: tune them to the server):
#   Healthy  max_server_memory_default 0; xp_cmdshell, clr_enabled and
#            ole_automation 0 unless needed.
#   Watch    cost_threshold 5 (the default) on a busy server; sysadmins
#            growing.
#   Act      xp_cmdshell 1 where nothing needs it; sa_enabled 1 with a weak
#            password; any of them changing when no one meant to.
#
# Requires: bash, sqlcmd (mssql-tools18 or go-sqlcmd), and a login with what
#   packs/README.md says to grant
# Exit code: 0 on success, or when the server does not answer; 1 if the
#   server refuses the login, its certificate or the query, or sqlcmd is
#   missing

set -u

me=config
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
-- Settings that are risky, or left at a default that rarely suits, as
-- numbers a dashboard can compare across servers or watch for change.
DECLARE @cfg TABLE (name nvarchar(70) PRIMARY KEY, v bigint);
INSERT @cfg SELECT name, CONVERT(bigint, value_in_use) FROM sys.configurations;
INSERT @m (name, v) SELECT 'max_server_memory_mb', v FROM @cfg WHERE name = N'max server memory (MB)';
-- Left at its default, SQL Server may take the machine's memory.
INSERT @m (name, v) SELECT 'max_server_memory_default', CASE WHEN v >= 2147483647 THEN 1 ELSE 0 END FROM @cfg WHERE name = N'max server memory (MB)';
INSERT @m (name, v) SELECT 'maxdop', v FROM @cfg WHERE name = N'max degree of parallelism';
INSERT @m (name, v) SELECT 'cost_threshold', v FROM @cfg WHERE name = N'cost threshold for parallelism';
INSERT @m (name, v) SELECT 'optimize_for_ad_hoc', v FROM @cfg WHERE name = N'optimize for ad hoc workloads';
-- Features that run code outside SQL Server: off unless needed.
INSERT @m (name, v) SELECT 'xp_cmdshell', v FROM @cfg WHERE name = N'xp_cmdshell';
INSERT @m (name, v) SELECT 'clr_enabled', v FROM @cfg WHERE name = N'clr enabled';
INSERT @m (name, v) SELECT 'ole_automation', v FROM @cfg WHERE name = N'Ole Automation Procedures';
INSERT @m (name, v) SELECT 'remote_admin_connections', v FROM @cfg WHERE name = N'remote admin connections';
-- The sa login, and how many logins are sysadmin.
INSERT @m (name, v) SELECT 'sa_enabled', CASE WHEN is_disabled = 0 THEN 1 ELSE 0 END FROM sys.server_principals WHERE sid = 0x01;
INSERT @m (name, v)
SELECT 'sysadmins', COUNT(*) FROM sys.server_role_members AS rm JOIN sys.server_principals AS p ON p.principal_id = rm.member_principal_id
WHERE rm.role_principal_id = SUSER_ID(N'sysadmin') AND p.is_disabled = 0;
-- Faster file growth, and memory Windows cannot page out.
INSERT @m (name, v)
SELECT TOP (1) 'instant_file_init', CASE WHEN instant_file_initialization_enabled = N'Y' THEN 1 ELSE 0 END
FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server (%';
INSERT @m (name, v) SELECT 'locked_pages', CASE WHEN sql_memory_model > 1 THEN 1 ELSE 0 END FROM sys.dm_os_sys_info;
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
