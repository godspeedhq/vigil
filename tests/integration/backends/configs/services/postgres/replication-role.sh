#!/bin/sh
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
# Run by the primary of compose.replication.yaml at its first start, after
# monitor-role.sh: a role the replica copies and streams as, and a line in
# pg_hba.conf that lets it connect for replication.

set -eu
: "${POSTGRES_REPLICATION_PASSWORD:?set POSTGRES_REPLICATION_PASSWORD in .env}"
psql -v ON_ERROR_STOP=1 -U postgres -d postgres -v pw="$POSTGRES_REPLICATION_PASSWORD" <<'SQL'
CREATE ROLE replicator LOGIN REPLICATION PASSWORD :'pw';
SQL
echo 'host replication replicator all scram-sha-256' >> "$PGDATA/pg_hba.conf"
