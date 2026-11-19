#Requires -Version 5.1

<#
.SYNOPSIS
    io.ps1 - a PostgreSQL server's checkpoints, temporary files and WAL, on
    Windows
.DESCRIPTION
    Running totals since the server's statistics were last reset:
    checkpoints on schedule and those forced by WAL volume, the temporary
    files queries wrote when they ran out of memory, and the WAL written.
    PostgreSQL 17 moved the checkpoint counts to pg_stat_checkpointer; this
    reads whichever the server has. The server may be anywhere this machine
    can reach. Connects as the libpq environment says: PGHOST, PGPORT,
    PGUSER, PGDATABASE and PGPASSWORD, set by the job. psql and pg_isready
    are looked for on the PATH, then in PostgreSQL's own folders under
    Program Files, the newest version first.

    Metrics:
        checkpoints_timed_count      checkpoints started on schedule
                                     (checkpoint_timeout) (a running total)
        checkpoints_requested_count  checkpoints forced early, mostly by WAL
                                     reaching max_wal_size (a running total)
        temp_files_count             temporary files queries wrote (a
                                     running total)
        temp_bytes                   bytes they wrote (a running total)
        wal_bytes                    WAL written (a running total)

    Example output:
      metric checkpoints_timed_count 142
      metric checkpoints_requested_count 3
      metric temp_files_count 0
      metric temp_bytes 0
      metric wal_bytes 98314512

    Reading the results (starting points: tune them to the server). Graph
    each as a rate: the totals restart when the statistics are reset.
      Healthy  checkpoints nearly all timed; temp files rare.
      Watch    checkpoints_requested_count rising alongside timed ones: WAL
               fills max_wal_size before checkpoint_timeout.
      Act      requested checkpoints outnumber timed ones: raise
               max_wal_size. temp_bytes rising fast: sorts and hashes spill
               to disk; find the queries (log_temp_files) and raise work_mem
               for them.

    When the server does not answer, it prints nothing and succeeds:
    postgres_status reports that, as postgres.up 0.

    Requires: Windows PowerShell 5.1 or PowerShell 7, psql and pg_isready
      (PostgreSQL's client tools), PostgreSQL 14 or later, and a role with
      pg_monitor
    Exit code: 0 on success, or when the server does not answer; 1 if psql or
      pg_isready is missing, the server refuses the login or the queries, or
      it is older than PostgreSQL 14
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
    [Console]::Error.WriteLine('io: psql or pg_isready not found: install PostgreSQL''s client tools')
    exit 1
}
& $ready -q -t 5
if ($LASTEXITCODE -ne 0) { exit 0 }

# The rows of $Query, one string each; exits saying why when it fails.
function Invoke-Psql {
    param([string]$Query)
    $ErrorActionPreference = 'Continue'
    $o = @(& $psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -c $Query 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("io: the server refused the login or the queries: $($o -join ' ')")
        exit 1
    }
    return , $o
}

$version = 0
[void][int]::TryParse("$(@(Invoke-Psql 'SELECT current_setting(''server_version_num'')')[0])".Trim(), [ref]$version)
if ($version -lt 140000) {
    [Console]::Error.WriteLine("io: PostgreSQL 14 or later is needed (pg_stat_wal); this server is $version")
    exit 1
}
if ($version -ge 170000) {
    $checkpoints = @'
SELECT 'checkpoints_timed_count', num_timed FROM pg_stat_checkpointer
UNION ALL SELECT 'checkpoints_requested_count', num_requested FROM pg_stat_checkpointer
'@
}
else {
    $checkpoints = @'
SELECT 'checkpoints_timed_count', checkpoints_timed FROM pg_stat_bgwriter
UNION ALL SELECT 'checkpoints_requested_count', checkpoints_req FROM pg_stat_bgwriter
'@
}

$rows = Invoke-Psql ($checkpoints + @'

UNION ALL SELECT 'temp_files_count', coalesce(sum(temp_files), 0)::bigint FROM pg_stat_database
UNION ALL SELECT 'temp_bytes', coalesce(sum(temp_bytes), 0)::bigint FROM pg_stat_database
UNION ALL SELECT 'wal_bytes', wal_bytes::bigint FROM pg_stat_wal
'@)
foreach ($line in $rows) {
    $name, $value = "$line".Trim().Split(' ', 2)
    if ($name -and $value) { Write-Output "metric $name $value" }
}
