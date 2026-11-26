#Requires -Version 5.1

<#
.SYNOPSIS
    replication.ps1 - ClickHouse's replicated tables: read-only, behind, their queues and the replicas active, the worst first, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each ReplicatedMergeTree table on this server, as this replica
    sees it: read-only (its session with Keeper or ZooKeeper lost, so it
    takes no writes), how far behind the others it is, the tasks in its queue
    (parts to fetch, merges to do) and those that keep failing, the oldest
    task, and how many of the table's replicas are active. The worst first:
    read-only, then the furthest behind. Run it on every server: each reports
    its own replicas. A server with no replicated tables reports replicated 0.

    Reads ClickHouse at CLICKHOUSE_URL with PowerShell alone: system.replicas and
    system.replication_queue. CLICKHOUSE_MOST (default 50) is how many tables
    are named; the rest are counted. What the scripts share is in
    _clickhouse.ps1, beside this one.

    Metrics:
      up                      1 when the server answers, else 0
      replicated              replicated tables on this server
      readonly                of those, how many are read-only
      replicas_missing        replicas that are not active, every table's
                              together
      queue_failing           tasks tried and failed several times, every
                              table's together
      table_readonly          1 when the table is read-only, else 0, tagged
                              table=<database.table>
      table_delay_seconds     how far this replica is behind
      table_queue             tasks in its queue
      table_queue_inserts     of those, parts to fetch
      table_queue_merges      of those, merges to do
      table_queue_failing     of those, tasks tried and failed several times
      table_queue_oldest_seconds  the oldest task's age
      table_log_behind        entries of the shared log this replica has not
                              read yet
      table_replicas_active   the table's replicas active
      table_replicas          the table's replicas
      replicated_not_shown    tables past CLICKHOUSE_MOST, counted and not
                              named

    Example output (the rest are in the same form):
      metric replicated 2
      metric readonly 0
      metric table_readonly 0 table=default.events
      metric table_delay_seconds 0 table=default.events
      metric table_replicas_active 2 table=default.events
      metric table_replicas 2 table=default.events

    Reading the results (starting points: tune them to the cluster):
      Healthy  readonly 0; replicas_missing 0; table_delay_seconds a few
               seconds; table_queue small and falling; queue_failing 0.
      Watch    table_delay_seconds past 60; table_queue rising run after run;
               table_queue_oldest_seconds past 600.
      Act      readonly above 0 (writes to the table fail: the session with
               Keeper is lost); replicas_missing above 0 (a replica is down);
               queue_failing above 0 and not falling (a task fails again and
               again: system.replication_queue's last_exception says why);
               table_delay_seconds past 300.

    Requires: PowerShell 5.1 or later
    Exit code: 0 on success, server up or down; 1 if the login is refused, or the
      server answers wrong

    Example (vigil.config):
      [job.clickhouse_replication]
      file        = packs/clickhouse/replication.ps1
      metric_name = clickhouse.replication
      run_every   = 1m
      env         = CLICKHOUSE_URL=http://localhost:8123
      env         = CLICKHOUSE_USER=vigil
      secret      = CLICKHOUSE_PASSWORD=secret:CLICKHOUSE_PASSWORD
#>

$Job = 'replication'
. (Join-Path $PSScriptRoot '_clickhouse.ps1')

Up
$most = [int]$script:Most
$reps = @(Get-Rows @"
SELECT database, table, is_readonly, queue_size, inserts_in_queue, merges_in_queue, absolute_delay,
       total_replicas, active_replicas, log_max_index - log_pointer AS log_behind
FROM system.replicas
"@)
$queue = @{}
foreach ($q in @(Get-Rows @"
SELECT database, table, countIf(num_tries > 3 AND last_exception != '') AS failing,
       max(dateDiff('second', create_time, now())) AS oldest
FROM system.replication_queue GROUP BY database, table
"@)) { $queue[$q.database + '.' + $q.table] = $q }
$all = @(foreach ($r in $reps) {
        $k = $r.database + '.' + $r.table
        $q = $queue[$k]
        [pscustomobject]@{
            Key = $k; Readonly = N $r.is_readonly; Delay = N $r.absolute_delay; Queue = N $r.queue_size
            Inserts = N $r.inserts_in_queue; Merges = N $r.merges_in_queue; Behind = N $r.log_behind
            Active = N $r.active_replicas; Total = N $r.total_replicas
            Failing = $(if ($q) { N $q.failing } else { 0 }); Oldest = $(if ($q) { N $q.oldest } else { 0 })
        }
    })
# The worst first: read-only, then the furthest behind, the longest queue.
# By key last, ordinally, as jq sorts.
$all = @($all | Sort-Object @{ Expression = 'Readonly'; Descending = $true }, @{ Expression = 'Delay'; Descending = $true }, @{ Expression = 'Queue'; Descending = $true }, @{ Expression = { [string]$_.Key } })
$t = @{ readonly = 0; missing = 0; failing = 0 }
foreach ($r in $all) { $t.readonly += $r.Readonly; $t.missing += $r.Total - $r.Active; $t.failing += $r.Failing }
M 'replicated' $all.Count
M 'readonly' $t.readonly
M 'replicas_missing' $t.missing
M 'queue_failing' $t.failing
foreach ($r in @($all | Select-Object -First $most)) {
    $tag = "table=$(Safe $r.Key)"
    M 'table_readonly' $r.Readonly $tag
    M 'table_delay_seconds' $r.Delay $tag
    M 'table_queue' $r.Queue $tag
    M 'table_queue_inserts' $r.Inserts $tag
    M 'table_queue_merges' $r.Merges $tag
    M 'table_queue_failing' $r.Failing $tag
    M 'table_queue_oldest_seconds' $r.Oldest $tag
    M 'table_log_behind' $r.Behind $tag
    M 'table_replicas_active' $r.Active $tag
    M 'table_replicas' $r.Total $tag
}
if ($all.Count -gt $most) { M 'replicated_not_shown' ($all.Count - $most) }
exit 0
