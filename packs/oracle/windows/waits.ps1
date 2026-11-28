#Requires -Version 5.1

<#
.SYNOPSIS
    waits.ps1 - where an Oracle database spends its time waiting, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the time the instance's sessions waited since it started, by wait
    class, and its ten most costly wait events. Idle waits are left out. One
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
      wait_ms_count      milliseconds waited, tagged class=<user_i_o, system_i_o,
                         commit, concurrency, application, configuration, network,
                         scheduler, cluster, other...> (a running total)
      waits_count        waits (a running total)
      top_wait_ms_count  milliseconds waited on one of the ten most costly events,
                         tagged event= (a running total)
      top_waits_count    waits on that event (a running total)

    Example output (the rest are in the same form):
      metric wait_ms_count 6020 class=user_i_o
      metric wait_ms_count 550 class=commit
      metric top_wait_ms_count 4435 event=db_file_sequential_read
      metric top_waits_count 9468 event=db_file_sequential_read

    Reading the results (starting points: tune them to the database):
      Healthy  each class's rate steady with the workload.
      Watch    user_i_o rising: reads from disk (the data does not fit in the
               buffer cache, or the disk is slow); commit rising: the redo
               log's disk is slow (log file sync); concurrency: latches and
               buffer contention.
      Act      application rising: row locks (enq: TX - row lock contention):
               blocking, see oracle_activity; configuration rising: log
               switches waiting or space (oracle_recovery). The totals restart
               with the instance: graph them as a rate.

    Requires: Windows PowerShell 5.1 or PowerShell 7, SQL*Plus (Oracle
      Instant Client, basic and sqlplus), and a user with what
      packs/oracle/README.md says to grant
    Exit code: 0 on success, or when the database does not answer; 1 if the
      database refuses the login or the query, or SQL*Plus is missing
#>

$ErrorActionPreference = 'Stop'
$me = 'waits'

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
-- Where the instance's sessions have waited since it started, by class,
-- and its ten most costly wait events. Idle waits are left out.
UNION ALL SELECT 1, 'wait_ms_count', time_waited * 10, 'class', LOWER(REPLACE(wait_class, ' ', '_')),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$system_wait_class WHERE wait_class <> 'Idle'
UNION ALL SELECT 2, 'waits_count', total_waits, 'class', LOWER(REPLACE(wait_class, ' ', '_')),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$system_wait_class WHERE wait_class <> 'Idle'
UNION ALL SELECT 3, x.n, x.v, 'event', e.event, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT event, time_waited_micro, total_waits FROM v$system_event WHERE wait_class <> 'Idle'
          ORDER BY time_waited_micro DESC FETCH FIRST 10 ROWS ONLY) e
    CROSS APPLY (SELECT 'top_wait_ms_count' AS n, ROUND(e.time_waited_micro / 1000) AS v FROM dual
                 UNION ALL SELECT 'top_waits_count', e.total_waits FROM dual) x
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
    '01033|01034|01089|01090|12528' = 'not_open'
    '01035|12526' = 'restricted'
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
