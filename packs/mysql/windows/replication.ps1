#Requires -Version 5.1

<#
.SYNOPSIS
    replication.ps1 - a MySQL or MariaDB server's replication, on Windows
.DESCRIPTION
    On a replica: whether its two replication threads run (one receives the
    source's changes, one applies them), and how far behind the source it
    is, for each channel (MySQL) or connection (MariaDB) it replicates
    through. On a source: the replicas connected to it now. A server with
    neither reports is_replica 0 and replicas 0. MySQL and MariaDB name
    these differently; this reads either.
    The server may be anywhere this machine can reach. Connects to
    MYSQL_HOST and MYSQL_TCP_PORT as MYSQL_USER, with the password in
    MYSQL_PWD, all set by the job; never on a command line.

    Metrics:
        is_replica   1 when it replicates from a source, else 0
        io_running   (replica) 1 while the thread receiving from the source
                     runs, tagged channel=<name, or default>
        sql_running  (replica) 1 while the thread applying the changes runs,
                     tagged channel=<name, or default>
        lag_seconds  (replica) how far behind the source it is
                     (Seconds_Behind_Source), tagged channel=<name, or
                     default>; left out while the applying thread is stopped,
                     when the server cannot tell
        replicas     (source) replicas connected to it now; one whose machine
                     stopped without closing its connection still counts
                     until the source's connection to it times out

    Example output:
      metric is_replica 1
      metric replicas 0
      metric io_running 1 channel=default
      metric sql_running 1 channel=default
      metric lag_seconds 0 channel=default

    Reading the results (starting points: tune them to the server):
      Healthy  on a replica, io_running 1 and sql_running 1, and
               lag_seconds a few seconds at most; on a source, replicas as
               many as you run.
      Watch    lag_seconds rising during heavy writes and not falling after.
      Act      io_running 0: the replica cannot reach or log in to its
               source; sql_running 0: applying stopped on an error (SHOW
               REPLICA STATUS says which). replicas below what you run, on
               the source: one is not connected. Alert on each replica's own
               io_running and mysql.up as well: they say at once what the
               source may learn only minutes later.

    When the server does not answer, it prints nothing and succeeds:
    mysql_status reports that, as mysql.up 0.

    Requires: Windows PowerShell 5.1 or PowerShell 7, the mysql client
      (MySQL's mysql.exe, or MariaDB's), and a user with PROCESS and REPLICATION CLIENT (MariaDB: and
      REPLICA MONITOR)
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
    [Console]::Error.WriteLine('replication: mysql not found: install the MySQL or MariaDB client')
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

function Fail { [Console]::Error.WriteLine("replication: the server refused the login or the queries: $(Get-ClientError)"); exit 1 }

$v = Invoke-MySql 'SELECT VERSION()'
if (-not $v.Ok) { if (Test-Down) { exit 0 }; Fail }
$version = "$($v.Lines[0])"
$c = Invoke-MySql "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE COMMAND IN ('Binlog Dump', 'Binlog Dump GTID')"
if (-not $c.Ok) { Fail }
$replicas = "$($c.Lines[0])".Trim()

# Every channel's status, with its column names. MariaDB lists every
# connection with SHOW ALL REPLICAS STATUS (10.5.1 on), MySQL every channel
# with SHOW REPLICA STATUS (8.0.22 on); each falls back to its older name.
if ($version -match 'MariaDB') { $q = 'SHOW ALL REPLICAS STATUS', 'SHOW ALL SLAVES STATUS' }
else { $q = 'SHOW REPLICA STATUS', 'SHOW SLAVE STATUS' }
$st = Invoke-MySql $q[0] -Header
if (-not $st.Ok) { $st = Invoke-MySql $q[1] -Header }
if (-not $st.Ok) { Fail }

# The columns found by name under either spelling.
$rows = @()
if ($st.Lines.Count -gt 1) {
    $cols = $st.Lines[0].Split("`t")
    $io = [Array]::FindIndex($cols, [Predicate[string]] { param($x) $x -ceq 'Replica_IO_Running' -or $x -ceq 'Slave_IO_Running' })
    $sq = [Array]::FindIndex($cols, [Predicate[string]] { param($x) $x -ceq 'Replica_SQL_Running' -or $x -ceq 'Slave_SQL_Running' })
    $lag = [Array]::FindIndex($cols, [Predicate[string]] { param($x) $x -ceq 'Seconds_Behind_Source' -or $x -ceq 'Seconds_Behind_Master' })
    $ch = [Array]::FindIndex($cols, [Predicate[string]] { param($x) $x -ceq 'Channel_Name' -or $x -ceq 'Connection_name' })
    if ($io -ge 0 -and $sq -ge 0) {
        foreach ($line in $st.Lines[1..($st.Lines.Count - 1)]) {
            $f = $line.Split("`t")
            $name = if ($ch -ge 0 -and $f[$ch]) { $f[$ch] } else { 'default' }
            $name = $name -replace '[^A-Za-z0-9_.-]', '_'
            $rows += "metric io_running $(if ($f[$io] -ceq 'Yes') { 1 } else { 0 }) channel=$name"
            $rows += "metric sql_running $(if ($f[$sq] -ceq 'Yes') { 1 } else { 0 }) channel=$name"
            if ($lag -ge 0 -and $f[$lag] -match '^\d+$') { $rows += "metric lag_seconds $($f[$lag]) channel=$name" }
        }
    }
}

Write-Output "metric is_replica $(if ($rows.Count -gt 0) { 1 } else { 0 })"
Write-Output "metric replicas $replicas"
$rows | ForEach-Object { Write-Output $_ }
