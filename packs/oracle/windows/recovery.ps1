#Requires -Version 5.1

<#
.SYNOPSIS
    recovery.ps1 - what an Oracle database's recovery depends on, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the fast recovery area: its limit, what it holds, what could be
    freed and how full it is; Flashback Database; archive destinations in
    error; log switches in the last hour; and the redo log groups, those still
    needed for crash recovery, and those not yet archived. One query,
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
      fra_limit_bytes           the fast recovery area's limit
                                (db_recovery_file_dest_size); 0 with none
      fra_used_bytes            what it holds
      fra_reclaimable_bytes     what could be deleted (backed up, or obsolete)
      fra_used_pct              used and not reclaimable, as a percent of the
                                limit
      flashback_on              1 when Flashback Database is on
      archive_dest_errors       archive destinations in error
      archive_dest_error        one of them: 1, tagged dest=
      log_switches_1h           redo log switches in the last hour
      redo_groups               redo log groups
      redo_group_bytes          the size of the largest
      redo_groups_active        groups still needed for crash recovery (their
                                checkpoint is not done)
      redo_groups_not_archived  in ARCHIVELOG mode, groups switched out and not
                                yet archived

    Example output (the rest are in the same form):
      metric fra_limit_bytes 2147483648
      metric fra_used_pct 23.1
      metric archive_dest_errors 0
      metric log_switches_1h 4
      metric redo_groups_not_archived 0

    Reading the results (starting points: tune them to the database):
      Healthy  fra_used_pct below 80; archive_dest_errors 0; log_switches_1h a
               few (Oracle suggests about four an hour).
      Watch    fra_used_pct above 80; log_switches_1h in the dozens: the redo
               logs are small for the load; redo_groups_not_archived above 0
               for more than a switch or two.
      Act      fra_used_pct near 100 in ARCHIVELOG mode: the archiver stops
               and so does every change (ORA-00257); archive_dest_errors above
               0.

    Requires: Windows PowerShell 5.1 or PowerShell 7, SQL*Plus (Oracle
      Instant Client, basic and sqlplus), and a user with what
      packs/oracle/README.md says to grant
    Exit code: 0 on success, or when the database does not answer; 1 if the
      database refuses the login or the query, or SQL*Plus is missing
#>

$ErrorActionPreference = 'Stop'
$me = 'recovery'

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
-- What recovery needs: the fast recovery area and how full it is, the
-- archiver, the redo logs and how often they switch.
UNION ALL SELECT 1, x.n, x.v, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM (SELECT NVL(SUM(space_limit), 0) AS lim, NVL(SUM(space_used), 0) AS used, NVL(SUM(space_reclaimable), 0) AS recl
          FROM v$recovery_file_dest WHERE name IS NOT NULL) f
    CROSS APPLY (SELECT 'fra_limit_bytes' AS n, f.lim AS v FROM dual
                 UNION ALL SELECT 'fra_used_bytes', f.used FROM dual
                 UNION ALL SELECT 'fra_reclaimable_bytes', f.recl FROM dual
                 -- What cannot be freed for new files, as a percent of the limit.
                 UNION ALL SELECT 'fra_used_pct', CASE WHEN f.lim > 0 THEN ROUND(100 * (f.used - f.recl) / f.lim, 2) END FROM dual) x
UNION ALL SELECT 2, 'flashback_on', CASE WHEN flashback_on = 'YES' THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$database
-- Archive destinations in error, each by its name.
UNION ALL SELECT 3, 'archive_dest_errors', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$archive_dest WHERE status IN ('ERROR', 'BAD PARAM')
UNION ALL SELECT 4, 'archive_dest_error', 1, 'dest', LOWER(dest_name), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$archive_dest WHERE status IN ('ERROR', 'BAD PARAM')
UNION ALL SELECT 5, 'log_switches_1h', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$log_history WHERE first_time > SYSDATE - 1 / 24
UNION ALL SELECT 6, 'redo_groups', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$log
UNION ALL SELECT 7, 'redo_group_bytes', MAX(bytes), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM v$log
-- Groups still needed for crash recovery: their checkpoint is not done.
UNION ALL SELECT 8, 'redo_groups_active', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$log WHERE status = 'ACTIVE'
-- In ARCHIVELOG mode, groups switched out and not yet archived.
UNION ALL SELECT 9, 'redo_groups_not_archived', COUNT(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM v$log l CROSS JOIN v$database d
    WHERE d.log_mode = 'ARCHIVELOG' AND l.archived = 'NO' AND l.status <> 'CURRENT'
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
