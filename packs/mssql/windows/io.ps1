#Requires -Version 5.1

<#
.SYNOPSIS
    io.ps1 - a SQL Server's reads and writes, file by file, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each database file's reads, writes, bytes and the time spent
    waiting on them, since SQL Server started, and its size. The 120 files
    that have waited longest. One query, read-only, that never waits more than
    5 seconds for a lock and gives way in a deadlock.

    Connects to MSSQL_HOST and MSSQL_PORT as MSSQL_USER, with the password in
    SQLCMDPASSWORD, all set by the job; never on a command line; or, with
    MSSQL_AUTH=windows, as the account Vigil runs as, with no password. Always
    encrypted, the server's certificate checked against Windows' trusted CAs
    and the server's name: put your CA, or the server's own certificate, in
    the machine's Trusted Root store. It uses .NET's own SQL Server client:
    there is nothing to install.

    Metrics:
      reads_count           reads, tagged database=, file= and kind=<data or log>
                            (a running total)
      writes_count          writes (a running total)
      read_bytes_count      bytes read (a running total)
      written_bytes_count   bytes written (a running total)
      read_stall_ms_count   milliseconds spent waiting on reads (a running total)
      write_stall_ms_count  milliseconds spent waiting on writes (a running total)
      size_bytes            the file's size on disk
      files_not_shown       files beyond the 120 reported

    Example output (the rest are in the same form):
      metric reads_count 74 database=master file=master kind=data
      metric read_stall_ms_count 124 database=master file=master kind=data
      metric write_stall_ms_count 277 database=master file=mastlog kind=log
      metric size_bytes 4915200 database=master file=master kind=data

    Reading the results (starting points: tune them to the server):
      Healthy  latency (the stall's rate over the reads' or writes') below 10
               ms for data, 2 ms for a log.
      Watch    read latency 10 to 20 ms; a log's write latency above 5 ms.
      Act      read latency above 20 ms, or a log's write latency above 10 ms,
               for long: the disk is the bottleneck.

    Requires: Windows PowerShell 5.1 or PowerShell 7, and a login with what
      packs/README.md says to grant
    Exit code: 0 on success, or when the server does not answer; 1 if the
      server refuses the login, its certificate or the query
#>

$ErrorActionPreference = 'Stop'
$me = 'io'

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
-- Reads, writes and the time spent waiting on them, for each database file,
-- since SQL Server started (running totals: graph them as rates; latency is
-- the stall's rate over the reads' or writes'). The 120 files that have
-- waited longest, so a server with thousands stays under Vigil's limit.
INSERT @m (name, v, k1, t1, k2, t2, k3, t3)
SELECT x.name, x.v, 'database', DB_NAME(s.database_id), 'file', ISNULL(f.name, N'file' + CONVERT(nvarchar(10), s.file_id)),
    'kind', ISNULL(f.kind, CASE WHEN s.file_id = 2 THEN N'log' ELSE N'data' END)
FROM (SELECT TOP (120) * FROM sys.dm_io_virtual_file_stats(NULL, NULL) WHERE database_id IN (SELECT database_id FROM sys.databases) ORDER BY io_stall DESC) AS s
LEFT JOIN @f AS f ON f.database_id = s.database_id AND f.file_id = s.file_id
CROSS APPLY (VALUES
    ('reads_count', s.num_of_reads),
    ('writes_count', s.num_of_writes),
    ('read_bytes_count', s.num_of_bytes_read),
    ('written_bytes_count', s.num_of_bytes_written),
    ('read_stall_ms_count', s.io_stall_read_ms),
    ('write_stall_ms_count', s.io_stall_write_ms),
    ('size_bytes', s.size_on_disk_bytes)
) AS x(name, v)
ORDER BY DB_NAME(s.database_id), s.file_id;
INSERT @m (name, v)
SELECT 'files_not_shown', CASE WHEN COUNT(*) > 120 THEN COUNT(*) - 120 ELSE 0 END FROM sys.dm_io_virtual_file_stats(NULL, NULL) WHERE database_id IN (SELECT database_id FROM sys.databases);
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
