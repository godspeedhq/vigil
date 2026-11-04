#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - a PostgreSQL server's health, on Windows
.DESCRIPTION
    Asks the server, as a read-only role (pg_monitor), whether it accepts
    connections, then for its connections, its longest query and
    transaction, its transactions and deadlocks since its statistics were
    last reset, and its cache hits. Connects as the libpq environment says:
    PGHOST, PGPORT, PGUSER, PGDATABASE and PGPASSWORD, set by the job. psql
    and pg_isready are looked for on the PATH, then in PostgreSQL's own
    folders under Program Files, the newest version first.

    Metrics:
        up                           1 when the server accepts connections, else 0
        connections                  client connections now
        max_connections              the server's limit
        connections_pct              connections as a percent of the limit
        longest_query_seconds        the longest query running now
        longest_transaction_seconds  the longest open transaction now
        commits_count                transactions committed (a running total)
        rollbacks_count              transactions rolled back (a running total)
        deadlocks_count              deadlocks detected (a running total)
        cache_hit_pct                reads served from the buffer cache

    Example output (the rest are in the same form):
      metric up 1
      metric connections 12
      metric max_connections 100
      metric connections_pct 12

    Reading the results (starting points: tune them to the server):
      Healthy  up 1; connections_pct below 70; no query or transaction open
               for minutes; cache_hit_pct above 99 on a busy database.
      Watch    connections_pct 70 to 90; a transaction open for more than a
               few minutes holds back vacuum; rollbacks rising faster than usual.
      Act      up 0; connections_pct above 90, and new connections will soon
               be refused; deadlocks_count rising. The _count totals restart
               when the server's statistics are reset: graph them as a rate.

    Requires: Windows PowerShell 5.1 or PowerShell 7, psql and pg_isready
      (PostgreSQL's client tools), and a role with pg_monitor
    Exit code: 0 on success, server up or down; 1 if psql is missing or the
      server refuses the login or the queries
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
    [Console]::Error.WriteLine('status: psql or pg_isready not found: install PostgreSQL''s client tools')
    exit 1
}

# A server that does not answer is a reading, not a failure.
& $ready -q -t 5
if ($LASTEXITCODE -ne 0) {
    Write-Output 'metric up 0'
    exit 0
}

# One query, one "name value" row per metric; never this connection's own row.
$query = @'
SELECT 'connections', count(*) FROM pg_stat_activity WHERE backend_type = 'client backend'
UNION ALL SELECT 'max_connections', setting::bigint FROM pg_settings WHERE name = 'max_connections'
UNION ALL SELECT 'longest_query_seconds', coalesce(floor(max(extract(epoch FROM now() - query_start))), 0)::bigint
    FROM pg_stat_activity WHERE state = 'active' AND backend_type = 'client backend' AND pid <> pg_backend_pid()
UNION ALL SELECT 'longest_transaction_seconds', coalesce(floor(max(extract(epoch FROM now() - xact_start))), 0)::bigint
    FROM pg_stat_activity WHERE xact_start IS NOT NULL AND backend_type = 'client backend' AND pid <> pg_backend_pid()
UNION ALL SELECT 'commits_count', coalesce(sum(xact_commit), 0)::bigint FROM pg_stat_database
UNION ALL SELECT 'rollbacks_count', coalesce(sum(xact_rollback), 0)::bigint FROM pg_stat_database
UNION ALL SELECT 'deadlocks_count', coalesce(sum(deadlocks), 0)::bigint FROM pg_stat_database
UNION ALL SELECT 'cache_hit_pct', coalesce(floor(100 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0)), 100)::bigint
    FROM pg_stat_database
'@
$ErrorActionPreference = 'Continue'
$out = @(& $psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -c $query 2>&1 | ForEach-Object { "$_" })
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("status: the server refused the login or the queries: $($out -join ' ')")
    exit 1
}

Write-Output 'metric up 1'
$connections = $null; $max = $null
foreach ($line in $out) {
    $name, $value = "$line".Trim().Split(' ', 2)
    if (-not $name -or -not $value) { continue }
    if ($name -ceq 'connections') { $connections = [long]$value }
    if ($name -ceq 'max_connections') { $max = [long]$value }
    Write-Output "metric $name $value"
}
if ($null -ne $connections -and $max -gt 0) {
    Write-Output "metric connections_pct $([long][Math]::Floor(100 * $connections / $max))"
}
