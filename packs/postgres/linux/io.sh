#!/usr/bin/env bash
#
# io.sh - a PostgreSQL server's checkpoints, temporary files and WAL
#
# Running totals since the server's statistics were last reset: checkpoints
# on schedule and those forced by WAL volume, the temporary files queries
# wrote when they ran out of memory, and the WAL written. PostgreSQL 17 moved
# the checkpoint counts to pg_stat_checkpointer; this reads whichever the
# server has. Connects as the libpq environment says: PGHOST, PGPORT, PGUSER,
# PGDATABASE and PGPASSWORD, set by the job.
#
# Metrics:
#   checkpoints_timed_count      checkpoints started on schedule
#                                (checkpoint_timeout) (a running total)
#   checkpoints_requested_count  checkpoints forced early, mostly by WAL
#                                reaching max_wal_size (a running total)
#   temp_files_count             temporary files queries wrote (a running
#                                total)
#   temp_bytes                   bytes they wrote (a running total)
#   wal_bytes                    WAL written (a running total)
#
# Example output:
#   metric checkpoints_timed_count 142
#   metric checkpoints_requested_count 3
#   metric temp_files_count 0
#   metric temp_bytes 0
#   metric wal_bytes 98314512
#
# Reading the results (starting points: tune them to the server). Graph each
# as a rate: the totals restart when the statistics are reset.
#   Healthy  checkpoints nearly all timed; temp files rare.
#   Watch    checkpoints_requested_count rising alongside timed ones: WAL
#            fills max_wal_size before checkpoint_timeout, and writes come in
#            bursts.
#   Act      requested checkpoints outnumber timed ones: raise max_wal_size.
#            temp_bytes rising fast: sorts and hashes spill to disk; find the
#            queries (log_temp_files) and raise work_mem for them.
#
# When the server does not answer, it prints nothing and succeeds:
# postgres_status reports that, as postgres.up 0.
#
# Requires: bash, psql and pg_isready (PostgreSQL's client tools), PostgreSQL
#   14 or later, and a role with pg_monitor
# Exit code: 0 on success, or when the server does not answer; 1 if psql or
#   pg_isready is missing, the server refuses the login or the queries, or
#   it is older than PostgreSQL 14
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

set -u

for tool in psql pg_isready; do
    command -v "$tool" > /dev/null 2>&1 || { echo "io: $tool not found: install PostgreSQL's client tools" >&2; exit 1; }
done
pg_isready -q -t 5 || exit 0

q() { psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -c "$1" 2>&1; }

version=$(q "SELECT current_setting('server_version_num')") ||
    { echo "io: the server refused the login or the queries: $version" >&2; exit 1; }
if [ "$version" -lt 140000 ]; then
    echo "io: PostgreSQL 14 or later is needed (pg_stat_wal); this server is $version" >&2
    exit 1
fi
if [ "$version" -ge 170000 ]; then
    checkpoints="SELECT 'checkpoints_timed_count', num_timed FROM pg_stat_checkpointer
UNION ALL SELECT 'checkpoints_requested_count', num_requested FROM pg_stat_checkpointer"
else
    checkpoints="SELECT 'checkpoints_timed_count', checkpoints_timed FROM pg_stat_bgwriter
UNION ALL SELECT 'checkpoints_requested_count', checkpoints_req FROM pg_stat_bgwriter"
fi

out=$(q "$checkpoints
UNION ALL SELECT 'temp_files_count', coalesce(sum(temp_files), 0)::bigint FROM pg_stat_database
UNION ALL SELECT 'temp_bytes', coalesce(sum(temp_bytes), 0)::bigint FROM pg_stat_database
UNION ALL SELECT 'wal_bytes', wal_bytes::bigint FROM pg_stat_wal
") || { echo "io: the server refused the queries: $out" >&2; exit 1; }

while read -r name value; do
    [ -n "$name" ] && echo "metric $name $value"
done <<EOF
$out
EOF
