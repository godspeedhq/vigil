#Requires -Version 5.1

<#
.SYNOPSIS
    backups.ps1 - how long since a SQL Server's databases were backed up, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports, from msdb's history, how long since each database's last full and
    differential backup, and for a database whose log needs backing up (full
    or bulk-logged recovery), its log; and how many databases have no full
    backup in 400 days. One query, read-only, that never waits more than 5
    seconds for a lock and gives way in a deadlock.

    Connects to MSSQL_HOST and MSSQL_PORT as MSSQL_USER, with the password in
    SQLCMDPASSWORD, all set by the job; never on a command line; or, with
    MSSQL_AUTH=windows, as the account Vigil runs as, with no password. Always
    encrypted, the server's certificate checked against Windows' trusted CAs
    and the server's name: put your CA, or the server's own certificate, in
    the machine's Trusted Root store. It uses .NET's own SQL Server client:
    there is nothing to install.

    Metrics:
      full_age_seconds  since the last full backup, tagged database=; -1 none in
                        400 days
      diff_age_seconds  since the last differential backup; -1 none
      log_age_seconds   since the last log backup (full or bulk-logged recovery);
                        -1 none
      never_backed_up   databases with no full backup in 400 days

    Example output (the rest are in the same form):
      metric full_age_seconds 86210 database=shop
      metric diff_age_seconds -1 database=shop
      metric log_age_seconds 912 database=shop
      metric never_backed_up 0

    Reading the results (starting points: tune them to the server):
      Healthy  full_age_seconds within your schedule (a day or a week);
               log_age_seconds within minutes to an hour.
      Watch    log_age_seconds growing past your schedule: the log grows and
               the data you can lose with it.
      Act      never_backed_up above 0; full_age_seconds -1 or far past the
               schedule: the backups stopped.

    Requires: Windows PowerShell 5.1 or PowerShell 7, and a login with what
      packs/README.md says to grant
    Exit code: 0 on success, or when the server does not answer; 1 if the
      server refuses the login, its certificate or the query
#>

$ErrorActionPreference = 'Stop'
$me = 'backups'

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
-- How long since each database was last backed up, from msdb's history:
-- full, differential, and for a database whose log needs backing up (full
-- or bulk-logged recovery), its log. -1: none in the last 400 days. At
-- most 150 databases, so a server with thousands stays under Vigil's limit.
DECLARE @b TABLE (name nvarchar(128), type char(1), last datetime, PRIMARY KEY (name, type));
INSERT @b SELECT database_name, type, MAX(backup_finish_date) FROM msdb.dbo.backupset
WHERE backup_finish_date > DATEADD(day, -400, @now) AND type IN ('D', 'I', 'L') GROUP BY database_name, type;
DECLARE @d TABLE (name nvarchar(128) PRIMARY KEY, recovery int);
INSERT @d SELECT TOP (150) name, recovery_model FROM sys.databases WHERE database_id <> 2 AND state = 0 AND source_database_id IS NULL ORDER BY name;
INSERT @m (name, v, k1, t1)
SELECT x.name, x.v, 'database', d.name FROM @d AS d
CROSS APPLY (VALUES
    ('full_age_seconds', ISNULL((SELECT DATEDIFF_BIG(second, last, @now) FROM @b WHERE name = d.name AND type = 'D'), -1)),
    -- master has full backups only.
    ('diff_age_seconds', CASE WHEN d.name = N'master' THEN NULL ELSE ISNULL((SELECT DATEDIFF_BIG(second, last, @now) FROM @b WHERE name = d.name AND type = 'I'), -1) END),
    -- Simple recovery (3) has no log backups.
    ('log_age_seconds', CASE WHEN d.recovery = 3 THEN NULL ELSE ISNULL((SELECT DATEDIFF_BIG(second, last, @now) FROM @b WHERE name = d.name AND type = 'L'), -1) END)
) AS x(name, v)
WHERE x.v IS NOT NULL ORDER BY d.name;
INSERT @m (name, v)
SELECT 'never_backed_up', COUNT(*) FROM @d AS d WHERE d.name <> N'tempdb' AND NOT EXISTS (SELECT 1 FROM @b WHERE name = d.name AND type = 'D');
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
