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
# run-mssql.sh - the mssql pack against a real SQL Server and the secondary
# of its availability group, on this host, with its evidence kept like the
# other runs'.
#
#   scripts/run-mssql.sh [image] [--no-replica]     compose.mssql.yaml
#
# --no-replica: the primary alone, with no availability group (SQL Server
# 2022 CU28's secondary would not join one in Docker on the Fedora test
# machine, where 2019 and 2025 did).
# It makes a TLS certificate from a CA of its own, starts the pair (any SQL
# Server image from 2019; default the one the Compose file pins), makes the
# read-only login on both as packs/README.md says, joins them in a read-scale
# availability group (no cluster) with a database, runs
# tests/integration/service-packs.sh with the secondary given, then stops
# and starts the secondary, showing what the pack's replication and status
# scripts report at each step. The pair is taken down, with its data, at
# the end.
#
# Passwords from .env: MSSQL_SA_PASSWORD and MSSQL_MONITOR_PASSWORD (SQL
# Server wants 8 characters or more, of three kinds). The pack needs sqlcmd
# here, Microsoft's or the Go one; with neither, this runs the one in the
# server's image (docker run), and says so.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

[ -n "${1-}" ] && [ "$1" != --no-replica ] && export MSSQL_IMAGE=$1
replica=yes
case " $* " in *' --no-replica '*) replica=no ;; esac
[ -n "${MSSQL_SA_PASSWORD-}" ] && [ -n "${MSSQL_MONITOR_PASSWORD-}" ] || die 'set MSSQL_SA_PASSWORD and MSSQL_MONITOR_PASSWORD in .env'
file=compose.mssql.yaml
dc() {
    local env=()
    [ -f "$bk_dir/.env" ] && env=(--env-file "$bk_dir/.env")
    docker compose -p vigil-mssql --project-directory "$bk_dir" -f "$bk_dir/$file" ${env[@]+"${env[@]}"} "$@"
}
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-mssql.XXXXXX") || exit 1
root=$work/none
# The availability group's certificate is protected by a password of this
# run's own.
agpw=$(openssl rand -hex 16)Aa1
trap 'dc down -v > /dev/null 2>&1; evidence_save "$MSSQL_SA_PASSWORD" "$MSSQL_MONITOR_PASSWORD" "$agpw"; rm -rf "$work"' EXIT

# Each release's run is kept apart: pack-mssql-2022-replication.
v=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU28-ubuntu-22.04}
v=${v##*:}
name=pack-mssql-${v%%-*}-replication
[ "$replica" = yes ] || name=pack-mssql-${v%%-*}

# The servers' certificate, from a CA of this run's own: the name the pack
# connects by, each host, and 127.0.0.1.
tls=$work/tls
mkdir -p "$tls"
(
    cd "$tls" || exit 1
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 -subj '/CN=Vigil test CA' \
        -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' &&
        openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj '/CN=localhost' &&
        printf 'subjectAltName=DNS:localhost,DNS:mssql-primary,DNS:mssql-secondary,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > server.ext &&
        openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 2 -extfile server.ext
) > "$work/tls.out" 2>&1 || { cat "$work/tls.out"; die 'could not make the TLS certificates'; }
rm -f "$tls/ca.key"
# SQL Server runs as its own account in the container: it reads them.
chmod 755 "$tls"
chmod 644 "$tls"/*
export MSSQL_TLS_DIR=$tls

evidence_start "$name" "$bk_dir/$file" "$0" "$@"
scripts=$bk_repo/packs/mssql/linux
[ "$(uname -s)" = Darwin ] && scripts=$bk_repo/packs/mssql/macos

# The client the pack's scripts will use.
if command -v sqlcmd > /dev/null 2>&1; then
    printf 'client   %s\n' "$(sqlcmd --version 2>&1 | grep -im 1 version)"
else
    # No client here: the server image's own, run for each call. Only the
    # password's name is on the command line; docker passes its value. The
    # TLS files are where the host has them.
    image=$(dc config --images 2> /dev/null | head -n 1)
    mkdir -p "$work/bin"
    printf '#!/bin/sh\nexec docker run --rm -i --network host -e SQLCMDPASSWORD -e SSL_CERT_FILE -v %s:%s:ro,z --entrypoint /opt/mssql-tools18/bin/sqlcmd %s "$@"\n' \
        "$tls" "$tls" "$image" > "$work/bin/sqlcmd"
    chmod +x "$work/bin/sqlcmd"
    export PATH="$work/bin:$PATH"
    printf 'client   sqlcmd from the image %s (none is installed here)\n' "$image"
fi

# SQL $2 as sa inside container $1, on stdin; the password from the
# container's own environment.
as_sa() {
    dc exec -T "$1" sh -c 'SQLCMDPASSWORD=$MSSQL_SA_PASSWORD SSL_CERT_FILE=/tls/ca.crt exec /opt/mssql-tools18/bin/sqlcmd -S tcp:localhost,1433 -U sa -Nm -l 10 -h -1 -W -b -i /dev/stdin' <<< "SET NOCOUNT ON; $2"
}
ready() { as_sa "$1" 'SELECT 1' > /dev/null 2>&1; }
# A setup step failed: what SQL Server said (never a password: it does not
# repeat the statement).
sa_failed() { die "$1: $(tr -s '\r\n' '  ' < "$work/sa.out")"; }
say() { printf '\n# %s\n' "$*"; }
export MSSQL_HOST=localhost MSSQL_USER=vigil_monitor MSSQL_CACERT=$tls/ca.crt SQLCMDPASSWORD=$MSSQL_MONITOR_PASSWORD
job() {
    printf '$ MSSQL_PORT=%s bash packs/mssql/%s.sh\n' "$1" "$2"
    MSSQL_PORT=$1 bash "$scripts/$2.sh"
}
synchronized() { MSSQL_PORT=11433 bash "$scripts/replication.sh" 2> /dev/null | grep -q 'sync_state 2 group=ag1 replica=mssql-secondary database='; }
wait_synchronized() {
    local i
    for i in $(seq 1 60); do synchronized && return 0; sleep 2; done
    return 1
}

servers='mssql-primary mssql-secondary'
[ "$replica" = yes ] || servers=mssql-primary
# shellcheck disable=SC2086
dc up -d $servers > "$work/up.out" 2>&1 || { cat "$work/up.out"; die 'the servers would not start'; }
for s in $servers; do
    for i in $(seq 1 90); do ready "$s" && break; sleep 2; done
    ready "$s" || { dc logs --tail 30 "$s"; die "$s never answered"; }
done

# The login, as packs/README.md says: 2022 and later split VIEW SERVER STATE.
major=$(as_sa mssql-primary "SELECT CONVERT(int, SERVERPROPERTY('ProductMajorVersion'))" | tr -d '\r ')
if [ "${major:-0}" -ge 16 ]; then
    grants='VIEW SERVER PERFORMANCE STATE, VIEW SERVER SECURITY STATE, VIEW ANY DATABASE, CONNECT ANY DATABASE'
else
    grants='VIEW SERVER STATE, VIEW ANY DATABASE, CONNECT ANY DATABASE'
fi
for s in $servers; do
    as_sa "$s" "CREATE LOGIN vigil_monitor WITH PASSWORD = '$MSSQL_MONITOR_PASSWORD'; GRANT $grants TO vigil_monitor;" > "$work/sa.out" 2>&1 ||
        sa_failed "could not make the login on $s"
done

if [ "$replica" = no ]; then
    as_sa mssql-primary "CREATE DATABASE vigil_it; ALTER DATABASE vigil_it SET RECOVERY FULL;" > "$work/sa.out" 2>&1 || sa_failed 'could not make the database'
    printf 'server   %s

' "$(job 11433 status 2> /dev/null | grep '^metric info ' | cut -d ' ' -f 4-)"
    say "The pack through Vigil, with no secondary."
    export VIGIL_IT_MSSQL_HOST=localhost VIGIL_IT_MSSQL_PORT=11433 VIGIL_IT_MSSQL_PASSWORD=$MSSQL_MONITOR_PASSWORD         VIGIL_IT_MSSQL_SA_PASSWORD=$MSSQL_SA_PASSWORD VIGIL_IT_MSSQL_CACERT=$tls/ca.crt VIGIL_IT_MSSQL_DATABASE=vigil_it
    bash "$bk_repo/tests/integration/service-packs.sh"
    exit $?
fi

# The availability group: one certificate for both endpoints, made on the
# primary and copied to the secondary, then the group, then its database,
# seeded to the secondary.
as_sa mssql-primary "CREATE LOGIN dbm_login WITH PASSWORD = '$agpw'; CREATE USER dbm_user FOR LOGIN dbm_login;
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$agpw';
    CREATE CERTIFICATE dbm_certificate WITH SUBJECT = 'dbm';
    BACKUP CERTIFICATE dbm_certificate TO FILE = '/var/opt/mssql/data/dbm_certificate.cer'
        WITH PRIVATE KEY (FILE = '/var/opt/mssql/data/dbm_certificate.pvk', ENCRYPTION BY PASSWORD = '$agpw');" > "$work/sa.out" 2>&1 ||
    sa_failed 'could not make the certificate'
for f in dbm_certificate.cer dbm_certificate.pvk; do
    docker cp "vigil-mssql-mssql-primary-1:/var/opt/mssql/data/$f" "$work/$f" > /dev/null &&
        docker cp "$work/$f" "vigil-mssql-mssql-secondary-1:/var/opt/mssql/data/$f" > /dev/null || die "could not copy $f"
    dc exec -T -u 0 mssql-secondary chown mssql "/var/opt/mssql/data/$f"
    rm -f "$work/$f"
done
as_sa mssql-secondary "CREATE LOGIN dbm_login WITH PASSWORD = '$agpw'; CREATE USER dbm_user FOR LOGIN dbm_login;
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$agpw';
    CREATE CERTIFICATE dbm_certificate AUTHORIZATION dbm_user FROM FILE = '/var/opt/mssql/data/dbm_certificate.cer'
        WITH PRIVATE KEY (FILE = '/var/opt/mssql/data/dbm_certificate.pvk', DECRYPTION BY PASSWORD = '$agpw');" > "$work/sa.out" 2>&1 ||
    sa_failed 'could not load the certificate on the secondary'
for s in mssql-primary mssql-secondary; do
    as_sa "$s" "CREATE ENDPOINT hadr_endpoint AS TCP (LISTENER_PORT = 5022)
        FOR DATABASE_MIRRORING (ROLE = ALL, AUTHENTICATION = CERTIFICATE dbm_certificate, ENCRYPTION = REQUIRED ALGORITHM AES);
    ALTER ENDPOINT hadr_endpoint STATE = STARTED;
    GRANT CONNECT ON ENDPOINT::hadr_endpoint TO dbm_login;" > "$work/sa.out" 2>&1 || sa_failed "could not make the endpoint on $s"
done
replica() {
    printf "N'%s' WITH (ENDPOINT_URL = N'tcp://%s:5022', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL))" "$1" "$1"
}
as_sa mssql-primary "CREATE AVAILABILITY GROUP ag1 WITH (CLUSTER_TYPE = NONE) FOR REPLICA ON $(replica mssql-primary), $(replica mssql-secondary);
    ALTER AVAILABILITY GROUP ag1 GRANT CREATE ANY DATABASE;
    -- Its name, for the pack: without it, the group is tagged by its id.
    GRANT VIEW DEFINITION ON AVAILABILITY GROUP::ag1 TO vigil_monitor;" > "$work/sa.out" 2>&1 || sa_failed 'could not make the availability group'
as_sa mssql-secondary "ALTER AVAILABILITY GROUP ag1 JOIN WITH (CLUSTER_TYPE = NONE); ALTER AVAILABILITY GROUP ag1 GRANT CREATE ANY DATABASE;
    GRANT VIEW DEFINITION ON AVAILABILITY GROUP::ag1 TO vigil_monitor;" > "$work/sa.out" 2>&1 ||
    sa_failed 'the secondary could not join'
as_sa mssql-primary "CREATE DATABASE vigil_it; ALTER DATABASE vigil_it SET RECOVERY FULL;
    BACKUP DATABASE vigil_it TO DISK = N'/var/opt/mssql/data/vigil_it_seed.bak' WITH INIT;
    ALTER AVAILABILITY GROUP ag1 ADD DATABASE vigil_it;" > "$work/sa.out" 2>&1 || sa_failed 'could not add the database'
wait_synchronized || { dc logs --tail 30 mssql-secondary; die 'the secondary never synchronized'; }
printf 'server   %s\n\n' "$(job 11433 status 2> /dev/null | grep '^metric info ' | cut -d ' ' -f 4-)"

say "The pack through Vigil, the secondary given."
export VIGIL_IT_MSSQL_HOST=localhost VIGIL_IT_MSSQL_PORT=11433 VIGIL_IT_MSSQL_PASSWORD=$MSSQL_MONITOR_PASSWORD \
    VIGIL_IT_MSSQL_SA_PASSWORD=$MSSQL_SA_PASSWORD VIGIL_IT_MSSQL_CACERT=$tls/ca.crt VIGIL_IT_MSSQL_DATABASE=vigil_it \
    VIGIL_IT_MSSQL_REPLICA_HOST=localhost VIGIL_IT_MSSQL_REPLICA_PORT=11434
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?

say "Both sides, synchronized."
job 11433 replication
job 11434 replication

say "The secondary stops."
dc stop mssql-secondary > /dev/null 2>&1
# The primary notices once its session with the secondary times out (10
# seconds by default).
sleep 20
job 11433 replication
job 11434 status
printf '(the secondary'"'"'s other jobs print nothing while it does not answer; status reports it)\n'

say "The secondary starts again, and catches up."
dc start mssql-secondary > /dev/null 2>&1
for i in $(seq 1 90); do ready mssql-secondary && break; sleep 2; done
wait_synchronized || printf 'the secondary did not synchronize again within 2 minutes\n'
job 11433 replication
job 11434 replication

exit "$rc"
