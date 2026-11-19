#Requires -Version 5.1

<#
.SYNOPSIS
    innodb.ps1 - a MySQL or MariaDB server's InnoDB buffer pool, purge and locks, on
    Windows
.DESCRIPTION
    How many reads the buffer pool served without going to disk, how full
    it is, how much undo history waits for purge (it grows behind long
    transactions), and running totals of row lock waits and deadlocks.
    MySQL keeps the last two in information_schema.INNODB_METRICS, MariaDB
    in its status variables; this reads either.
    The server may be anywhere this machine can reach. Connects to
    MYSQL_HOST and MYSQL_TCP_PORT as MYSQL_USER, with the password in
    MYSQL_PWD, all set by the job; never on a command line.

    Metrics:
        buffer_pool_hit_pct   reads served from the buffer pool, since the
                              server started; left out while the server's
                              counters cannot give it (MariaDB counts read
                              requests only in part, and on a fresh server
                              can show more reads from disk than requests)
        buffer_pool_used_pct  pages of the buffer pool in use
        history_list_count    undo log entries waiting for purge
        row_lock_waits_count  times a statement waited for a row lock (a
                              running total)
        deadlocks_count       deadlocks InnoDB detected (a running total)

    Example output:
      metric buffer_pool_hit_pct 99
      metric buffer_pool_used_pct 41
      metric history_list_count 12
      metric row_lock_waits_count 3
      metric deadlocks_count 0

    Reading the results (starting points: tune them to the server):
      Healthy  buffer_pool_hit_pct above 99 on a busy server;
               history_list_count in the thousands at most, and falling back
               after bursts.
      Watch    buffer_pool_used_pct at 100 with the hit rate falling: the
               working set no longer fits (innodb_buffer_pool_size).
               history_list_count climbing for hours: purge cannot keep up,
               or a long transaction holds it back (mysql_activity).
      Act      history_list_count in the millions: end the transaction
               holding it back. deadlocks_count rising: transactions take
               their locks in different orders (SHOW ENGINE INNODB STATUS
               shows the last one). The _count totals restart with the
               server: graph them as a rate.

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
    [Console]::Error.WriteLine('innodb: mysql not found: install the MySQL or MariaDB client')
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

$s = Invoke-MySql "SHOW GLOBAL STATUS WHERE Variable_name IN ('Innodb_buffer_pool_read_requests', 'Innodb_buffer_pool_reads', 'Innodb_buffer_pool_pages_total', 'Innodb_buffer_pool_pages_free', 'Innodb_row_lock_waits', 'Innodb_deadlocks', 'Innodb_history_list_length')"
if (-not $s.Ok) {
    if (Test-Down) { exit 0 }
    [Console]::Error.WriteLine("innodb: the server refused the login or the queries: $(Get-ClientError)")
    exit 1
}
$v = @{}
foreach ($line in $s.Lines) { $name, $value = $line.Split("`t", 2); $v[$name] = [long]$value }

# MySQL has neither as a status variable: INNODB_METRICS keeps them, both
# counted by default.
$deadlocks = $v['Innodb_deadlocks']; $history = $v['Innodb_history_list_length']
if ($null -eq $deadlocks -or $null -eq $history) {
    $m = Invoke-MySql "SELECT NAME, COUNT FROM information_schema.INNODB_METRICS WHERE NAME IN ('lock_deadlocks', 'trx_rseg_history_len')"
    if (-not $m.Ok) {
        [Console]::Error.WriteLine("innodb: the server refused the queries: $(Get-ClientError)")
        exit 1
    }
    foreach ($line in $m.Lines) {
        $name, $value = $line.Split("`t", 2)
        if ($name -ceq 'lock_deadlocks' -and $null -eq $deadlocks) { $deadlocks = [long]$value }
        if ($name -ceq 'trx_rseg_history_len' -and $null -eq $history) { $history = [long]$value }
    }
}

$requests = [long]$v['Innodb_buffer_pool_read_requests']; $reads = [long]$v['Innodb_buffer_pool_reads']
$total = [long]$v['Innodb_buffer_pool_pages_total']; $free = [long]$v['Innodb_buffer_pool_pages_free']
# Left out when the counters cannot give it: MariaDB counts read requests
# only in part, and can show more reads from disk than requests.
if ($requests -gt 0 -and $reads -le $requests) {
    Write-Output "metric buffer_pool_hit_pct $([long][Math]::Floor(100 * ($requests - $reads) / $requests))"
}
if ($total -gt 0) { Write-Output "metric buffer_pool_used_pct $([long][Math]::Floor(100 * ($total - $free) / $total))" }
Write-Output "metric history_list_count $(if ($null -ne $history) { $history } else { 0 })"
Write-Output "metric row_lock_waits_count $([long]$v['Innodb_row_lock_waits'])"
Write-Output "metric deadlocks_count $(if ($null -ne $deadlocks) { $deadlocks } else { 0 })"
