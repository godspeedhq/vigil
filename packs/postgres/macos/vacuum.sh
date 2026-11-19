#!/usr/bin/env bash
#
# vacuum.sh - whether autovacuum keeps up on a PostgreSQL server
#
# For each database this role may connect to: the dead rows waiting for
# vacuum, and the tables past the point where autovacuum should vacuum them.
# For the server: the autovacuum workers running now, and how many may run.
# Table statistics belong to each database, so it connects to each in turn.
# Connects as the libpq environment says: PGHOST, PGPORT, PGUSER and
# PGPASSWORD, set by the job; PGDATABASE is the first database it asks.
#
# Metrics:
#   dead_tuples_count       dead rows waiting for vacuum, tagged
#                           database=<name>
#   tables_due_count        tables with more dead rows than the server-wide
#                           autovacuum threshold allows, tagged database=<name>
#                           (a table's own autovacuum settings are not read)
#   autovacuum_workers      autovacuum workers running now
#   autovacuum_max_workers  how many may run at once
#
# Example output (one line per database for the tagged ones):
#   metric autovacuum_workers 0
#   metric autovacuum_max_workers 3
#   metric dead_tuples_count 1204 database=app
#   metric tables_due_count 0 database=app
#
# Reading the results (starting points: tune them to the server):
#   Healthy  tables_due_count 0, or briefly above it while workers catch up.
#   Watch    tables_due_count staying above 0, and autovacuum_workers often
#            at autovacuum_max_workers: autovacuum is busy all the time, and
#            tables wait their turn.
#   Act      dead_tuples_count growing run after run with tables due: tables
#            and indexes bloat, and queries slow down. Look for a long open
#            transaction holding vacuum back (postgres_activity,
#            postgres_wraparound), or give autovacuum more workers or less
#            cost delay.
#
# A database it may not connect to is left out, with a line on stderr. When
# the server does not answer, it prints nothing and succeeds: postgres_status
# reports that, as postgres.up 0.
#
# Requires: bash, psql and pg_isready (PostgreSQL's client tools), PostgreSQL
#   14 or later, and a role with pg_monitor
# Exit code: 0 on success, or when the server does not answer; 1 if psql or
#   pg_isready is missing or the server refuses the login or the queries
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
    command -v "$tool" > /dev/null 2>&1 || { echo "vacuum: $tool not found: install PostgreSQL's client tools" >&2; exit 1; }
done
pg_isready -q -t 5 || exit 0

q() { psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -c "$1" 2>&1; }

out=$(q "
SELECT 'autovacuum_workers', count(*) FROM pg_stat_activity WHERE backend_type = 'autovacuum worker'
UNION ALL SELECT 'autovacuum_max_workers', setting::bigint FROM pg_settings WHERE name = 'autovacuum_max_workers'
") || { echo "vacuum: the server refused the login or the queries: $out" >&2; exit 1; }
while read -r name value; do
    [ -n "$name" ] && echo "metric $name $value"
done <<EOF
$out
EOF

dbs=$(q "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate
    AND has_database_privilege(datname, 'CONNECT') ORDER BY datname") ||
    { echo "vacuum: the server refused the queries: $dbs" >&2; exit 1; }

# A table is due when its dead rows pass threshold + scale factor x its rows,
# as autovacuum reckons it. reltuples is -1 for a table never analysed.
while IFS= read -r db; do
    [ -n "$db" ] || continue
    out=$(PGDATABASE=$db q "
SELECT 'dead_tuples_count', coalesce(sum(n_dead_tup), 0)::bigint FROM pg_stat_user_tables
UNION ALL SELECT 'tables_due_count', count(*) FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
    WHERE s.n_dead_tup > current_setting('autovacuum_vacuum_threshold')::bigint
        + current_setting('autovacuum_vacuum_scale_factor')::float8 * greatest(c.reltuples, 0)
") || { echo "vacuum: database $db left out: $out" >&2; continue; }
    tag=$(printf '%s' "$db" | tr -c 'A-Za-z0-9_.-' '_')
    while read -r name value; do
        [ -n "$name" ] && echo "metric $name $value database=$tag"
    done <<EOF
$out
EOF
done <<EOF
$dbs
EOF
