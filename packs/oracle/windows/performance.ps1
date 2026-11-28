#Requires -Version 5.1

<#
.SYNOPSIS
    performance.ps1 - an Oracle database's workload counters, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the instance's own counters since it started: executions, calls,
    commits and rollbacks, logons, parses, reads and writes, redo, network,
    disk sorts, long scans, deadlocks and lock timeouts; time in the database
    and on CPU; the machine's CPU; and the buffer cache's hit ratio. One
    query, read-only, from Oracle's basic dynamic performance views and the
    data dictionary: nothing from the Diagnostics or Tuning Pack (no ASH, no
    AWR, no V$SYSMETRIC).

    Connects with SQL*Plus (Oracle Instant Client) to ORACLE_HOST, ORACLE_PORT
    and ORACLE_SERVICE, the service of the CDB root (or of a database that is
    not a CDB), as ORACLE_USER, with the password in ORACLE_PASSWORD, all set
    by the job. The password goes to SQL*Plus on its standard input, never on
    a command line. Oracle Net's encryption and integrity checks are required,
    by settings of the job's own (it never reads the machine's sqlnet.ora): a
    server that refuses them refuses the job.

    Metrics:
      executions_count        SQL statements executed (a running total)
      user_calls_count        calls from clients (a running total)
      commits_count           commits (a running total)
      rollbacks_count         rollbacks (a running total)
      logons_count            logons (a running total)
      logons_current          sessions logged on now
      parses_count            statements parsed (a running total)
      hard_parses_count       parsed from scratch, with no shared cursor (a
                              running total)
      parse_failures_count    parses that failed (a running total)
      logical_reads_count     blocks read, from memory or disk (a running total)
      physical_reads_count    blocks read from disk (a running total)
      physical_writes_count   blocks written to disk (a running total)
      redo_bytes_count        redo generated (a running total)
      bytes_received_count    bytes from clients (a running total)
      bytes_sent_count        bytes to clients (a running total)
      disk_sorts_count        sorts too big for memory (a running total)
      long_table_scans_count  whole scans of large tables (a running total)
      deadlocks_count         deadlocks (a running total)
      lock_timeouts_count     lock requests that timed out (a running total)
      open_cursors            cursors open now
      db_time_ms_count        time sessions spent in the database, waiting or
                              working, in ms (a running total)
      db_cpu_ms_count         of that, on CPU (a running total)
      host_busy_ms_count      the machine's CPUs busy, summed, in ms (a running
                              total)
      host_idle_ms_count      and idle (a running total)
      buffer_cache_hit_pct    blocks found in memory, as a percent, since the
                              instance started

    Example output (the rest are in the same form):
      metric executions_count 269816
      metric commits_count 39
      metric hard_parses_count 4268
      metric db_time_ms_count 57102
      metric buffer_cache_hit_pct 98.71

    Reading the results (starting points: tune them to the database):
      Healthy  db_time_ms_count's rate steady with the workload;
               deadlocks_count flat.
      Watch    hard_parses_count close to parses_count: statements are not
               shared (literals, not bind variables); db_cpu_ms_count's rate a
               small share of db_time's: sessions mostly wait (oracle_waits
               says on what).
      Act      deadlocks_count rising; db_time_ms_count's rate far above its
               usual. The _count totals restart with the instance: graph them
               as a rate.

    Requires: Windows PowerShell 5.1 or PowerShell 7, SQL*Plus (Oracle
      Instant Client, basic and sqlplus), and a user with what
      packs/oracle/README.md says to grant
    Exit code: 0 on success, or when the database does not answer; 1 if the
      database refuses the login or the query, or SQL*Plus is missing
#>

$ErrorActionPreference = 'Stop'
$me = 'performance'

# The query, which prints finished metric lines, so every platform's script
# prints the same.
$sql = @'
-- Numbers with a full stop, whatever the client's or the server's language.
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
-- Each reading: an order, a metric name, its value, and up to five tags
-- whose values the footer makes safe. The first row only fixes the types.
WITH m (s, n, v, k1, t1, k2, t2, k3, t3, k4, t4, k5, t5) AS (
SELECT 0, CAST(NULL AS VARCHAR2(64)), CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR2(32)), CAST(NULL AS VARCHAR2(512)),
    CAST(NULL AS VARCHAR2(32)), CAST(NULL AS VARCHAR2(512)), CAST(NULL AS VARCHAR2(32)), CAST(NULL AS VARCHAR2(512)),
    CAST(NULL AS VARCHAR2(32)), CAST(NULL AS VARCHAR2(512)), CAST(NULL AS VARCHAR2(32)), CAST(NULL AS VARCHAR2(512))
FROM dual WHERE 1 = 0
-- The instance's own counters since it started, read from V$SYSSTAT,
-- V$SYS_TIME_MODEL and V$OSSTAT, none of them in a paid pack: running
-- totals, to graph as a rate.
UNION ALL SELECT 1, x.n, SUM(s.value), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$sysstat s
    JOIN (SELECT 'execute count' AS stat, 'executions_count' AS n FROM dual
          UNION ALL SELECT 'user calls', 'user_calls_count' FROM dual
          UNION ALL SELECT 'user commits', 'commits_count' FROM dual
          UNION ALL SELECT 'user rollbacks', 'rollbacks_count' FROM dual
          UNION ALL SELECT 'logons cumulative', 'logons_count' FROM dual
          UNION ALL SELECT 'parse count (total)', 'parses_count' FROM dual
          UNION ALL SELECT 'parse count (hard)', 'hard_parses_count' FROM dual
          UNION ALL SELECT 'parse count (failures)', 'parse_failures_count' FROM dual
          UNION ALL SELECT 'session logical reads', 'logical_reads_count' FROM dual
          UNION ALL SELECT 'physical reads', 'physical_reads_count' FROM dual
          UNION ALL SELECT 'physical writes', 'physical_writes_count' FROM dual
          UNION ALL SELECT 'redo size', 'redo_bytes_count' FROM dual
          UNION ALL SELECT 'bytes received via SQL*Net from client', 'bytes_received_count' FROM dual
          UNION ALL SELECT 'bytes sent via SQL*Net to client', 'bytes_sent_count' FROM dual
          UNION ALL SELECT 'sorts (disk)', 'disk_sorts_count' FROM dual
          UNION ALL SELECT 'table scans (long tables)', 'long_table_scans_count' FROM dual
          UNION ALL SELECT 'enqueue deadlocks', 'deadlocks_count' FROM dual
          UNION ALL SELECT 'enqueue timeouts', 'lock_timeouts_count' FROM dual
          UNION ALL SELECT 'logons current', 'logons_current' FROM dual
          UNION ALL SELECT 'opened cursors current', 'open_cursors' FROM dual) x ON x.stat = s.name
    GROUP BY x.n
-- Time sessions spent in the database, and on CPU, in milliseconds.
UNION ALL SELECT 2, CASE stat_name WHEN 'DB time' THEN 'db_time_ms_count' ELSE 'db_cpu_ms_count' END, ROUND(SUM(value) / 1000),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$sys_time_model WHERE stat_name IN ('DB time', 'DB CPU') GROUP BY stat_name
-- The machine's CPUs, busy and idle, in milliseconds (summed over CPUs).
UNION ALL SELECT 3, CASE stat_name WHEN 'BUSY_TIME' THEN 'host_busy_ms_count' ELSE 'host_idle_ms_count' END, value * 10,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$osstat WHERE stat_name IN ('BUSY_TIME', 'IDLE_TIME')
-- Blocks found in the buffer cache, as a percent, since the instance started.
UNION ALL SELECT 4, 'buffer_cache_hit_pct',
    ROUND(100 * (1 - SUM(CASE name WHEN 'physical reads cache' THEN value END)
        / NULLIF(SUM(CASE WHEN name IN ('consistent gets from cache', 'db block gets from cache') THEN value END), 0)), 2),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$sysstat WHERE name IN ('physical reads cache', 'consistent gets from cache', 'db block gets from cache')
)
-- The readings as metric lines, in order. A value has at most two
-- decimals and a 0 before its point. A tag value keeps A-Z, a-z, 0-9, _, .
-- and -, has anything else as _, and is "none" when empty. At most 1000
-- lines: Vigil reads no more from one run.
SELECT 'metric ' || n || ' ' || REGEXP_REPLACE(TO_CHAR(ROUND(v, 2), 'TM9'), '^(-?)\.', '\10.')
    || CASE WHEN k1 IS NOT NULL THEN ' ' || k1 || '=' || NVL(REGEXP_REPLACE(t1, '[^A-Za-z0-9_.-]', '_'), 'none') END
    || CASE WHEN k2 IS NOT NULL THEN ' ' || k2 || '=' || NVL(REGEXP_REPLACE(t2, '[^A-Za-z0-9_.-]', '_'), 'none') END
    || CASE WHEN k3 IS NOT NULL THEN ' ' || k3 || '=' || NVL(REGEXP_REPLACE(t3, '[^A-Za-z0-9_.-]', '_'), 'none') END
    || CASE WHEN k4 IS NOT NULL THEN ' ' || k4 || '=' || NVL(REGEXP_REPLACE(t4, '[^A-Za-z0-9_.-]', '_'), 'none') END
    || CASE WHEN k5 IS NOT NULL THEN ' ' || k5 || '=' || NVL(REGEXP_REPLACE(t5, '[^A-Za-z0-9_.-]', '_'), 'none') END
FROM m WHERE v IS NOT NULL
ORDER BY s, t1, t2, t3, n
FETCH FIRST 1000 ROWS ONLY;
'@

# SQL*Plus: ORACLE_SQLPLUS, else the one on the PATH, else ORACLE_HOME's.
$client = $env:ORACLE_SQLPLUS
if (-not $client) { $c = Get-Command sqlplus.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $client = $c.Source } }
if (-not $client -and $env:ORACLE_HOME -and (Test-Path -LiteralPath (Join-Path $env:ORACLE_HOME 'bin\sqlplus.exe'))) { $client = Join-Path $env:ORACLE_HOME 'bin\sqlplus.exe' }
if (-not $client -or -not (Test-Path -LiteralPath $client)) { [Console]::Error.WriteLine("${me}: sqlplus not found: install Oracle Instant Client (basic and sqlplus), and put it on the PATH or set ORACLE_SQLPLUS"); exit 1 }
if (-not $env:ORACLE_PASSWORD) { [Console]::Error.WriteLine("${me}: no password: the job's secret line gives ORACLE_PASSWORD"); exit 1 }
if (-not $env:ORACLE_SERVICE) { [Console]::Error.WriteLine("${me}: no ORACLE_SERVICE: set it to the service of the CDB root (or of a database that is not a CDB)"); exit 1 }
if ($env:ORACLE_PASSWORD.Contains('"')) { [Console]::Error.WriteLine("${me}: the password holds a double quote, which an Oracle password cannot"); exit 1 }
$user = if ($env:ORACLE_USER) { $env:ORACLE_USER } else { 'C##VIGIL_MONITOR' }
$hostName = if ($env:ORACLE_HOST) { $env:ORACLE_HOST } else { 'localhost' }
$port = if ($env:ORACLE_PORT) { $env:ORACLE_PORT } else { '1521' }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-oracle.' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # Oracle Net settings of the job's own, never the machine's: encryption
    # and integrity required, and no wait longer than 10 seconds to connect.
    [System.IO.File]::WriteAllText((Join-Path $work 'sqlnet.ora'), @'
SQLNET.ENCRYPTION_CLIENT = REQUIRED
SQLNET.ENCRYPTION_TYPES_CLIENT = (AES256, AES192, AES128)
SQLNET.CRYPTO_CHECKSUM_CLIENT = REQUIRED
SQLNET.CRYPTO_CHECKSUM_TYPES_CLIENT = (SHA256, SHA384, SHA512)
SQLNET.OUTBOUND_CONNECT_TIMEOUT = 10
TCP.CONNECT_TIMEOUT = 10
NAMES.DIRECTORY_PATH = (EZCONNECT)
'@)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $client
    $psi.Arguments = '-s -L /nolog'
    $psi.WorkingDirectory = $work
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['TNS_ADMIN'] = $work
    $psi.EnvironmentVariables['NLS_LANG'] = 'AMERICAN_AMERICA.AL32UTF8'
    # No login.sql of anyone's: SQL*Plus runs one from these, and from where
    # it starts.
    foreach ($v in 'SQLPATH', 'ORACLE_PATH', 'TWO_TASK', 'LOCAL') { $psi.EnvironmentVariables.Remove($v) }
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    # The password on SQL*Plus's standard input: on no command line.
    $in = $p.StandardInput
    $in.NewLine = "`n"
    $in.WriteLine('WHENEVER SQLERROR EXIT 3')
    $in.WriteLine('WHENEVER OSERROR EXIT 4')
    $in.WriteLine('SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 4000 TRIMOUT ON TAB OFF VERIFY OFF ECHO OFF')
    $in.WriteLine('SET DEFINE OFF SQLBLANKLINES ON SERVEROUTPUT OFF TERMOUT ON')
    $in.WriteLine('CONNECT ' + $user + '/"' + $env:ORACLE_PASSWORD + '"@//' + $hostName + ':' + $port + '/' + $env:ORACLE_SERVICE)
    $in.Write($sql.Replace("`r`n", "`n"))
    $in.WriteLine('EXIT')
    $in.Close()
    $p.WaitForExit()
    $out = $outTask.Result + $errTask.Result
    $rc = $p.ExitCode
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

if ($rc -eq 0) {
    foreach ($l in ($out -split "`r?`n")) { if ($l.StartsWith('metric ')) { Write-Output $l } }
    exit 0
}
$code = ''
if ($out -match 'ORA-(\d{5})') { $code = $Matches[1] }
$why = (($out -split "`r?`n") | Where-Object { $_ -match 'ORA-\d{5}|SP2-\d{4}|TNS-\d{5}' } | Select-Object -First 3) -join ' '
if (-not $why) { $why = ($out -replace '\s+', ' ').Trim() }
# It could not be reached, or is not open: a reading, not a failure. A
# refused login and a failed query are failures.
$reasons = [ordered]@{
    '12541' = 'no_listener'
    '12514|12505|12521' = 'service_unknown'
    '01033|01034|01089|01090|12526|12528' = 'not_open'
    '01035' = 'restricted'
    '12170|12535|12171' = 'timeout'
    '12543|12545|12537|12547|12560|03113|03114|03135' = 'unreachable'
}
foreach ($k in $reasons.Keys) {
    if ($code -and ($k.Split('|') -contains $code)) {
        exit 0
    }
}
[Console]::Error.WriteLine("${me}: the query failed: $why")
exit 1
