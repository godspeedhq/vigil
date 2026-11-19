#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - a MySQL or MariaDB server's health, on Windows
.DESCRIPTION
    Asks the server, as a read-only user, whether it answers, then for its
    connections against the limit, the statements running and the longest,
    and running totals of statements, slow ones, failed connection attempts
    and temporary tables that spilled to disk.
    The server may be anywhere this machine can reach. Connects to
    MYSQL_HOST and MYSQL_TCP_PORT as MYSQL_USER, with the password in
    MYSQL_PWD, all set by the job; never on a command line.

    Metrics:
        up                      1 when the server answers, else 0
        connections             client connections now
        max_connections         the server's limit
        connections_pct         connections as a percent of the limit
        running                 client connections running a statement now,
                                leaving out this one and replication threads
        longest_query_seconds   the longest statement running now
                                (replication threads left out)
        queries_count           statements run (a running total)
        slow_queries_count      statements over long_query_time (a running total)
        aborted_connects_count  failed connection attempts (a running total)
        tmp_disk_tables_count   temporary tables that spilled to disk (a
                                running total)

    Example output:
      metric up 1
      metric connections 12
      metric max_connections 151
      metric connections_pct 7

    Reading the results (starting points: tune them to the server):
      Healthy  up 1; connections_pct below 70; running a handful; no
               statement running for minutes.
      Watch    connections_pct 70 to 90; slow_queries_count or
               tmp_disk_tables_count rising faster than usual.
      Act      up 0; connections_pct above 90, and new connections will soon
               be refused; aborted_connects_count rising fast: bad
               passwords, or a full server. The _count totals restart with
               the server: graph them as a rate.

    Requires: Windows PowerShell 5.1 or PowerShell 7, the mysql client
      (MySQL's mysql.exe, or MariaDB's), and a user with PROCESS
    Exit code: 0 on success, server up or down; 1 if the client is missing or
      the server refuses the login or the queries
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
    [Console]::Error.WriteLine('status: mysql not found: install the MySQL or MariaDB client')
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

# A server that does not answer is a reading, not a failure.
$r = Invoke-MySql 'SELECT 1'
if (-not $r.Ok) {
    if (Test-Down) { Write-Output 'metric up 0'; exit 0 }
    [Console]::Error.WriteLine("status: the server refused the login or the queries: $(Get-ClientError)")
    exit 1
}
$s = Invoke-MySql "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected', 'Questions', 'Slow_queries', 'Aborted_connects', 'Created_tmp_disk_tables')"
$m = Invoke-MySql 'SELECT @@GLOBAL.max_connections'
# Client statements only: the server's own threads (replication, the event
# scheduler) run for as long as the server does.
$c = Invoke-MySql "SELECT COUNT(*), COALESCE(MAX(TIME), 0) FROM information_schema.PROCESSLIST WHERE COMMAND = 'Query' AND ID <> CONNECTION_ID() AND USER NOT IN ('system user', 'event_scheduler')"
if (-not ($s.Ok -and $m.Ok -and $c.Ok)) {
    [Console]::Error.WriteLine("status: the server refused the queries: $(Get-ClientError)")
    exit 1
}

Write-Output 'metric up 1'
$names = @{ Threads_connected = 'connections'; Questions = 'queries_count'; Slow_queries = 'slow_queries_count'
    Aborted_connects = 'aborted_connects_count'; Created_tmp_disk_tables = 'tmp_disk_tables_count' }
$connections = $null
foreach ($line in $s.Lines) {
    $name, $value = $line.Split("`t", 2)
    if (-not $names.ContainsKey($name)) { continue }
    if ($name -ceq 'Threads_connected') { $connections = [long]$value }
    Write-Output "metric $($names[$name]) $value"
}
$max = [long]("$($m.Lines[0])".Trim())
Write-Output "metric max_connections $max"
if ($null -ne $connections -and $max -gt 0) {
    Write-Output "metric connections_pct $([long][Math]::Floor(100 * $connections / $max))"
}
$running, $longest = "$($c.Lines[0])".Split("`t", 2)
Write-Output "metric running $running"
Write-Output "metric longest_query_seconds $longest"
