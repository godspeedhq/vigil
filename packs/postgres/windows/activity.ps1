#Requires -Version 5.1

<#
.SYNOPSIS
    activity.ps1 - what a PostgreSQL server's client sessions are doing, on
    Windows
.DESCRIPTION
    Counts the client sessions in each state, those waiting on a lock and
    those blocked by another session, and finds the longest lock wait and
    the longest session idle in a transaction. Leaves out its own session.
    The server may be anywhere this machine can reach. Connects as the libpq
    environment says: PGHOST, PGPORT, PGUSER, PGDATABASE and PGPASSWORD, set
    by the job. psql and pg_isready are looked for on the PATH, then in
    PostgreSQL's own folders under Program Files, the newest version first.

    Metrics:
        active                               sessions running a query now
        idle                                 sessions connected and doing nothing
        idle_in_transaction                  sessions inside a transaction, doing nothing
        waiting                              sessions waiting on a lock
        blocked                              sessions blocked by another session
        longest_wait_seconds                 the longest lock wait now
        longest_idle_in_transaction_seconds  the longest time a session has
                                             sat idle inside a transaction

    Example output (the rest are in the same form):
      metric active 3
      metric idle 18
      metric idle_in_transaction 1
      metric waiting 0

    Reading the results (starting points: tune them to the server):
      Healthy  waiting and blocked at 0, or briefly above it; no session idle
               in a transaction for more than a few seconds.
      Watch    longest_wait_seconds above a few seconds, again and again:
               sessions queue behind each other's locks.
      Act      blocked growing, or longest_wait_seconds in minutes: something
               holds a lock and everything behind it waits. A session idle in
               a transaction for minutes holds its locks and holds back
               vacuum: fix the application, or set
               idle_in_transaction_session_timeout.

    When the server does not answer, it prints nothing and succeeds:
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
    [Console]::Error.WriteLine('activity: psql or pg_isready not found: install PostgreSQL''s client tools')
    exit 1
}
& $ready -q -t 5
if ($LASTEXITCODE -ne 0) { exit 0 }

# One query, one "name value" row per metric. A lock wait is timed from
# pg_locks.waitstart, when the wait began (PostgreSQL 14 or later).
$query = @'
WITH s AS (
    SELECT * FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
)
SELECT 'active', count(*) FILTER (WHERE state = 'active') FROM s
UNION ALL SELECT 'idle', count(*) FILTER (WHERE state = 'idle') FROM s
UNION ALL SELECT 'idle_in_transaction', count(*) FILTER (WHERE state LIKE 'idle in transaction%') FROM s
UNION ALL SELECT 'waiting', count(*) FILTER (WHERE wait_event_type = 'Lock') FROM s
UNION ALL SELECT 'blocked', count(*) FILTER (WHERE cardinality(pg_blocking_pids(pid)) > 0) FROM s
UNION ALL SELECT 'longest_wait_seconds', coalesce(floor(max(extract(epoch FROM now() - waitstart))), 0)::bigint
    FROM pg_locks WHERE NOT granted AND waitstart IS NOT NULL AND pid <> pg_backend_pid()
UNION ALL SELECT 'longest_idle_in_transaction_seconds',
    coalesce(floor(max(extract(epoch FROM now() - state_change)) FILTER (WHERE state LIKE 'idle in transaction%')), 0)::bigint FROM s
'@
$ErrorActionPreference = 'Continue'
$out = @(& $psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -c $query 2>&1 | ForEach-Object { "$_" })
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("activity: the server refused the login or the queries: $($out -join ' ')")
    exit 1
}
foreach ($line in $out) {
    $name, $value = "$line".Trim().Split(' ', 2)
    if ($name -and $value) { Write-Output "metric $name $value" }
}
