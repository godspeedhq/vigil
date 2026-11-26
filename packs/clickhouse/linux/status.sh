#!/usr/bin/env bash
#
# status.sh - a ClickHouse server: up, queries and connections, memory,
# inserts delayed and refused, the most parts in a partition, Keeper
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Reports one server, the one at CLICKHOUSE_URL: whether it answers, its
# version and uptime; the queries running and the connections open; its
# memory against the most it may use; inserts delayed and refused because a
# partition has too many parts (merges cannot keep up), and that count
# against the limit where inserts are refused; failed queries; and its
# session with Keeper or ZooKeeper, for replicated tables. Run it on every
# server of a cluster: each reports its own.
#
# Reads ClickHouse at CLICKHOUSE_URL (default http://localhost:8123), its
# HTTP interface, with curl and jq: /ping, then one SELECT from
# system.metrics, system.events, system.asynchronous_metrics,
# system.server_settings and system.merge_tree_settings, as CLICKHOUSE_USER
# (a read-only user). What the scripts share is in _clickhouse.sh, beside
# this one.
#
# Metrics:
#   up                         1 when the server answers, else 0
#   info                       always 1, tagged version=<25.8.2.29>
#   uptime_seconds             since it started
#   queries                    queries running now
#   connections                connections open, tagged kind=<tcp, http,
#                              mysql, postgresql, interserver>
#   memory_bytes               memory it holds, as it counts it
#   memory_limit_bytes         the most it may hold (max_server_memory_usage,
#                              or its share of the machine's memory)
#   memory_pct                 memory_bytes, of memory_limit_bytes
#   max_parts_in_partition     the most active parts any one partition has
#   parts_to_throw_insert      the count where inserts into a partition are
#                              refused (Too many parts), by default
#   parts_pct                  max_parts_in_partition, of
#                              parts_to_throw_insert
#   inserts_delayed            inserts being slowed down now, for too many
#                              parts
#   inserts_delayed_count      inserts slowed down (a running total)
#   inserts_rejected_count     inserts refused for too many parts (a running
#                              total)
#   queries_count              queries run (a running total)
#   failed_queries_count       queries that failed (a running total), tagged
#                              kind=<all, select, insert>
#   keeper_sessions            sessions open with Keeper or ZooKeeper (0
#                              without replicated tables)
#   readonly_replicas          replicated tables gone read-only: cut off from
#                              Keeper
#   replica_delay_seconds      how far the furthest-behind replicated table
#                              is
#   replica_queue              tasks waiting in the replicated tables' queues
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric info 1 version=25.8.2.29
#   metric queries 3
#   metric connections 12 kind=tcp
#   metric memory_pct 31.4
#   metric max_parts_in_partition 14
#   metric parts_pct 0.47
#   metric readonly_replicas 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  up 1; memory_pct below 80; parts_pct below 10 (a few dozen
#            parts a partition); inserts_rejected_count flat;
#            readonly_replicas 0; replica_delay_seconds a few seconds.
#   Watch    memory_pct past 80; parts_pct past 20, or rising run after run
#            (inserts too small or too frequent: merges cannot keep up);
#            inserts_delayed above 0; failed_queries_count rising faster than
#            usual.
#   Act      up 0; memory_pct past 90 (queries are refused for memory);
#            inserts_rejected_count rising (Too many parts: inserts fail);
#            readonly_replicas above 0 (replicated tables take no writes);
#            replica_delay_seconds past 300.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, server up or down; 1 if curl or jq is missing,
#   the login is refused, or the server answers wrong
#
# Example (vigil.config):
#   [job.clickhouse_status]
#   file        = packs/clickhouse/status.sh
#   metric_name = clickhouse
#   run_every   = 1m
#   env         = CLICKHOUSE_URL=http://localhost:8123
#   env         = CLICKHOUSE_USER=vigil
#   secret      = CLICKHOUSE_PASSWORD=secret:CLICKHOUSE_PASSWORD

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_clickhouse.sh"

up
sel "SELECT 'version' AS k, version() AS v
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
  WHERE name = 'parts_to_throw_insert'"
jq -r "$jqlib"'
    (map({(.k): .v}) | add // {}) as $s
    | def g($k): $s[$k] | n;
    def got($k): $s | has($k);
    # The most it may hold: the setting, else its share of the memory it
    # has (the cgroup limit when there is one, else the machine'"'"'s).
    ((if got("a.CGroupMemoryTotal") and g("a.CGroupMemoryTotal") > 0 then g("a.CGroupMemoryTotal") else g("a.OSMemoryTotal") end)) as $ram
    | (if g("s.max_server_memory_usage") > 0 then g("s.max_server_memory_usage") else ($ram * (if got("s.max_server_memory_usage_to_ram_ratio") then g("s.max_server_memory_usage_to_ram_ratio") else 0.9 end) | floor) end) as $lim
    | "metric info 1 version=\($s.version // "unknown" | tag)",
      m("uptime_seconds"; g("uptime")),
      m("queries"; g("m.Query")),
      m("connections"; g("m.TCPConnection"); "kind=tcp"),
      m("connections"; g("m.HTTPConnection"); "kind=http"),
      (if got("m.MySQLConnection") then m("connections"; g("m.MySQLConnection"); "kind=mysql") else empty end),
      (if got("m.PostgreSQLConnection") then m("connections"; g("m.PostgreSQLConnection"); "kind=postgresql") else empty end),
      (if got("m.InterserverConnection") then m("connections"; g("m.InterserverConnection"); "kind=interserver") else empty end),
      m("memory_bytes"; g("m.MemoryTracking")),
      (if $lim > 0 then m("memory_limit_bytes"; $lim), m("memory_pct"; 100 * g("m.MemoryTracking") / $lim) else empty end),
      m("max_parts_in_partition"; g("a.MaxPartCountForPartition")),
      (if g("t.parts_to_throw_insert") > 0 then
          m("parts_to_throw_insert"; g("t.parts_to_throw_insert")),
          m("parts_pct"; 100 * g("a.MaxPartCountForPartition") / g("t.parts_to_throw_insert"))
       else empty end),
      m("inserts_delayed"; g("m.DelayedInserts")),
      m("inserts_delayed_count"; g("e.DelayedInserts")),
      m("inserts_rejected_count"; g("e.RejectedInserts")),
      m("queries_count"; g("e.Query")),
      m("failed_queries_count"; g("e.FailedQuery"); "kind=all"),
      m("failed_queries_count"; g("e.FailedSelectQuery"); "kind=select"),
      m("failed_queries_count"; g("e.FailedInsertQuery"); "kind=insert"),
      m("keeper_sessions"; g("m.ZooKeeperSession")),
      m("readonly_replicas"; g("m.ReadonlyReplica")),
      m("replica_delay_seconds"; g("a.ReplicasMaxAbsoluteDelay")),
      m("replica_queue"; g("a.ReplicasSumQueueSize"))
' "$work/rows"
exit 0
