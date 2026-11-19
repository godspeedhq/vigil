#Requires -Version 5.1

<#
.SYNOPSIS
    size.ps1 - each database's size on a MySQL or MariaDB server, on Windows
.DESCRIPTION
    The size on disk of each database's InnoDB tables, data and indexes,
    from the server's list of InnoDB tablespaces (a table each, by
    default), which a user with PROCESS may read without being able to read
    the tables themselves. The server's own databases (mysql, sys,
    performance_schema) are left out. Tables in the shared system
    tablespace or in another engine, such as MyISAM, are not counted.
    The server may be anywhere this machine can reach. Connects to
    MYSQL_HOST and MYSQL_TCP_PORT as MYSQL_USER, with the password in
    MYSQL_PWD, all set by the job; never on a command line.

    Metrics:
        size_bytes  a database's InnoDB tables on disk, tagged database=<name>

    Example output:
      metric size_bytes 114688 database=orders
      metric size_bytes 4194304 database=shop

    Reading the results (starting points: tune them to the server):
      Healthy  growth in line with the data the database takes in.
      Watch    a database growing much faster than usual.
      Act      growth that will fill the disk soon: compare with the disk's
               free space (the base pack's disk job).

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
    [Console]::Error.WriteLine('size: mysql not found: install the MySQL or MariaDB client')
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

$v = Invoke-MySql 'SELECT VERSION()'
if (-not $v.Ok) {
    if (Test-Down) { exit 0 }
    [Console]::Error.WriteLine("size: the server refused the login or the queries: $(Get-ClientError)")
    exit 1
}
# A file-per-table tablespace is named <database>/<table>. MySQL lists them
# in INNODB_TABLESPACES, MariaDB in INNODB_SYS_TABLESPACES.
$view = if ("$($v.Lines[0])" -match 'MariaDB') { 'INNODB_SYS_TABLESPACES' } else { 'INNODB_TABLESPACES' }
$r = Invoke-MySql "SELECT SUBSTRING_INDEX(NAME, '/', 1) AS db, SUM(FILE_SIZE) FROM information_schema.$view WHERE NAME LIKE '%/%' AND SUBSTRING_INDEX(NAME, '/', 1) NOT IN ('mysql', 'sys', 'performance_schema') GROUP BY db ORDER BY db"
if (-not $r.Ok) {
    [Console]::Error.WriteLine("size: the server refused the queries: $(Get-ClientError)")
    exit 1
}
foreach ($line in $r.Lines) {
    $name, $bytes = $line.Split("`t", 2)
    if ($name) { Write-Output "metric size_bytes $bytes database=$($name -replace '[^A-Za-z0-9_.-]', '_')" }
}
