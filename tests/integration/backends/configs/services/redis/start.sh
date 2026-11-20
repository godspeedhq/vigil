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
# The entrypoint of each server of compose.redis.yaml, Redis or Valkey: it
# writes the server's users and settings to files, then starts the image's
# own entrypoint, which runs the server as its own user. The passwords stay
# in those files, never on a command line. ROLE says which server:
#
#   primary  snapshots and the append-only file on, maxmemory 32 MB with
#            allkeys-lru, so a test can make it evict; the default user off
#   replica  a replica of PRIMARY_HOST, logging in as repl; default user off
#   tls      TLS only, with the certificate in /tls; the default user on
#            with no password, as an unsecured server has it
#
# Every server has the pack's user, vigil_monitor, with what README says to
# grant; vigil_noinfo, which may not run INFO, for the refused case; and
# admin, which the tests use to make work.

set -eu
: "${MONITOR_PASSWORD:?set REDIS_MONITOR_PASSWORD in .env}"
: "${ADMIN_PASSWORD:?set REDIS_ADMIN_PASSWORD in .env}"
: "${REPLICATION_PASSWORD:?set REDIS_REPLICATION_PASSWORD in .env}"
server=redis-server
command -v valkey-server > /dev/null 2>&1 && server=valkey-server
dir=/tmp/vigil-it
mkdir -p "$dir"

if [ "${ROLE:-}" = tls ]; then
    echo 'user default on nopass ~* &* +@all' > "$dir/users.acl"
else
    echo 'user default off' > "$dir/users.acl"
fi
cat >> "$dir/users.acl" <<EOF
user vigil_monitor on >$MONITOR_PASSWORD -@all +info +ping
user vigil_noinfo on >$MONITOR_PASSWORD -@all +ping
user repl on >$REPLICATION_PASSWORD +psync +replconf +ping
user admin on >$ADMIN_PASSWORD ~* &* +@all
EOF

{
    echo "aclfile $dir/users.acl"
    echo 'protected-mode no'
    echo 'dir /data'
    case ${ROLE:-} in
        primary)
            echo 'save 3600 1 300 100 60 10000'
            echo 'appendonly yes'
            echo 'maxmemory 32mb'
            echo 'maxmemory-policy allkeys-lru'
            ;;
        replica)
            echo "replicaof ${PRIMARY_HOST:?} 6379"
            echo 'masteruser repl'
            echo "masterauth $REPLICATION_PASSWORD"
            ;;
        tls)
            echo 'port 0'
            echo 'tls-port 6379'
            echo 'tls-cert-file /tls/server.crt'
            echo 'tls-key-file /tls/server.key'
            echo 'tls-ca-cert-file /tls/ca.crt'
            echo 'tls-auth-clients optional'
            ;;
        *) echo "ROLE is '${ROLE:-}': primary, replica or tls" >&2; exit 1 ;;
    esac
} > "$dir/server.conf"
# The server runs as its own user, which must read them.
chmod 755 "$dir"
chmod 644 "$dir/users.acl" "$dir/server.conf"
exec docker-entrypoint.sh "$server" "$dir/server.conf"
