#!/usr/bin/env bash
#
# size.sh - the size of each PostgreSQL database
#
# Asks the server, as a read-only role (pg_monitor), how much disk each
# database takes. Template databases are left out. Connects as the libpq
# environment says: PGHOST, PGPORT, PGUSER, PGDATABASE and PGPASSWORD, set
# by the job.
#
# Metrics:
#   size_bytes  disk used by the database, in bytes (tag: database)
#
# Example output:
#   metric size_bytes 7631663 database=postgres
#   metric size_bytes 52748591104 database=orders
#
# Reading the results (starting points: tune them to the server):
#   Healthy  growing as the data does.
#   Watch    growing much faster than the data, which can mean bloat that
#            vacuum is not keeping up with.
#   Act      approaching the space left on the disk.
#
# Requires: bash, psql (PostgreSQL's client tools), and a role with pg_monitor
# Exit code: 0 on success; 1 if psql is missing, or the server cannot be
#   reached or refuses the login or the query
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

command -v psql > /dev/null 2>&1 || { echo "size: psql not found: install PostgreSQL's client tools" >&2; exit 1; }

out=$(psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -c "
SELECT datname, pg_database_size(datname) FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname
" 2>&1) || { echo "size: the server could not be reached, or refused the login or the query: $out" >&2; exit 1; }

while read -r name bytes; do
    [ -n "$name" ] || continue
    # A metric tag cannot hold a space, and a database name may.
    echo "metric size_bytes $bytes database=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')"
done <<EOF
$out
EOF
