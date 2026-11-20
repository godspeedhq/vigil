#Requires -Version 5.1

<#
.SYNOPSIS
    databases.ps1 - a SQL Server's databases, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each database's state, recovery model, size, its log's size and
    use and what keeps the log from being reused, open transactions,
    compatibility level against the server's, and Query Store's state. The 75
    biggest. One query, read-only, that never waits more than 5 seconds for a
    lock and gives way in a deadlock.

    Connects to MSSQL_HOST and MSSQL_PORT as MSSQL_USER, with the password in
    SQLCMDPASSWORD, all set by the job; never on a command line; or, with
    MSSQL_AUTH=windows, as the account Vigil runs as, with no password. Always
    encrypted, the server's certificate checked against Windows' trusted CAs
    and the server's name: put your CA, or the server's own certificate, in
    the machine's Trusted Root store. It uses .NET's own SQL Server client:
    there is nothing to install.

    Metrics:
      databases             databases on the server
      databases_not_shown   databases beyond the 75 reported
      online                1 when online, tagged database=
      state                 0 online, 1 restoring, 2 recovering, 3 recovery
                            pending, 4 suspect, 5 emergency, 6 offline; tagged
                            state=
      read_only             1 when read-only
      recovery              always 1, tagged model=<full, bulk_logged or simple>
      data_bytes            its data files
      log_bytes             its log
      log_used_bytes        its log in use
      log_used_pct          its log in use, as a percent
      log_reuse_waiting     1 when something keeps the log from being reused,
                            tagged reason=<log_backup, active_transaction,
                            replication and the like, or nothing>
      active_transactions   transactions open in it
      compatibility_level   its compatibility level
      compatibility_behind  1 when below the server's own
      query_store           0 off, 1 read only (often full), 2 read and write, 3
                            in error

    Example output (the rest are in the same form):
      metric online 1 database=shop
      metric recovery 1 database=shop model=full
      metric log_used_pct 11 database=shop
      metric log_reuse_waiting 0 database=shop reason=nothing
      metric query_store 2 database=shop

    Reading the results (starting points: tune them to the server):
      Healthy  online 1; log_used_pct below 70; log_reuse_waiting 0 or
               reason=log_backup between log backups.
      Watch    log_used_pct above 70 and rising; query_store 1 where it should
               record; compatibility_behind 1 after an upgrade.
      Act      online 0 or state 4 (suspect); log_used_pct near 100: writes
               stop when the log cannot grow; log_reuse_waiting with
               reason=active_transaction for long.

    Requires: Windows PowerShell 5.1 or PowerShell 7, and a login with what
      packs/README.md says to grant
    Exit code: 0 on success, or when the server does not answer; 1 if the
      server refuses the login, its certificate or the query
#>

$ErrorActionPreference = 'Stop'
$me = 'databases'

# The query, which prints finished metric lines, so every platform's script
# prints the same.
$sql = @'
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
-- Each database: whether it is online, how big it is, how full its log is
-- and why that log cannot be reused, and its settings. The 75 biggest, so a
-- server with hundreds stays under Vigil's limit.
DECLARE @d TABLE (database_id int PRIMARY KEY, name nvarchar(128), state int, read_only bit, recovery nvarchar(60),
    compat int, reuse nvarchar(60), data_kb bigint, log_kb bigint, log_used_kb bigint, log_pct int, active bigint);
INSERT @d
SELECT TOP (75) d.database_id, d.name, d.state, d.is_read_only, d.recovery_model_desc, d.compatibility_level, d.log_reuse_wait_desc,
    ds.value, ls.value, lu.value, lp.value, a.value
FROM sys.databases AS d
LEFT JOIN @pc AS ds ON ds.obj = N'Databases' AND ds.counter = N'Data File(s) Size (KB)' AND ds.inst = d.name
LEFT JOIN @pc AS ls ON ls.obj = N'Databases' AND ls.counter = N'Log File(s) Size (KB)' AND ls.inst = d.name
LEFT JOIN @pc AS lu ON lu.obj = N'Databases' AND lu.counter = N'Log File(s) Used Size (KB)' AND lu.inst = d.name
LEFT JOIN @pc AS lp ON lp.obj = N'Databases' AND lp.counter = N'Percent Log Used' AND lp.inst = d.name
LEFT JOIN @pc AS a ON a.obj = N'Databases' AND a.counter = N'Active Transactions' AND a.inst = d.name
ORDER BY ISNULL(ds.value, 0) DESC, d.name;
-- Query Store, from each database that can be opened: 0 off, 1 read only
-- (often because it is full), 2 read and write, 3 in error.
DECLARE @q TABLE (database_id int PRIMARY KEY, state int);
DECLARE @qsql nvarchar(max) = N'';
SELECT @qsql = @qsql + N' UNION ALL SELECT ' + CONVERT(nvarchar(10), d.database_id) + N', actual_state FROM '
    + QUOTENAME(d.name) + N'.sys.database_query_store_options'
FROM @d AS dd JOIN sys.databases AS d ON d.database_id = dd.database_id
WHERE d.state = 0 AND d.user_access = 0 AND HAS_DBACCESS(d.name) = 1 AND d.database_id NOT IN (2, 3);
IF LEN(@qsql) > 0
BEGIN
    SET @qsql = STUFF(@qsql, 1, 11, N'');
    INSERT @q EXEC sys.sp_executesql @qsql;
END;
DECLARE @server_compat int = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) * 10;

INSERT @m (name, v) SELECT 'databases', COUNT(*) FROM sys.databases;
INSERT @m (name, v) SELECT 'databases_not_shown', CASE WHEN COUNT(*) > 75 THEN COUNT(*) - 75 ELSE 0 END FROM sys.databases;
INSERT @m (name, v, k1, t1, k2, t2, k3, t3)
SELECT x.name, x.v, 'database', d.name, x.k2, x.t2, x.k3, x.t3
FROM @d AS d
LEFT JOIN @q AS q ON q.database_id = d.database_id
CROSS APPLY (VALUES
    ('online', CASE WHEN d.state = 0 THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL),
    -- 0 online, 1 restoring, 2 recovering, 3 recovery pending, 4 suspect,
    -- 5 emergency, 6 offline.
    ('state', d.state, 'state', LOWER(REPLACE((SELECT state_desc FROM sys.databases WHERE database_id = d.database_id), N' ', N'_')), NULL, NULL),
    ('read_only', CONVERT(int, d.read_only), NULL, NULL, NULL, NULL),
    ('recovery', 1, 'model', LOWER(d.recovery), NULL, NULL),
    ('data_bytes', ISNULL(d.data_kb, 0) * 1024.0, NULL, NULL, NULL, NULL),
    ('log_bytes', ISNULL(d.log_kb, 0) * 1024.0, NULL, NULL, NULL, NULL),
    ('log_used_bytes', ISNULL(d.log_used_kb, 0) * 1024.0, NULL, NULL, NULL, NULL),
    ('log_used_pct', ISNULL(d.log_pct, 0), NULL, NULL, NULL, NULL),
    -- What keeps the log from being reused: 0 nothing, 1 something, named.
    ('log_reuse_waiting', CASE WHEN d.reuse = N'NOTHING' THEN 0 ELSE 1 END, 'reason', LOWER(d.reuse), NULL, NULL),
    ('active_transactions', ISNULL(d.active, 0), NULL, NULL, NULL, NULL),
    ('compatibility_level', d.compat, NULL, NULL, NULL, NULL),
    ('compatibility_behind', CASE WHEN d.compat < @server_compat THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL)
) AS x(name, v, k2, t2, k3, t3)
ORDER BY d.name;
INSERT @m (name, v, k1, t1)
SELECT 'query_store', q.state, 'database', d.name FROM @q AS q JOIN @d AS d ON d.database_id = q.database_id ORDER BY d.name;
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
'@

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
        exit 0
    }
    [Console]::Error.WriteLine("${me}: the query failed: $why")
    exit 1
}
finally { $conn.Dispose() }
foreach ($l in $lines) { if ($l.StartsWith('metric ')) { Write-Output $l } }
exit 0
