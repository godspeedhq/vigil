#Requires -Version 5.1

<#
.SYNOPSIS
    activity.ps1 - what an Oracle database is doing now, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports user sessions by state, what the active ones are doing (on CPU or
    waiting, by the wait's class), sessions blocked and the sessions at the
    head of a blocking chain, the longest call running, transactions and the
    oldest, sessions asleep with a transaction open, and long operations still
    running. Every container's; its own session left out. One query,
    read-only, from Oracle's basic dynamic performance views and the data
    dictionary: nothing from the Diagnostics or Tuning Pack (no ASH, no AWR,
    no V$SYSMETRIC).

    Connects with SQL*Plus (Oracle Instant Client) to ORACLE_HOST, ORACLE_PORT
    and ORACLE_SERVICE, the service of the CDB root (or of a database that is
    not a CDB), as ORACLE_USER, with the password in ORACLE_PASSWORD, all set
    by the job. The password goes to SQL*Plus on its standard input, never on
    a command line. Oracle Net's encryption and integrity checks are required,
    by settings of the job's own (it never reads the machine's sqlnet.ora): a
    server that refuses them refuses the job.

    Metrics:
      sessions                     user sessions, tagged state=<active, inactive,
                                   killed and the like>
      active                       active ones, tagged class=<cpu, or the class of
                                   their wait: user_i_o, concurrency,
                                   application...>
      blocked                      sessions waiting on another
      longest_blocked_seconds      how long the longest of them has waited
      head_blockers                sessions that block others and wait on no one
      longest_active_seconds       how long the longest call running has run
      transactions                 transactions open
      oldest_transaction_seconds   how long the oldest has been open
      idle_in_transaction          sessions asleep with a transaction open
      idle_in_transaction_seconds  how long the longest of them has slept
      long_operations              long operations (scans, sorts, backups) still
                                   running

    Example output (the rest are in the same form):
      metric sessions 4 state=active
      metric active 1 class=application
      metric blocked 1
      metric head_blockers 1
      metric oldest_transaction_seconds 95

    Reading the results (starting points: tune them to the database):
      Healthy  blocked and head_blockers 0; idle_in_transaction 0.
      Watch    oldest_transaction_seconds in minutes: it holds locks and undo;
               longest_active_seconds growing past what the application runs.
      Act      head_blockers above 0 for minutes: one session holds up others,
               find it (V$SESSION's BLOCKING_SESSION); idle_in_transaction
               above 0 for long: an application that did not commit.

    Requires: Windows PowerShell 5.1 or PowerShell 7, SQL*Plus (Oracle
      Instant Client, basic and sqlplus), and a user with what
      packs/oracle/README.md says to grant
    Exit code: 0 on success, or when the database does not answer; 1 if the
      database refuses the login or the query, or SQL*Plus is missing
#>

$ErrorActionPreference = 'Stop'
$me = 'activity'

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
-- User sessions now, in every container: their state, what the active ones
-- wait on, blocking, the longest call and transaction. This job's own
-- session is left out.
-- Active and inactive always, even at 0; killed and the rest when there are any.
UNION ALL SELECT 1, 'sessions', COUNT(s.sid), 'state', LOWER(k.status), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT 'ACTIVE' AS status FROM dual UNION ALL SELECT 'INACTIVE' FROM dual
          UNION SELECT status FROM v$session WHERE type = 'USER') k
    LEFT JOIN v$session s ON s.status = k.status AND s.type = 'USER' AND s.sid <> SYS_CONTEXT('USERENV', 'SID')
    GROUP BY k.status
-- What the active ones do: on CPU, or waiting, by the wait's class. One
-- waiting on an idle event (a client that has not answered) is left out.
UNION ALL SELECT 2, 'active', COUNT(*), 'class',
    CASE WHEN state = 'WAITING' THEN LOWER(REPLACE(wait_class, ' ', '_')) ELSE 'cpu' END,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE type = 'USER' AND status = 'ACTIVE' AND sid <> SYS_CONTEXT('USERENV', 'SID')
        AND NOT (state = 'WAITING' AND wait_class = 'Idle')
    GROUP BY CASE WHEN state = 'WAITING' THEN LOWER(REPLACE(wait_class, ' ', '_')) ELSE 'cpu' END
UNION ALL SELECT 3, 'blocked', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE blocking_session IS NOT NULL AND blocking_session_status = 'VALID'
UNION ALL SELECT 4, 'longest_blocked_seconds', NVL(ROUND(MAX(wait_time_micro) / 1e6, 2), 0),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE blocking_session IS NOT NULL AND blocking_session_status = 'VALID'
-- Sessions that block others and wait on no one: where a chain starts.
UNION ALL SELECT 5, 'head_blockers', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session h
    WHERE (h.blocking_session IS NULL OR h.blocking_session_status <> 'VALID')
      AND EXISTS (SELECT 1 FROM v$session w WHERE w.blocking_session = h.sid AND w.blocking_session_status = 'VALID')
UNION ALL SELECT 6, 'longest_active_seconds', NVL(MAX(last_call_et), 0), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE type = 'USER' AND status = 'ACTIVE' AND sid <> SYS_CONTEXT('USERENV', 'SID')
UNION ALL SELECT 7, 'transactions', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$transaction
UNION ALL SELECT 8, 'oldest_transaction_seconds', NVL(ROUND((SYSDATE - MIN(start_date)) * 86400), 0),
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$transaction
-- Asleep with a transaction open: an application that did not commit.
UNION ALL SELECT 9, 'idle_in_transaction', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE type = 'USER' AND status = 'INACTIVE' AND taddr IS NOT NULL
UNION ALL SELECT 10, 'idle_in_transaction_seconds', NVL(MAX(last_call_et), 0), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session WHERE type = 'USER' AND status = 'INACTIVE' AND taddr IS NOT NULL
UNION ALL SELECT 11, 'long_operations', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$session_longops WHERE time_remaining > 0 AND sofar < totalwork
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
