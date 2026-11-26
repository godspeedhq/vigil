#!/usr/bin/env bash
#
# tables.sh - ClickHouse's tables: parts and partitions, the most parts in a
# partition, rows and bytes, the worst first
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
# Reports each MergeTree table on the server: its active parts, its
# partitions, the most parts any one partition has, its rows and the bytes
# it takes on disk. A partition with too many parts is the table whose
# inserts will be slowed, then refused (Too many parts): it is named here
# before that happens, the worst first. The system database's own tables
# (query_log and the others) are tables like any.
#
# Reads ClickHouse at CLICKHOUSE_URL with curl and jq: one SELECT from
# system.parts. CLICKHOUSE_MOST (default 50) is how many tables are named;
# the rest are counted. What the scripts share is in _clickhouse.sh, beside
# this one.
#
# Metrics:
#   up                         1 when the server answers, else 0
#   tables                     MergeTree tables with data
#   parts                      active parts, every table's together
#   rows                       rows, every table's together
#   bytes                      bytes on disk, every table's together
#   table_parts                a table's active parts, tagged
#                              table=<database.table>
#   table_partitions           its partitions
#   table_max_parts            the most parts one of its partitions has
#   table_rows                 its rows
#   table_bytes                its bytes on disk
#   tables_not_shown           tables past CLICKHOUSE_MOST, counted in the
#                              totals and not named
#
# Example output (the rest are in the same form):
#   metric tables 12
#   metric parts 210
#   metric table_parts 96 table=default.events
#   metric table_max_parts 41 table=default.events
#   metric table_bytes 12884901888 table=default.events
#
# Reading the results (starting points: tune them to the server):
#   Healthy  table_max_parts a few dozen at most; table_parts steady.
#   Watch    table_max_parts past 300, or rising run after run: inserts too
#            small or too frequent for merges to keep up (batch them, or
#            use async inserts); a table's bytes growing faster than usual.
#   Act      table_max_parts near parts_to_throw_insert (the status job
#            says the limit, 3000 by default): inserts into it are about to
#            be refused.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, server up or down; 1 if curl or jq is missing,
#   the login is refused, or the server answers wrong
#
# Example (vigil.config):
#   [job.clickhouse_tables]
#   file        = packs/clickhouse/tables.sh
#   metric_name = clickhouse.tables
#   run_every   = 5m
#   env         = CLICKHOUSE_URL=http://localhost:8123
#   env         = CLICKHOUSE_USER=vigil
#   secret      = CLICKHOUSE_PASSWORD=secret:CLICKHOUSE_PASSWORD

set -u

job=tables
# shellcheck source=/dev/null
. "$(dirname "$0")/_clickhouse.sh"

up
sel "SELECT database, table, sum(n) AS parts, count() AS partitions, max(n) AS worst, sum(r) AS rows, sum(b) AS bytes
FROM (SELECT database, table, partition_id, count() AS n, sum(rows) AS r, sum(bytes_on_disk) AS b
      FROM system.parts WHERE active GROUP BY database, table, partition_id)
GROUP BY database, table ORDER BY worst DESC, bytes DESC, database, table"
jq -r --argjson most "$most" "$jqlib"'
    m("tables"; length),
    m("parts"; map(.parts | n) | add // 0),
    m("rows"; map(.rows | n) | add // 0),
    m("bytes"; map(.bytes | n) | add // 0),
    (.[0:$most][] | "table=\(.database + "." + .table | tag)" as $t
        | m("table_parts"; .parts; $t),
          m("table_partitions"; .partitions; $t),
          m("table_max_parts"; .worst; $t),
          m("table_rows"; .rows; $t),
          m("table_bytes"; .bytes; $t)),
    (if length > $most then m("tables_not_shown"; length - $most) else empty end)
' "$work/rows"
exit 0
