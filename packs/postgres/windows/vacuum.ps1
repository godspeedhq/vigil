#Requires -Version 5.1

<#
.SYNOPSIS
    vacuum.ps1 - whether autovacuum keeps up on a PostgreSQL server, on
    Windows
.DESCRIPTION
    For each database this role may connect to: the dead rows waiting for
    vacuum, and the tables past the point where autovacuum should vacuum
    them. For the server: the autovacuum workers running now, and how many
    may run. Table statistics belong to each database, so it connects to
    each in turn. The server may be anywhere this machine can reach.
    Connects as the libpq environment says: PGHOST, PGPORT, PGUSER and
    PGPASSWORD, set by the job; PGDATABASE is the first database it asks.
    psql and pg_isready are looked for on the PATH, then in PostgreSQL's own
    folders under Program Files, the newest version first.

    Metrics:
        dead_tuples_count       dead rows waiting for vacuum, tagged
                                database=<name>
        tables_due_count        tables with more dead rows than the
                                server-wide autovacuum threshold allows,
                                tagged database=<name> (a table's own
                                autovacuum settings are not read)
        autovacuum_workers      autovacuum workers running now
        autovacuum_max_workers  how many may run at once

    Example output (one line per database for the tagged ones):
      metric autovacuum_workers 0
      metric autovacuum_max_workers 3
      metric dead_tuples_count 1204 database=app
      metric tables_due_count 0 database=app

    Reading the results (starting points: tune them to the server):
      Healthy  tables_due_count 0, or briefly above it while workers catch up.
      Watch    tables_due_count staying above 0, and autovacuum_workers often
               at autovacuum_max_workers: autovacuum is busy all the time.
      Act      dead_tuples_count growing run after run with tables due:
               tables and indexes bloat, and queries slow down. Look for a
               long open transaction holding vacuum back (postgres_activity,
               postgres_wraparound), or give autovacuum more workers or less
               cost delay.

    A database it may not connect to is left out, with a line on standard
    error. When the server does not answer, it prints nothing and succeeds:
    postgres_status reports that, as postgres.up 0.

    Requires: Windows PowerShell 5.1 or PowerShell 7, psql and pg_isready
      (PostgreSQL's client tools), PostgreSQL 14 or later, and a role with
      pg_monitor
    Exit code: 0 on success, or when the server does not answer; 1 if psql or
      pg_isready is missing or the server refuses the login or the queries
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

# A PostgreSQL client tool: on the PATH, or the newest of PostgreSQL's own.
function Find-PgTool {
    param([string]$Name)
    $c = @(Get-Command "$Name.exe" -CommandType Application -ErrorAction SilentlyContinue)
    if ($c.Count -gt 0) { return $c[0].Source }
    $dir = Join-Path $env:ProgramFiles 'PostgreSQL'
    $found = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "bin\$Name.exe") } |
            Sort-Object { [int]($_.Name -replace '\D.*$', '') } -Descending)
    if ($found.Count -gt 0) { return Join-Path $found[0].FullName "bin\$Name.exe" }
    return $null
}

$psql = Find-PgTool 'psql'
$ready = Find-PgTool 'pg_isready'
if (-not $psql -or -not $ready) {
    [Console]::Error.WriteLine('vacuum: psql or pg_isready not found: install PostgreSQL''s client tools')
    exit 1
}
& $ready -q -t 5
if ($LASTEXITCODE -ne 0) { exit 0 }

# The rows of $Query, one string each, and whether psql succeeded.
function Invoke-Psql {
    param([string]$Query)
    $ErrorActionPreference = 'Continue'
    $o = @(& $psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -c $Query 2>&1 | ForEach-Object { "$_" })
    return @{ Ok = ($LASTEXITCODE -eq 0); Rows = $o }
}

$r = Invoke-Psql @'
SELECT 'autovacuum_workers', count(*) FROM pg_stat_activity WHERE backend_type = 'autovacuum worker'
UNION ALL SELECT 'autovacuum_max_workers', setting::bigint FROM pg_settings WHERE name = 'autovacuum_max_workers'
'@
if (-not $r.Ok) {
    [Console]::Error.WriteLine("vacuum: the server refused the login or the queries: $($r.Rows -join ' ')")
    exit 1
}
foreach ($line in $r.Rows) {
    $name, $value = "$line".Trim().Split(' ', 2)
    if ($name -and $value) { Write-Output "metric $name $value" }
}

$dbs = Invoke-Psql @'
SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate
    AND has_database_privilege(datname, 'CONNECT') ORDER BY datname
'@
if (-not $dbs.Ok) {
    [Console]::Error.WriteLine("vacuum: the server refused the queries: $($dbs.Rows -join ' ')")
    exit 1
}

# A table is due when its dead rows pass threshold + scale factor x its rows,
# as autovacuum reckons it. reltuples is -1 for a table never analysed.
$perDb = @'
SELECT 'dead_tuples_count', coalesce(sum(n_dead_tup), 0)::bigint FROM pg_stat_user_tables
UNION ALL SELECT 'tables_due_count', count(*) FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
    WHERE s.n_dead_tup > current_setting('autovacuum_vacuum_threshold')::bigint
        + current_setting('autovacuum_vacuum_scale_factor')::float8 * greatest(c.reltuples, 0)
'@
$first = $env:PGDATABASE
try {
    foreach ($db in $dbs.Rows) {
        $db = "$db".Trim()
        if (-not $db) { continue }
        $env:PGDATABASE = $db
        $d = Invoke-Psql $perDb
        if (-not $d.Ok) {
            [Console]::Error.WriteLine("vacuum: database $db left out: $($d.Rows -join ' ')")
            continue
        }
        $tag = $db -replace '[^A-Za-z0-9_.-]', '_'
        foreach ($line in $d.Rows) {
            $name, $value = "$line".Trim().Split(' ', 2)
            if ($name -and $value) { Write-Output "metric $name $value database=$tag" }
        }
    }
}
finally { $env:PGDATABASE = $first }
