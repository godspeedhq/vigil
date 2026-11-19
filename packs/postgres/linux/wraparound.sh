#!/usr/bin/env bash
#
# wraparound.sh - how far each database of a PostgreSQL server is from
# transaction ID wraparound
#
# PostgreSQL numbers transactions with 32-bit IDs, and must freeze old rows
# (vacuum does) before about 2 billion more transactions have passed, or it
# stops accepting writes to protect the data. This reports, for each
# database, the age of its oldest unfrozen transaction ID and multixact ID,
# as a count and as a percent of that limit, and the oldest transaction
# anything on the server still needs, which vacuum cannot freeze past.
# Connects as the libpq environment says: PGHOST, PGPORT, PGUSER, PGDATABASE
# and PGPASSWORD, set by the job.
#
# Metrics:
#   xid_age_count          transactions since the oldest unfrozen row,
#                          tagged database=<name>
#   xid_pct                that age, as a percent of the 2^31 limit
#   mxid_age_count         the same for multixact IDs (row locks shared by
#                          several transactions), tagged database=<name>
#   mxid_pct               that age, as a percent of the 2^31 limit
#   oldest_xmin_age_count  age of the oldest transaction a session, a
#                          replication slot or a prepared transaction still
#                          needs
#
# Example output (one line per database for the tagged ones):
#   metric xid_age_count 2381 database=postgres
#   metric xid_pct 0 database=postgres
#   metric mxid_age_count 0 database=postgres
#   metric mxid_pct 0 database=postgres
#   metric oldest_xmin_age_count 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  xid_pct below 10: autovacuum keeps freezing as it should (it
#            starts on a database at autovacuum_freeze_max_age, 200 million by
#            default, or 9 percent).
#   Watch    xid_pct above 20 and climbing: autovacuum is not keeping up, or
#            something holds it back; check oldest_xmin_age_count.
#   Act      xid_pct above 50: plan a VACUUM (FREEZE) of the oldest tables now.
#            Near 100, PostgreSQL refuses writes until it is done.
#            oldest_xmin_age_count in the hundreds of millions: an old session,
#            an abandoned replication slot or a forgotten prepared transaction
#            stops vacuum freezing anything newer; end or drop it.
#
# When the server does not answer, it prints nothing and succeeds:
# postgres_status reports that, as postgres.up 0.
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
    command -v "$tool" > /dev/null 2>&1 || { echo "wraparound: $tool not found: install PostgreSQL's client tools" >&2; exit 1; }
done
pg_isready -q -t 5 || exit 0

# One "name value [tag]" row per metric, from pg_database, which lists every
# database whatever this role may connect to. A database name in a tag keeps
# letters, digits, _, . and - only.
out=$(psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -c "
WITH d AS (
    SELECT 'database=' || regexp_replace(datname, '[^A-Za-z0-9_.-]', '_', 'g') AS tag,
           age(datfrozenxid)::bigint AS xid, mxid_age(datminmxid)::bigint AS mxid
    FROM pg_database
)
SELECT 'xid_age_count', xid, tag FROM d
UNION ALL SELECT 'xid_pct', floor(100 * xid / 2147483648.0)::bigint, tag FROM d
UNION ALL SELECT 'mxid_age_count', mxid, tag FROM d
UNION ALL SELECT 'mxid_pct', floor(100 * mxid / 2147483648.0)::bigint, tag FROM d
UNION ALL SELECT 'oldest_xmin_age_count', coalesce(max(a), 0)::bigint, '' FROM (
    SELECT age(backend_xmin) AS a FROM pg_stat_activity WHERE backend_xmin IS NOT NULL AND pid <> pg_backend_pid()
    UNION ALL SELECT age(xmin) FROM pg_replication_slots WHERE xmin IS NOT NULL
    UNION ALL SELECT age(catalog_xmin) FROM pg_replication_slots WHERE catalog_xmin IS NOT NULL
    UNION ALL SELECT age(transaction) FROM pg_prepared_xacts
) x
" 2>&1) || { echo "wraparound: the server refused the login or the queries: $out" >&2; exit 1; }

while read -r name value tag; do
    [ -n "$name" ] || continue
    if [ -n "$tag" ]; then echo "metric $name $value $tag"; else echo "metric $name $value"; fi
done <<EOF
$out
EOF
