#!/usr/bin/env bash
#
# replication.sh - ClickHouse's replicated tables: read-only, behind, their
# queues and the replicas active, the worst first
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
# Reports each ReplicatedMergeTree table on this server, as this replica
# sees it: read-only (its session with Keeper or ZooKeeper lost, so it
# takes no writes), how far behind the others it is, the tasks in its queue
# (parts to fetch, merges to do) and those that keep failing, the oldest
# task, and how many of the table's replicas are active. The worst first:
# read-only, then the furthest behind. Run it on every server: each reports
# its own replicas. A server with no replicated tables reports replicated 0.
#
# Reads ClickHouse at CLICKHOUSE_URL with curl and jq: system.replicas and
# system.replication_queue. CLICKHOUSE_MOST (default 50) is how many tables
# are named; the rest are counted. What the scripts share is in
# _clickhouse.sh, beside this one.
#
# Metrics:
#   up                      1 when the server answers, else 0
#   replicated              replicated tables on this server
#   readonly                of those, how many are read-only
#   replicas_missing        replicas that are not active, every table's
#                           together
#   queue_failing           tasks tried and failed several times, every
#                           table's together
#   table_readonly          1 when the table is read-only, else 0, tagged
#                           table=<database.table>
#   table_delay_seconds     how far this replica is behind
#   table_queue             tasks in its queue
#   table_queue_inserts     of those, parts to fetch
#   table_queue_merges      of those, merges to do
#   table_queue_failing     of those, tasks tried and failed several times
#   table_queue_oldest_seconds  the oldest task's age
#   table_log_behind        entries of the shared log this replica has not
#                           read yet
#   table_replicas_active   the table's replicas active
#   table_replicas          the table's replicas
#   replicated_not_shown    tables past CLICKHOUSE_MOST, counted and not
#                           named
#
# Example output (the rest are in the same form):
#   metric replicated 2
#   metric readonly 0
#   metric table_readonly 0 table=default.events
#   metric table_delay_seconds 0 table=default.events
#   metric table_replicas_active 2 table=default.events
#   metric table_replicas 2 table=default.events
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  readonly 0; replicas_missing 0; table_delay_seconds a few
#            seconds; table_queue small and falling; queue_failing 0.
#   Watch    table_delay_seconds past 60; table_queue rising run after run;
#            table_queue_oldest_seconds past 600.
#   Act      readonly above 0 (writes to the table fail: the session with
#            Keeper is lost); replicas_missing above 0 (a replica is down);
#            queue_failing above 0 and not falling (a task fails again and
#            again: system.replication_queue's last_exception says why);
#            table_delay_seconds past 300.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, server up or down; 1 if curl or jq is missing,
#   the login is refused, or the server answers wrong
#
# Example (vigil.config):
#   [job.clickhouse_replication]
#   file        = packs/clickhouse/replication.sh
#   metric_name = clickhouse.replication
#   run_every   = 1m
#   env         = CLICKHOUSE_URL=http://localhost:8123
#   env         = CLICKHOUSE_USER=vigil
#   secret      = CLICKHOUSE_PASSWORD=secret:CLICKHOUSE_PASSWORD

set -u

job=replication
# shellcheck source=/dev/null
. "$(dirname "$0")/_clickhouse.sh"

up
sel "SELECT database, table, is_readonly, queue_size, inserts_in_queue, merges_in_queue, absolute_delay,
       total_replicas, active_replicas, log_max_index - log_pointer AS log_behind
FROM system.replicas"
mv "$work/rows" "$work/replicas"
sel "SELECT database, table, countIf(num_tries > 3 AND last_exception != '') AS failing,
       max(dateDiff('second', create_time, now())) AS oldest
FROM system.replication_queue GROUP BY database, table"
jq -r --argjson most "$most" --slurpfile q "$work/rows" "$jqlib"'
    ($q[0] | map({(.database + "." + .table): .}) | add // {}) as $queue
    | map(. + {key: (.database + "." + .table)}
          | . + {failing: ($queue[.key].failing // 0 | n), oldest: ($queue[.key].oldest // 0 | n)})
    | sort_by(-(.is_readonly | n), -(.absolute_delay | n), -(.queue_size | n), .key)
    | m("replicated"; length),
      m("readonly"; map(.is_readonly | n) | add // 0),
      m("replicas_missing"; map((.total_replicas | n) - (.active_replicas | n)) | add // 0),
      m("queue_failing"; map(.failing) | add // 0),
      (.[0:$most][] | "table=\(.key | tag)" as $t
          | m("table_readonly"; .is_readonly; $t),
            m("table_delay_seconds"; .absolute_delay; $t),
            m("table_queue"; .queue_size; $t),
            m("table_queue_inserts"; .inserts_in_queue; $t),
            m("table_queue_merges"; .merges_in_queue; $t),
            m("table_queue_failing"; .failing; $t),
            m("table_queue_oldest_seconds"; .oldest; $t),
            m("table_log_behind"; .log_behind; $t),
            m("table_replicas_active"; .active_replicas; $t),
            m("table_replicas"; .total_replicas; $t)),
      (if length > $most then m("replicated_not_shown"; length - $most) else empty end)
' "$work/replicas"
exit 0
