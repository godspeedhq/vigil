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
# The replica of compose.replication.yaml: on its first start, a copy of the
# primary (pg_basebackup), set up to stream from it (-R) through a
# replication slot of its own (-C -S replica1); then the image's own
# entrypoint, which finds the data there and starts the server as a
# standby.

set -eu
: "${POSTGRES_REPLICATION_PASSWORD:?set POSTGRES_REPLICATION_PASSWORD in .env}"
# The images switch user with gosu, or with su-exec before.
as=gosu
command -v gosu > /dev/null 2>&1 || as=su-exec
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    mkdir -p "$PGDATA"
    chown postgres:postgres "$PGDATA"
    chmod 700 "$PGDATA"
    until PGPASSWORD=$POSTGRES_REPLICATION_PASSWORD "$as" postgres \
        pg_basebackup -h pg-primary -U replicator -D "$PGDATA" -R -X stream -C -S replica1 \
        -d 'application_name=replica1'; do
        echo 'waiting for the primary' >&2
        rm -rf "${PGDATA:?}"/*
        sleep 2
    done
fi
exec docker-entrypoint.sh "$@"
