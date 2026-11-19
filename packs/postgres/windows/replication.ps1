#Requires -Version 5.1

<#
.SYNOPSIS
    replication.ps1 - a PostgreSQL server's streaming replication, on
    Windows
.DESCRIPTION
    On a primary: the streaming replicas connected, how far each is behind,
    and its replication slots, which keep WAL until whatever uses them
    catches up. On a replica: whether it is receiving from its primary, and
    how far its replay is behind. A server with neither reports is_replica
    0, replicas 0 and slots_inactive 0. The server may be anywhere this
    machine can reach. Connects as the libpq environment says: PGHOST,
    PGPORT, PGUSER, PGDATABASE and PGPASSWORD, set by the job. psql and
    pg_isready are looked for on the PATH, then in PostgreSQL's own folders
    under Program Files, the newest version first.

    Metrics:
        is_replica           1 on a replica (in recovery), 0 on a primary
        replicas             (primary) streaming replicas connected
        lag_bytes            (primary) WAL a replica has not yet replayed,
                             tagged replica=<its application_name>
        lag_seconds          (primary) that replica's replay lag in time; 0
                             when there is nothing to replay
        slots_inactive       (primary) replication slots nothing is using now
        slot_retained_bytes  (primary) WAL a slot keeps, tagged slot=<its name>
        receiver_up          (replica) 1 while it streams from its primary
        replay_lag_bytes     (replica) WAL received but not yet replayed
        last_replay_seconds  (replica) since the last transaction it replayed

    Example output, on a primary with one replica:
      metric is_replica 0
      metric replicas 1
      metric slots_inactive 0
      metric lag_bytes 0 replica=standby1
      metric lag_seconds 0 replica=standby1
      metric slot_retained_bytes 16496 slot=standby1

    Reading the results (starting points: tune them to the server):
      Healthy  replicas as many as you run; lag_bytes near 0 and lag_seconds
               a few seconds at most; slots_inactive 0; on a replica,
               receiver_up 1.
      Watch    lag rising during heavy writes and not falling after them.
      Act      replicas below what you run, or receiver_up 0: a replica is
               not streaming. slots_inactive above 0 and slot_retained_bytes
               growing: an unused slot keeps every WAL file until the disk
               fills; drop it (pg_drop_replication_slot) if nothing will use
               it again. last_replay_seconds also grows when the primary
               simply has nothing to write: read it with lag_bytes.

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
    [Console]::Error.WriteLine('replication: psql or pg_isready not found: install PostgreSQL''s client tools')
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
        [Console]::Error.WriteLine("replication: the server refused the login or the queries: $($o -join ' ')")
        exit 1
    }
    return , $o
}

$replica = "$(@(Invoke-Psql 'SELECT pg_is_in_recovery()::int')[0])".Trim()

# One "name value [tag]" row per metric. A name in a tag keeps letters,
# digits, _, . and - only.
if ($replica -eq '1') {
    $rows = Invoke-Psql @'
SELECT 'receiver_up', count(*) FROM pg_stat_wal_receiver WHERE status = 'streaming'
UNION ALL SELECT 'replay_lag_bytes',
    coalesce(greatest(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()), 0), 0)::bigint
UNION ALL SELECT 'last_replay_seconds',
    coalesce(floor(extract(epoch FROM now() - pg_last_xact_replay_timestamp())), 0)::bigint
'@
}
else {
    $rows = Invoke-Psql @'
SELECT 'replicas', count(*), '' FROM pg_stat_replication WHERE state = 'streaming'
UNION ALL SELECT 'slots_inactive', count(*), '' FROM pg_replication_slots WHERE NOT active
UNION ALL SELECT 'lag_bytes', coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), 0)::bigint,
    'replica=' || regexp_replace(coalesce(nullif(application_name, ''), 'unnamed'), '[^A-Za-z0-9_.-]', '_', 'g')
    FROM pg_stat_replication
UNION ALL SELECT 'lag_seconds', coalesce(floor(extract(epoch FROM replay_lag)), 0)::bigint,
    'replica=' || regexp_replace(coalesce(nullif(application_name, ''), 'unnamed'), '[^A-Za-z0-9_.-]', '_', 'g')
    FROM pg_stat_replication
UNION ALL SELECT 'slot_retained_bytes', coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0)::bigint,
    'slot=' || regexp_replace(slot_name, '[^A-Za-z0-9_.-]', '_', 'g')
    FROM pg_replication_slots
'@
}

Write-Output "metric is_replica $replica"
foreach ($line in $rows) {
    $parts = "$line".Trim().Split(' ', 3)
    if ($parts.Count -lt 2 -or -not $parts[0]) { continue }
    if ($parts.Count -eq 3 -and $parts[2]) { Write-Output "metric $($parts[0]) $($parts[1]) $($parts[2])" }
    else { Write-Output "metric $($parts[0]) $($parts[1])" }
}
