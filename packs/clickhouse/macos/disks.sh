#!/usr/bin/env bash
#
# disks.sh - ClickHouse's disks: free space, used, and the space it keeps
# free, each disk of its storage policies
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
# Reports each disk ClickHouse writes to, as it sees it: its size, the
# space free, how much is used, and the space it is told to keep free. A
# merge needs room for its new part before it can drop the old ones, so a
# disk that fills stops merges first, then inserts. An object store (S3)
# has no size, and reports none.
#
# Reads ClickHouse at CLICKHOUSE_URL with curl and jq: system.disks. What
# the scripts share is in _clickhouse.sh, beside this one.
#
# Metrics:
#   up                1 when the server answers, else 0
#   disks             disks ClickHouse uses
#   free_bytes        a disk's free space, tagged disk=<name>
#   total_bytes       its size
#   used_pct          how much of it is used
#   keep_free_bytes   the space ClickHouse keeps free on it
#   used_pct_max      the fullest disk's used_pct
#
# Example output (the rest are in the same form):
#   metric disks 1
#   metric free_bytes 52613349376 disk=default
#   metric total_bytes 107374182400 disk=default
#   metric used_pct 51 disk=default
#   metric used_pct_max 51
#
# Reading the results (starting points: tune them to the server):
#   Healthy  used_pct_max below 70, room for the largest merge.
#   Watch    used_pct_max past 80: merges of large parts may not find room.
#   Act      used_pct_max past 90: merges stop, parts pile up, then inserts
#            fail.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, server up or down; 1 if curl or jq is missing,
#   the login is refused, or the server answers wrong
#
# Example (vigil.config):
#   [job.clickhouse_disks]
#   file        = packs/clickhouse/disks.sh
#   metric_name = clickhouse.disks
#   run_every   = 5m
#   env         = CLICKHOUSE_URL=http://localhost:8123
#   env         = CLICKHOUSE_USER=vigil
#   secret      = CLICKHOUSE_PASSWORD=secret:CLICKHOUSE_PASSWORD

set -u

job=disks
# shellcheck source=/dev/null
. "$(dirname "$0")/_clickhouse.sh"

up
sel "SELECT name, free_space, total_space, keep_free_space FROM system.disks ORDER BY name"
jq -r "$jqlib"'
    m("disks"; length),
    (.[] | "disk=\(.name | tag)" as $t
        | m("free_bytes"; .free_space; $t),
          (if (.total_space | n) > 0 then
              m("total_bytes"; .total_space; $t),
              m("used_pct"; 100 * ((.total_space | n) - (.free_space | n)) / (.total_space | n); $t)
           else empty end),
          m("keep_free_bytes"; .keep_free_space; $t)),
    (map(select((.total_space | n) > 0) | 100 * ((.total_space | n) - (.free_space | n)) / (.total_space | n)) | max) as $w
    | if $w == null then empty else m("used_pct_max"; $w) end
' "$work/rows"
exit 0
