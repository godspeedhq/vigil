#!/usr/bin/env bash
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
# run-replication.sh - a pack's replication job against a real source and
# replica, on this host, with its evidence kept like the other runs'. CI has
# no replicas; this is where replication is tested.
#
#   scripts/run-replication.sh postgres [image]   compose.replication.yaml
#   scripts/run-replication.sh mysql              compose.mysql.yaml
#   scripts/run-replication.sh mariadb            compose.mysql.yaml
#   scripts/run-replication.sh redis [image]      compose.redis.yaml
#
# It starts the pair (postgres: any image from 14 on, default the one the
# Compose file pins; redis: any Redis from 6.2 or Valkey, default Valkey
# 9.2, with a TLS server beside it), waits for the replica to stream, runs
# tests/integration/service-packs.sh with the replica given, then stops and
# starts the replica, and (MySQL, MariaDB) its applying thread, showing what
# the pack's replication and status scripts report at each step. The pair is
# taken down, with its data, at the end.
#
# Passwords from .env: POSTGRES_PASSWORD, POSTGRES_MONITOR_PASSWORD and
# POSTGRES_REPLICATION_PASSWORD, or MYSQL_ROOT_PASSWORD,
# MYSQL_MONITOR_PASSWORD and MYSQL_REPLICATION_PASSWORD, or
# REDIS_MONITOR_PASSWORD, REDIS_ADMIN_PASSWORD and
# REDIS_REPLICATION_PASSWORD. The postgres pack needs psql and pg_isready
# here; the mysql pack a mysql or mariadb client, and the redis pack
# redis-cli or valkey-cli: with neither, this runs the one in the server's
# image (docker run), and says so.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

target=${1-}
case $target in
    postgres)
        file=compose.replication.yaml profile='' pack=postgres
        src=pg-primary rep=pg-replica sport=15433 rport=15434
        [ -n "${2-}" ] && export PG_IMAGE=$2
        secrets=("${POSTGRES_PASSWORD-}" "${POSTGRES_MONITOR_PASSWORD-}" "${POSTGRES_REPLICATION_PASSWORD-}")
        ;;
    mysql | mariadb)
        file=compose.mysql.yaml profile=$target pack=mysql
        src=$target-source rep=$target-replica
        if [ "$target" = mysql ]; then sport=13306 rport=13307; else sport=13316 rport=13317; fi
        secrets=("${MYSQL_ROOT_PASSWORD-}" "${MYSQL_MONITOR_PASSWORD-}" "${MYSQL_REPLICATION_PASSWORD-}")
        ;;
    redis)
        file=compose.redis.yaml profile='' pack=redis
        src=redis-primary rep=redis-replica sport=16379 rport=16380
        [ -n "${2-}" ] && export REDIS_IMAGE=$2
        secrets=("${REDIS_MONITOR_PASSWORD-}" "${REDIS_ADMIN_PASSWORD-}" "${REDIS_REPLICATION_PASSWORD-}")
        ;;
    *) die 'usage: run-replication.sh postgres [image] | mysql | mariadb | redis [image]' ;;
esac

dc() {
    local env=() prof=()
    [ -f "$bk_dir/.env" ] && env=(--env-file "$bk_dir/.env")
    [ -n "$profile" ] && prof=(--profile "$profile")
    docker compose -p "vigil-$target-replication" --project-directory "$bk_dir" -f "$bk_dir/$file" \
        ${env[@]+"${env[@]}"} ${prof[@]+"${prof[@]}"} "$@"
}
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-repl.XXXXXX") || exit 1
root=$work/none
trap 'dc down -v > /dev/null 2>&1; evidence_save "${secrets[@]}"; rm -rf "$work"' EXIT

# Each PostgreSQL version's run is kept apart: pack-postgres-14-replication.
name=pack-$target-replication
if [ "$pack" = postgres ]; then
    v=${PG_IMAGE:-postgres:18.1-alpine}
    v=${v##*:}
    name=pack-postgres-${v%%[.-]*}-replication
fi
# And each Redis or Valkey: pack-valkey-9-replication.
if [ "$pack" = redis ]; then
    v=${REDIS_IMAGE:-valkey/valkey:9.2.0-alpine}
    s=redis
    case $v in *valkey*) s=valkey ;; esac
    v=${v##*:}
    name=pack-$s-${v%%[.-]*}-replication
    # The TLS server's certificate, from a CA of this run's own, naming
    # 127.0.0.1 only.
    tls=$work/tls
    mkdir -p "$tls"
    (
        cd "$tls" || exit 1
        openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 -subj '/CN=Vigil test CA' \
            -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' &&
            openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj '/CN=127.0.0.1' &&
            printf 'subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > server.ext &&
            openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 2 -extfile server.ext
    ) > "$work/tls.out" 2>&1 || { cat "$work/tls.out"; die 'could not make the TLS certificates'; }
    rm -f "$tls/ca.key"
    chmod 755 "$tls"
    chmod 644 "$tls"/*
    export REDIS_TLS_DIR=$tls
fi
evidence_start "$name" "$bk_dir/$file" "$0" "$@"
scripts=$bk_repo/packs/$pack/linux
[ "$(uname -s)" = Darwin ] && scripts=$bk_repo/packs/$pack/macos

# The client the pack's scripts will use.
if [ "$pack" = postgres ]; then
    command -v psql > /dev/null 2>&1 || die 'the postgres pack needs psql and pg_isready here'
    printf 'client   %s\n' "$(psql --version)"
    export PGHOST=127.0.0.1 PGUSER=vigil_monitor PGDATABASE=postgres PGPASSWORD=${POSTGRES_MONITOR_PASSWORD-}
    port_var=PGPORT
    export VIGIL_IT_PG_HOST=127.0.0.1 VIGIL_IT_PG_PORT=$sport VIGIL_IT_PG_PASSWORD=${POSTGRES_MONITOR_PASSWORD-} \
        VIGIL_IT_PG_SUPER_PASSWORD=${POSTGRES_PASSWORD-} VIGIL_IT_PG_REPLICA_HOST=127.0.0.1 VIGIL_IT_PG_REPLICA_PORT=$rport
elif [ "$pack" = redis ]; then
    if command -v redis-cli > /dev/null 2>&1 || command -v valkey-cli > /dev/null 2>&1; then
        printf 'client   %s\n' "$( (command -v redis-cli > /dev/null && redis-cli --version) || valkey-cli --version)"
    else
        # No client here: the server image's own, run for each call, by the
        # name that image gives it. Only the password's name is on the
        # command line; docker passes its value. The TLS files are where the
        # host has them.
        image=$(dc config --images 2> /dev/null | grep -m 1 -E 'redis|valkey')
        bin=redis-cli
        case $image in *valkey*) bin=valkey-cli ;; esac
        mkdir -p "$work/bin"
        printf '#!/bin/sh\nexec docker run --rm -i --network host -e REDISCLI_AUTH -v %s:%s:ro,z %s %s "$@"\n' "$tls" "$tls" "$image" "$bin" > "$work/bin/$bin"
        chmod +x "$work/bin/$bin"
        export PATH="$work/bin:$PATH"
        printf 'client   %s, from the image %s (none is installed here)\n' "$("$bin" --version)" "$image"
    fi
    export REDIS_HOST=127.0.0.1 REDIS_USER=vigil_monitor REDISCLI_AUTH=${REDIS_MONITOR_PASSWORD-}
    port_var=REDIS_PORT
    export VIGIL_IT_REDIS_HOST=127.0.0.1 VIGIL_IT_REDIS_PORT=$sport VIGIL_IT_REDIS_PASSWORD=${REDIS_MONITOR_PASSWORD-} \
        VIGIL_IT_REDIS_ADMIN_PASSWORD=${REDIS_ADMIN_PASSWORD-} VIGIL_IT_REDIS_REPLICA_HOST=127.0.0.1 VIGIL_IT_REDIS_REPLICA_PORT=$rport \
        VIGIL_IT_REDIS_TLS_HOST=127.0.0.1 VIGIL_IT_REDIS_TLS_PORT=16381 VIGIL_IT_REDIS_CACERT=$tls/ca.crt
else
    if command -v mysql > /dev/null 2>&1 || command -v mariadb > /dev/null 2>&1; then
        printf 'client   %s\n' "$( (command -v mysql > /dev/null && mysql --version) || mariadb --version)"
    else
        # No client here: the server image's own, run for each call. Only the
        # password's name is on the command line; docker passes its value.
        image=$(dc config --images 2> /dev/null | grep -m 1 "^$target:")
        bin=mysql
        [ "$target" = mariadb ] && bin=mariadb
        mkdir -p "$work/bin"
        printf '#!/bin/sh\nexec docker run --rm -i --network host -e MYSQL_PWD %s %s "$@"\n' "$image" "$bin" > "$work/bin/mysql"
        chmod +x "$work/bin/mysql"
        export PATH="$work/bin:$PATH"
        printf 'client   %s, from the image %s (none is installed here)\n' "$(mysql --version)" "$image"
    fi
    export MYSQL_HOST=127.0.0.1 MYSQL_USER=vigil_monitor MYSQL_PWD=${MYSQL_MONITOR_PASSWORD-}
    port_var=MYSQL_TCP_PORT
    export VIGIL_IT_MYSQL_HOST=127.0.0.1 VIGIL_IT_MYSQL_PORT=$sport VIGIL_IT_MYSQL_PASSWORD=${MYSQL_MONITOR_PASSWORD-} \
        VIGIL_IT_MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD-} VIGIL_IT_MYSQL_REPLICA_HOST=127.0.0.1 VIGIL_IT_MYSQL_REPLICA_PORT=$rport
fi

# Job $2's script against port $1, as the command a reader could type.
job() {
    printf '$ %s=%s bash packs/%s/%s.sh\n' "$port_var" "$1" "$pack" "$2"
    env "$port_var=$1" bash "$scripts/$2.sh"
}
# Whether the replica streams: its own replication job says so.
streaming() { env "$port_var=$rport" bash "$scripts/replication.sh" 2> /dev/null | grep -qE 'receiver_up 1|sql_running 1|link_up 1'; }
wait_streaming() {
    local i
    for i in $(seq 1 60); do streaming && return 0; sleep 2; done
    return 1
}
# Runs SQL $2 as the server's root inside container $1.
as_root() {
    if [ "$target" = mariadb ]; then
        dc exec -T "$1" sh -c 'MYSQL_PWD=$MARIADB_ROOT_PASSWORD mariadb -uroot -N' <<< "$2" 2> /dev/null
    else
        dc exec -T "$1" sh -c 'MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot -N' <<< "$2" 2> /dev/null
    fi
}
say() { printf '\n# %s\n' "$*"; }

dc up -d > "$work/up.out" 2>&1 || { cat "$work/up.out"; die "the pair would not start"; }
wait_streaming || { dc logs --tail 30; die 'the replica never streamed'; }
if [ "$pack" = postgres ]; then
    printf 'server   PostgreSQL %s\n\n' "$(PGPORT=$sport psql -X -Atc 'SHOW server_version')"
elif [ "$pack" = redis ]; then
    printf 'server   %s\n\n' "$(REDIS_PORT=$sport bash "$scripts/status.sh" | grep '^metric info ' | cut -d ' ' -f 4-)"
else
    # The port on the command line: a client run from an image gets only
    # the password's variable.
    printf 'server   %s\n\n' "$(mysql --protocol=TCP -h 127.0.0.1 -P "$sport" -u vigil_monitor -N -B -e 'SELECT VERSION()' 2> /dev/null)"
fi

say "The pack through Vigil, the replica given."
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?

say "Both sides, streaming."
job "$sport" replication
job "$rport" replication

if [ "$pack" = mysql ]; then
    say "The replica's applying thread stops."
    if [ "$target" = mariadb ]; then as_root "$rep" 'STOP SLAVE SQL_THREAD;'; else as_root "$rep" 'STOP REPLICA SQL_THREAD;'; fi
    sleep 2
    job "$rport" replication
    if [ "$target" = mariadb ]; then as_root "$rep" 'START SLAVE SQL_THREAD;'; else as_root "$rep" 'START REPLICA SQL_THREAD;'; fi
fi

say "The replica stops."
dc stop "$rep" > /dev/null 2>&1
sleep 3
job "$sport" replication
job "$rport" status
printf '(the replica'"'"'s other jobs print nothing while it does not answer; status reports it)\n'

say "The replica starts again, and catches up."
dc start "$rep" > /dev/null 2>&1
wait_streaming || printf 'the replica did not stream again within 2 minutes\n'
job "$sport" replication
job "$rport" replication

exit "$rc"
