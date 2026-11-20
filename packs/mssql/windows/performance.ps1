#Requires -Version 5.1

<#
.SYNOPSIS
    performance.ps1 - a SQL Server's workload counters, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports SQL Server's own counters: requests, transactions, compilations,
    logins, errors, the buffer pool's page life and hit ratio, I/O, locks and
    deadlocks, page splits, scans, memory grants, and the indexes the
    optimizer wished it had. One query, read-only, that never waits more than
    5 seconds for a lock and gives way in a deadlock.

    Connects to MSSQL_HOST and MSSQL_PORT as MSSQL_USER, with the password in
    SQLCMDPASSWORD, all set by the job; never on a command line; or, with
    MSSQL_AUTH=windows, as the account Vigil runs as, with no password. Always
    encrypted, the server's certificate checked against Windows' trusted CAs
    and the server's name: put your CA, or the server's own certificate, in
    the machine's Trusted Root store. It uses .NET's own SQL Server client:
    there is nothing to install.

    Metrics:
      batch_requests_count          requests run (a running total)
      compilations_count            query plans compiled (a running total)
      recompilations_count          plans compiled again (a running total)
      transactions_count            transactions started, all databases (a running
                                    total)
      logins_count                  logins (a running total)
      logouts_count                 logouts (a running total)
      processes_blocked             sessions waiting on another now
      errors_count                  errors raised (a running total)
      page_life_expectancy_seconds  how long a page stays in the buffer pool
      lazy_writes_count             pages written to free memory (a running total)
      checkpoint_pages_count        pages written by checkpoints (a running total)
      page_reads_count              pages read from disk (a running total)
      page_writes_count             pages written to disk (a running total)
      lock_waits_count              lock requests that had to wait (a running
                                    total)
      lock_timeouts_count           lock requests that gave up (a running total)
      deadlocks_count               deadlocks (a running total)
      page_splits_count             index pages split in two (a running total)
      full_scans_count              whole tables or indexes scanned (a running
                                    total)
      memory_grants_pending         queries waiting for memory to run
      memory_grants_outstanding     queries holding memory to run
      buffer_cache_hit_pct          pages found in memory, as a percent
      missing_indexes               indexes the optimizer wished for since the
                                    server started
      missing_index_top_impact_pct  the most one of them would improve its
                                    queries, as a percent

    Example output (the rest are in the same form):
      metric batch_requests_count 569
      metric page_life_expectancy_seconds 593
      metric deadlocks_count 0
      metric memory_grants_pending 0
      metric buffer_cache_hit_pct 100

    Reading the results (starting points: tune them to the server):
      Healthy  memory_grants_pending 0; deadlocks_count flat;
               page_life_expectancy_seconds steady.
      Watch    page_life_expectancy_seconds falling: memory is short for the
               data; compilations_count close to batch_requests_count: plans
               are not reused; lock_timeouts_count rising.
      Act      memory_grants_pending above 0 for minutes: queries wait for
               memory; deadlocks_count rising. The _count totals restart with
               the server: graph them as a rate.

    Requires: Windows PowerShell 5.1 or PowerShell 7, and a login with what
      packs/README.md says to grant
    Exit code: 0 on success, or when the server does not answer; 1 if the
      server refuses the login, its certificate or the query
#>

$ErrorActionPreference = 'Stop'
$me = 'performance'

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
-- SQL Server's own counters. Those named _count are running totals since it
-- started: graph them as rates.
DECLARE @c TABLE (id int IDENTITY PRIMARY KEY, name varchar(64), obj nvarchar(128), counter nvarchar(128), inst nvarchar(128));
INSERT @c (name, obj, counter, inst) VALUES
    ('batch_requests_count', N'SQL Statistics', N'Batch Requests/sec', N''),
    ('compilations_count', N'SQL Statistics', N'SQL Compilations/sec', N''),
    ('recompilations_count', N'SQL Statistics', N'SQL Re-Compilations/sec', N''),
    ('transactions_count', N'Databases', N'Transactions/sec', N'_Total'),
    ('logins_count', N'General Statistics', N'Logins/sec', N''),
    ('logouts_count', N'General Statistics', N'Logouts/sec', N''),
    ('processes_blocked', N'General Statistics', N'Processes blocked', N''),
    ('errors_count', N'SQL Errors', N'Errors/sec', N'_Total'),
    ('page_life_expectancy_seconds', N'Buffer Manager', N'Page life expectancy', N''),
    ('lazy_writes_count', N'Buffer Manager', N'Lazy writes/sec', N''),
    ('checkpoint_pages_count', N'Buffer Manager', N'Checkpoint pages/sec', N''),
    ('page_reads_count', N'Buffer Manager', N'Page reads/sec', N''),
    ('page_writes_count', N'Buffer Manager', N'Page writes/sec', N''),
    ('lock_waits_count', N'Locks', N'Lock Waits/sec', N'_Total'),
    ('lock_timeouts_count', N'Locks', N'Lock Timeouts/sec', N'_Total'),
    ('deadlocks_count', N'Locks', N'Number of Deadlocks/sec', N'_Total'),
    ('page_splits_count', N'Access Methods', N'Page Splits/sec', N''),
    ('full_scans_count', N'Access Methods', N'Full Scans/sec', N''),
    ('memory_grants_pending', N'Memory Manager', N'Memory Grants Pending', N''),
    ('memory_grants_outstanding', N'Memory Manager', N'Memory Grants Outstanding', N'');
INSERT @m (name, v)
SELECT c.name, p.value FROM @c AS c JOIN @pc AS p ON p.obj = c.obj AND p.counter = c.counter AND p.inst = c.inst ORDER BY c.id;
-- A ratio counter is two: the value and its base.
INSERT @m (name, v)
SELECT 'buffer_cache_hit_pct', CONVERT(decimal(38, 2), 100.0 * r.value / b.value)
FROM @pc AS r JOIN @pc AS b ON b.obj = r.obj AND b.counter = N'Buffer cache hit ratio base'
WHERE r.obj = N'Buffer Manager' AND r.counter = N'Buffer cache hit ratio' AND b.value > 0;
-- Indexes the optimizer wished it had, since the server started: how many,
-- and the most a single one would have improved its queries.
INSERT @m (name, v)
SELECT 'missing_indexes', COUNT(*) FROM sys.dm_db_missing_index_group_stats;
INSERT @m (name, v)
SELECT 'missing_index_top_impact_pct', ISNULL(MAX(CONVERT(decimal(38, 2), avg_user_impact)), 0) FROM sys.dm_db_missing_index_group_stats;
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
