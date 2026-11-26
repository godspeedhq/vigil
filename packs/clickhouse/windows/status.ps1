#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - a ClickHouse server: up, queries and connections, memory, inserts delayed and refused, the most parts in a partition, Keeper, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports one server, the one at CLICKHOUSE_URL: whether it answers, its
    version and uptime; the queries running and the connections open; its
    memory against the most it may use; inserts delayed and refused because a
    partition has too many parts (merges cannot keep up), and that count
    against the limit where inserts are refused; failed queries; and its
    session with Keeper or ZooKeeper, for replicated tables. Run it on every
    server of a cluster: each reports its own.

    Reads ClickHouse at CLICKHOUSE_URL (default http://localhost:8123), its
    HTTP interface, with PowerShell alone: /ping, then one SELECT from
    system.metrics, system.events, system.asynchronous_metrics,
    system.server_settings and system.merge_tree_settings, as CLICKHOUSE_USER
    (a read-only user). What the scripts share is in _clickhouse.ps1, beside
    this one.

    Metrics:
      up                         1 when the server answers, else 0
      info                       always 1, tagged version=<25.8.2.29>
      uptime_seconds             since it started
      queries                    queries running now
      connections                connections open, tagged kind=<tcp, http,
                                 mysql, postgresql, interserver>
      memory_bytes               memory it holds, as it counts it
      memory_limit_bytes         the most it may hold (max_server_memory_usage,
                                 or its share of the machine's memory)
      memory_pct                 memory_bytes, of memory_limit_bytes
      max_parts_in_partition     the most active parts any one partition has
      parts_to_throw_insert      the count where inserts into a partition are
                                 refused (Too many parts), by default
      parts_pct                  max_parts_in_partition, of
                                 parts_to_throw_insert
      inserts_delayed            inserts being slowed down now, for too many
                                 parts
      inserts_delayed_count      inserts slowed down (a running total)
      inserts_rejected_count     inserts refused for too many parts (a running
                                 total)
      queries_count              queries run (a running total)
      failed_queries_count       queries that failed (a running total), tagged
                                 kind=<all, select, insert>
      keeper_sessions            sessions open with Keeper or ZooKeeper (0
                                 without replicated tables). With Keeper
                                 gone it stays 1 while the server retries:
                                 readonly_replicas is what says so
      readonly_replicas          replicated tables gone read-only: cut off from
                                 Keeper
      replica_delay_seconds      how far the furthest-behind replicated table
                                 is
      replica_queue              tasks waiting in the replicated tables' queues

    Example output (the rest are in the same form):
      metric up 1
      metric info 1 version=25.8.2.29
      metric queries 3
      metric connections 12 kind=tcp
      metric memory_pct 31.4
      metric max_parts_in_partition 14
      metric parts_pct 0.47
      metric readonly_replicas 0

    Reading the results (starting points: tune them to the server):
      Healthy  up 1; memory_pct below 80; parts_pct below 10 (a few dozen
               parts a partition); inserts_rejected_count flat;
               readonly_replicas 0; replica_delay_seconds a few seconds.
      Watch    memory_pct past 80; parts_pct past 20, or rising run after run
               (inserts too small or too frequent: merges cannot keep up);
               inserts_delayed above 0; failed_queries_count rising faster than
               usual.
      Act      up 0; memory_pct past 90 (queries are refused for memory);
               inserts_rejected_count rising (Too many parts: inserts fail);
               readonly_replicas above 0 (replicated tables take no writes);
               replica_delay_seconds past 300.

    Requires: PowerShell 5.1 or later
    Exit code: 0 on success, server up or down; 1 if the login is refused, or the
      server answers wrong

    Example (vigil.config):
      [job.clickhouse_status]
      file        = packs/clickhouse/status.ps1
      metric_name = clickhouse
      run_every   = 1m
      env         = CLICKHOUSE_URL=http://localhost:8123
      env         = CLICKHOUSE_USER=vigil
      secret      = CLICKHOUSE_PASSWORD=secret:CLICKHOUSE_PASSWORD
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_clickhouse.ps1')

Up
$rows = @(Get-Rows @"
SELECT 'version' AS k, version() AS v
UNION ALL SELECT 'uptime', toString(uptime())
UNION ALL SELECT concat('m.', metric), toString(value) FROM system.metrics
  WHERE metric IN ('Query', 'TCPConnection', 'HTTPConnection', 'MySQLConnection', 'PostgreSQLConnection', 'InterserverConnection',
                   'MemoryTracking', 'DelayedInserts', 'ZooKeeperSession', 'ReadonlyReplica')
UNION ALL SELECT concat('e.', event), toString(value) FROM system.events
  WHERE event IN ('Query', 'FailedQuery', 'FailedSelectQuery', 'FailedInsertQuery', 'DelayedInserts', 'RejectedInserts')
UNION ALL SELECT concat('a.', metric), toString(value) FROM system.asynchronous_metrics
  WHERE metric IN ('MaxPartCountForPartition', 'ReplicasMaxAbsoluteDelay', 'ReplicasSumQueueSize', 'OSMemoryTotal', 'CGroupMemoryTotal')
UNION ALL SELECT concat('s.', name), value FROM system.server_settings
  WHERE name IN ('max_server_memory_usage', 'max_server_memory_usage_to_ram_ratio')
UNION ALL SELECT concat('t.', name), value FROM system.merge_tree_settings
  WHERE name = 'parts_to_throw_insert'
"@)
$s = @{}
foreach ($r in $rows) { $s[[string]$r.k] = $r.v }
function G([string]$k) { return N $s[$k] }
# The most it may hold: the setting, else its share of the memory it has
# (the cgroup limit when there is one, else the machine's).
$ram = if ($s.ContainsKey('a.CGroupMemoryTotal') -and (G 'a.CGroupMemoryTotal') -gt 0) { G 'a.CGroupMemoryTotal' } else { G 'a.OSMemoryTotal' }
$ratio = if ($s.ContainsKey('s.max_server_memory_usage_to_ram_ratio')) { G 's.max_server_memory_usage_to_ram_ratio' } else { 0.9 }
$lim = if ((G 's.max_server_memory_usage') -gt 0) { G 's.max_server_memory_usage' } else { [Math]::Floor($ram * $ratio) }
$version = if ($s.ContainsKey('version')) { $s['version'] } else { 'unknown' }
"metric info 1 version=$(Safe $version)"
M 'uptime_seconds' (G 'uptime')
M 'queries' (G 'm.Query')
M 'connections' (G 'm.TCPConnection') 'kind=tcp'
M 'connections' (G 'm.HTTPConnection') 'kind=http'
if ($s.ContainsKey('m.MySQLConnection')) { M 'connections' (G 'm.MySQLConnection') 'kind=mysql' }
if ($s.ContainsKey('m.PostgreSQLConnection')) { M 'connections' (G 'm.PostgreSQLConnection') 'kind=postgresql' }
if ($s.ContainsKey('m.InterserverConnection')) { M 'connections' (G 'm.InterserverConnection') 'kind=interserver' }
M 'memory_bytes' (G 'm.MemoryTracking')
if ($lim -gt 0) {
    M 'memory_limit_bytes' $lim
    M 'memory_pct' (100 * (G 'm.MemoryTracking') / $lim)
}
M 'max_parts_in_partition' (G 'a.MaxPartCountForPartition')
if ((G 't.parts_to_throw_insert') -gt 0) {
    M 'parts_to_throw_insert' (G 't.parts_to_throw_insert')
    M 'parts_pct' (100 * (G 'a.MaxPartCountForPartition') / (G 't.parts_to_throw_insert'))
}
M 'inserts_delayed' (G 'm.DelayedInserts')
M 'inserts_delayed_count' (G 'e.DelayedInserts')
M 'inserts_rejected_count' (G 'e.RejectedInserts')
M 'queries_count' (G 'e.Query')
M 'failed_queries_count' (G 'e.FailedQuery') 'kind=all'
M 'failed_queries_count' (G 'e.FailedSelectQuery') 'kind=select'
M 'failed_queries_count' (G 'e.FailedInsertQuery') 'kind=insert'
M 'keeper_sessions' (G 'm.ZooKeeperSession')
M 'readonly_replicas' (G 'm.ReadonlyReplica')
M 'replica_delay_seconds' (G 'a.ReplicasMaxAbsoluteDelay')
M 'replica_queue' (G 'a.ReplicasSumQueueSize')
exit 0
