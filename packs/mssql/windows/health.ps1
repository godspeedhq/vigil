#Requires -Version 5.1

<#
.SYNOPSIS
    health.ps1 - what keeps a SQL Server's databases safe, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each database's days since its last good integrity check (DBCC
    CHECKDB) and its virtual log files; files growing by a percentage, and
    those near their maximum size; free space on each volume that holds a
    database file; Express edition's 10 GB limit; encryption (TDE); and pages
    SQL Server found damaged. One query, read-only, that never waits more than
    5 seconds for a lock and gives way in a deadlock.

    Connects to MSSQL_HOST and MSSQL_PORT as MSSQL_USER, with the password in
    SQLCMDPASSWORD, all set by the job; never on a command line; or, with
    MSSQL_AUTH=windows, as the account Vigil runs as, with no password. Always
    encrypted, the server's certificate checked against Windows' trusted CAs
    and the server's name: put your CA, or the server's own certificate, in
    the machine's Trusted Root store. It uses .NET's own SQL Server client:
    there is nothing to install.

    Metrics:
      checkdb_age_days        days since the last DBCC CHECKDB that found nothing,
                              tagged database=; -1 never
      vlfs                    virtual log files in its log
      pct_growth_files        files that grow by a percentage
      max_size_used_pct       a file with a maximum size: how much of it is used,
                              tagged database=, file= and kind=
      volume_total_bytes      a volume with database files, tagged volume=
      volume_free_bytes       space free on it
      volume_free_pct         free as a percent
      express_limit_used_pct  Express edition: a database's data against its 10 GB
                              limit
      encryption_state        with transparent data encryption: 3 encrypted, 2
                              encrypting, 4 changing its key, 5 decrypting, 1 not
                              yet
      suspect_pages           pages found damaged (bad checksum, torn page, I/O
                              error) and not yet repaired

    Example output (the rest are in the same form):
      metric checkdb_age_days 3 database=shop
      metric vlfs 4 database=shop
      metric volume_free_pct 55.26 volume=/var/opt/mssql/
      metric suspect_pages 0

    Reading the results (starting points: tune them to the server):
      Healthy  checkdb_age_days 0 to 7; suspect_pages 0; volume_free_pct above
               20.
      Watch    checkdb_age_days above 7, or -1; vlfs in the thousands;
               pct_growth_files above 0.
      Act      suspect_pages above 0: run DBCC CHECKDB and restore what it
               finds; max_size_used_pct or express_limit_used_pct near 100:
               writes fail; volume_free_pct below 10.

    Requires: Windows PowerShell 5.1 or PowerShell 7, and a login with what
      packs/README.md says to grant
    Exit code: 0 on success, or when the server does not answer; 1 if the
      server refuses the login, its certificate or the query
#>

$ErrorActionPreference = 'Stop'
$me = 'health'

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
-- Every file of every database this login may open (CONNECT ANY DATABASE),
-- from each database's own sys.database_files: sys.master_files, which
-- has them all, needs a wider right (VIEW ANY DEFINITION).
DECLARE @f TABLE (database_id int NOT NULL, file_id int NOT NULL, kind nvarchar(10) NOT NULL, name nvarchar(128) NOT NULL,
    pages bigint NOT NULL, max_pages bigint NOT NULL, growth bigint NOT NULL, pct_growth bit NOT NULL, PRIMARY KEY (database_id, file_id));
DECLARE @fsql nvarchar(max) = N'';
SELECT @fsql = @fsql + N' UNION ALL SELECT ' + CONVERT(nvarchar(10), database_id)
    + N', file_id, CASE type WHEN 1 THEN N''log'' ELSE N''data'' END, name, size, max_size, growth, is_percent_growth FROM '
    + QUOTENAME(name) + N'.sys.database_files'
FROM sys.databases WHERE state = 0 AND user_access = 0 AND HAS_DBACCESS(name) = 1;
IF LEN(@fsql) > 0
BEGIN
    SET @fsql = STUFF(@fsql, 1, 11, N'');
    INSERT @f EXEC sys.sp_executesql @fsql;
END;
-- What keeps a database safe and able to grow: its last integrity check,
-- its log's shape, files near their limit, disk space, encryption, and
-- pages SQL Server found damaged. tempdb is left out where it does not
-- apply. At most 150 databases and 100 files, so a server with thousands
-- stays under Vigil's limit.
DECLARE @d TABLE (database_id int PRIMARY KEY, name nvarchar(128), checkdb datetime);
INSERT @d SELECT TOP (150) database_id, name, CONVERT(datetime, DATABASEPROPERTYEX(name, 'LastGoodCheckDbTime'))
FROM sys.databases WHERE state = 0 AND database_id <> 2 ORDER BY name;
-- Days since the last DBCC CHECKDB that found nothing; never checked, -1.
INSERT @m (name, v, k1, t1)
SELECT 'checkdb_age_days', CASE WHEN checkdb IS NULL OR checkdb < '19010101' THEN -1 ELSE DATEDIFF(day, checkdb, @now) END, 'database', name
FROM @d ORDER BY name;
-- Virtual log files: thousands make startup, restores and failovers slow.
INSERT @m (name, v, k1, t1)
SELECT 'vlfs', (SELECT COUNT(*) FROM sys.dm_db_log_info(d.database_id)), 'database', d.name FROM @d AS d ORDER BY d.name;
-- Files that grow by a percentage: each growth bigger, and slower, than the last.
INSERT @m (name, v, k1, t1)
SELECT 'pct_growth_files', COUNT(*), 'database', DB_NAME(database_id) FROM @f WHERE pct_growth = 1
GROUP BY database_id ORDER BY DB_NAME(database_id);
-- Files with a maximum size: how much of it they use (writes fail at 100).
INSERT @m (name, v, k1, t1, k2, t2, k3, t3)
SELECT TOP (100) 'max_size_used_pct', CONVERT(decimal(38, 2), 100.0 * pages / max_pages), 'database', DB_NAME(database_id), 'file', name, 'kind', kind
FROM @f WHERE max_pages > 0 ORDER BY 1.0 * pages / max_pages DESC;
-- Space on each volume that holds a database file.
DECLARE @v TABLE (mount nvarchar(256) PRIMARY KEY, total bigint, free bigint);
INSERT @v SELECT ISNULL(v.volume_mount_point, ISNULL(v.logical_volume_name, N'unknown')), MAX(v.total_bytes), MAX(v.available_bytes)
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS s CROSS APPLY sys.dm_os_volume_stats(s.database_id, s.file_id) AS v WHERE s.database_id IN (SELECT database_id FROM sys.databases)
GROUP BY ISNULL(v.volume_mount_point, ISNULL(v.logical_volume_name, N'unknown'));
INSERT @m (name, v, k1, t1)
SELECT x.name, x.v, 'volume', v.mount FROM @v AS v
CROSS APPLY (VALUES ('volume_total_bytes', v.total), ('volume_free_bytes', v.free),
    ('volume_free_pct', CONVERT(decimal(38, 2), 100.0 * v.free / NULLIF(v.total, 0)))) AS x(name, v)
WHERE x.v IS NOT NULL ORDER BY v.mount;
-- Express edition stops a database at 10 GB of data.
IF CONVERT(int, SERVERPROPERTY('EngineEdition')) = 4
    INSERT @m (name, v, k1, t1)
    SELECT 'express_limit_used_pct', CONVERT(decimal(38, 2), 100.0 * SUM(pages) / (10.0 * 1024 * 1024 * 1024 / 8192)), 'database', DB_NAME(database_id)
    FROM @f WHERE kind = N'data' AND database_id > 4 GROUP BY database_id ORDER BY DB_NAME(database_id);
-- Transparent data encryption: 3 encrypted, 2 encrypting, 4 changing its
-- key, 5 decrypting, 1 not yet, for each database with a key.
INSERT @m (name, v, k1, t1)
SELECT 'encryption_state', encryption_state, 'database', DB_NAME(database_id) FROM sys.dm_database_encryption_keys
WHERE database_id <> 2 ORDER BY DB_NAME(database_id);
-- Pages SQL Server found damaged (bad checksum, torn page, other I/O
-- errors), not yet repaired or restored: any is a reason to act.
INSERT @m (name, v) SELECT 'suspect_pages', COUNT(*) FROM msdb.dbo.suspect_pages WHERE event_type IN (1, 2, 3);
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
