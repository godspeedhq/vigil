#Requires -Version 5.1

<#
.SYNOPSIS
    activity.ps1 - a MySQL or MariaDB server's open InnoDB transactions, on Windows
.DESCRIPTION
    Finds the longest open transaction, the transactions open on a
    connection that is doing nothing (they hold their locks and hold back
    purge), and the transactions waiting on a row lock. Leaves out its own
    connection. Reads information_schema.INNODB_TRX, which MySQL and
    MariaDB both have.
    The server may be anywhere this machine can reach. Connects to
    MYSQL_HOST and MYSQL_TCP_PORT as MYSQL_USER, with the password in
    MYSQL_PWD, all set by the job; never on a command line.

    Metrics:
        longest_transaction_seconds          the longest open transaction now
        idle_in_transaction                  transactions open on a
                                             connection that is doing nothing
        longest_idle_in_transaction_seconds  the longest of those idle times
        waiting                              transactions waiting on a row lock
        longest_wait_seconds                 the longest row lock wait now

    Example output:
      metric longest_transaction_seconds 3
      metric idle_in_transaction 0
      metric longest_idle_in_transaction_seconds 0
      metric waiting 0
      metric longest_wait_seconds 0

    Reading the results (starting points: tune them to the server):
      Healthy  waiting at 0, or briefly above it; no transaction open for
               minutes; no connection idle in a transaction for more than a
               few seconds.
      Watch    longest_wait_seconds above a few seconds, again and again.
      Act      longest_wait_seconds nearing innodb_lock_wait_timeout (50 s by
               default), when statements start failing; a transaction idle
               for minutes holds its locks and lets the undo history grow:
               find it in information_schema.INNODB_TRX and fix the
               application, or lower wait_timeout.

    When the server does not answer, it prints nothing and succeeds:
    mysql_status reports that, as mysql.up 0.

    Requires: Windows PowerShell 5.1 or PowerShell 7, the mysql client
      (MySQL's mysql.exe, or MariaDB's), and a user with PROCESS
    Exit code: 0 on success, or when the server does not answer; 1 if the
      client is missing or the server refuses the login or the queries
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
#>

$ErrorActionPreference = 'Stop'

# The client: mysql or mariadb on the PATH, else the newest under Program
# Files (MySQL Server <version>, MariaDB <version>).
function Find-MySqlClient {
    foreach ($n in 'mysql.exe', 'mariadb.exe') {
        $c = @(Get-Command $n -CommandType Application -ErrorAction SilentlyContinue)
        if ($c.Count -gt 0) { return $c[0].Source }
    }
    $found = @(foreach ($d in @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'MySQL\*'), (Join-Path $env:ProgramFiles 'MariaDB*') -Directory -ErrorAction SilentlyContinue)) {
            foreach ($n in 'mysql.exe', 'mariadb.exe') {
                $f = Join-Path $d.FullName "bin\$n"
                if (Test-Path -LiteralPath $f) { [pscustomobject]@{ Path = $f; Version = [version]("0$($d.Name -replace '[^0-9.]', '')".Trim('.') + '.0') } ; break }
            }
        })
    if ($found.Count -gt 0) { return @($found | Sort-Object Version -Descending)[0].Path }
    return $null
}

$client = Find-MySqlClient
if (-not $client) {
    [Console]::Error.WriteLine('activity: mysql not found: install the MySQL or MariaDB client')
    exit 1
}

# Runs $Query, with its column names when -Header. The client's standard
# error is kept apart from its output: MariaDB's warns there even when a
# query works. The password is MYSQL_PWD, in the environment the client
# inherits, never on its command line. A query goes on one line.
$script:ClientErr = ''
function Invoke-MySql {
    param([string]$Query, [switch]$Header)
    $a = @('--protocol=TCP', '-h', $(if ($env:MYSQL_HOST) { $env:MYSQL_HOST } else { '127.0.0.1' }),
        '-P', $(if ($env:MYSQL_TCP_PORT) { $env:MYSQL_TCP_PORT } else { '3306' }),
        '-u', $(if ($env:MYSQL_USER) { $env:MYSQL_USER } else { 'vigil_monitor' }), '--connect-timeout=5', '-B')
    if (-not $Header) { $a += '-N' }
    $a += @('-e', ($Query -replace '\s+', ' ').Trim())
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $client
    $psi.Arguments = ($a | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $script:ClientErr = $e.Result
    return @{ Ok = ($p.ExitCode -eq 0); Lines = @($o.Result -split "`r?`n" | Where-Object { $_ -ne '' }) }
}
# What the client said, on one line, for a message.
function Get-ClientError { (@($script:ClientErr -split "`r?`n") | Where-Object { $_ -and $_ -notmatch '^WARNING' }) -join ' ' }
# Whether it failed to reach the server at all: errors 2002, 2003, 2005 and
# 2013. Anything else, a refused login for one, is a failure.
function Test-Down { $script:ClientErr -match 'ERROR (2002|2003|2005|2013)' }

# One query, one "name value" row per metric. A transaction's connection is
# idle when its command is Sleep.
$r = Invoke-MySql @'
SELECT 'longest_transaction_seconds', COALESCE(MAX(TIMESTAMPDIFF(SECOND, t.trx_started, NOW())), 0)
    FROM information_schema.INNODB_TRX t WHERE t.trx_mysql_thread_id <> CONNECTION_ID()
UNION ALL SELECT 'idle_in_transaction', COUNT(*)
    FROM information_schema.INNODB_TRX t JOIN information_schema.PROCESSLIST p ON p.ID = t.trx_mysql_thread_id
    WHERE p.COMMAND = 'Sleep'
UNION ALL SELECT 'longest_idle_in_transaction_seconds', COALESCE(MAX(p.TIME), 0)
    FROM information_schema.INNODB_TRX t JOIN information_schema.PROCESSLIST p ON p.ID = t.trx_mysql_thread_id
    WHERE p.COMMAND = 'Sleep'
UNION ALL SELECT 'waiting', COUNT(*) FROM information_schema.INNODB_TRX WHERE trx_state = 'LOCK WAIT'
UNION ALL SELECT 'longest_wait_seconds', COALESCE(MAX(TIMESTAMPDIFF(SECOND, trx_wait_started, NOW())), 0)
    FROM information_schema.INNODB_TRX WHERE trx_state = 'LOCK WAIT'
'@
if (-not $r.Ok) {
    if (Test-Down) { exit 0 }
    [Console]::Error.WriteLine("activity: the server refused the login or the queries: $(Get-ClientError)")
    exit 1
}
foreach ($line in $r.Lines) {
    $name, $value = $line.Split("`t", 2)
    if ($name -and $value) { Write-Output "metric $name $value" }
}
