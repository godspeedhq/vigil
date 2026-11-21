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
# Integration test: the service packs (packs/postgres, packs/mysql,
# packs/redis, packs/mssql, packs/kafka, packs/nginx) against real servers, on Linux and
# macOS. The
# twin of Service-Packs.ps1, which tests them on Windows (nginx has no
# Windows script).
#
# A pack is tested only when its server is given, and SKIPped otherwise:
#   VIGIL_IT_PG_HOST, VIGIL_IT_PG_PORT   a PostgreSQL server (default port 5432)
#   VIGIL_IT_PG_PASSWORD                 its vigil_monitor role's password; the
#                                        role has pg_monitor and nothing more
#   VIGIL_IT_PG_SUPER_PASSWORD           optional: its postgres superuser's, to
#                                        make dead rows and an unused slot
#   VIGIL_IT_PG_REPLICA_HOST, _PORT      optional: a streaming replica of it
#                                        (compose.replication.yaml)
#   VIGIL_IT_MYSQL_HOST, _PORT           a MySQL or MariaDB server (default
#                                        port 3306)
#   VIGIL_IT_MYSQL_PASSWORD              its vigil_monitor user's password;
#                                        the user has PROCESS and REPLICATION
#                                        CLIENT (and on MariaDB REPLICA
#                                        MONITOR), and nothing more
#   VIGIL_IT_MYSQL_ROOT_PASSWORD         optional: its root's, to hold a row
#                                        lock and make a deadlock
#   VIGIL_IT_MYSQL_REPLICA_HOST, _PORT   optional: a replica of it
#                                        (compose.mysql.yaml)
#   VIGIL_IT_REDIS_HOST, _PORT           a Redis or Valkey server (default
#                                        port 6379)
#   VIGIL_IT_REDIS_PASSWORD              its vigil_monitor user's password; the
#                                        user may run INFO and PING, and
#                                        nothing more
#   VIGIL_IT_REDIS_ADMIN_PASSWORD        optional: its admin user's, to make
#                                        keys, lookups, a blocked client,
#                                        evictions and a snapshot
#   VIGIL_IT_REDIS_REPLICA_HOST, _PORT   optional: a replica of it
#   VIGIL_IT_REDIS_TLS_HOST, _PORT       optional: a server that speaks TLS
#                                        only, its default user open, with
#   VIGIL_IT_REDIS_CACERT                the CA its certificate is from
#                                        (compose.redis.yaml has all three)
#   VIGIL_IT_MSSQL_HOST, _PORT           a SQL Server (default port 1433), by
#                                        the name on its certificate
#   VIGIL_IT_MSSQL_PASSWORD              its vigil_monitor login's password; the
#                                        login has what packs/README.md says
#                                        to grant, and nothing more
#   VIGIL_IT_MSSQL_CACERT                the CA its certificate is from, when
#                                        the system does not trust it
#   VIGIL_IT_MSSQL_SA_PASSWORD           optional: sa's, to make a database,
#                                        backups, an integrity check, blocking
#                                        and a failing Agent job
#   VIGIL_IT_MSSQL_REPLICA_HOST, _PORT   optional: the secondary of its
#                                        availability group (compose.mssql.yaml
#                                        has both, scripts/run-mssql.sh sets
#                                        them up)
#   VIGIL_IT_KAFKA_BOOTSTRAP             a Kafka cluster's SASL_SSL listener
#                                        (host:port, comma-separated), SCRAM
#   VIGIL_IT_KAFKA_PASSWORD              its vigil_monitor user's password; the
#                                        user has the ACLs packs/README.md lists,
#                                        and nothing more
#   VIGIL_IT_KAFKA_CACERT                the CA its certificates are from
#   VIGIL_IT_KAFKA_HOME                  Kafka's command-line tools (3.9 on)
#   VIGIL_IT_KAFKA_JMX                   optional: its brokers' JMX, host:port
#                                        each, comma-separated
#   VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP       optional: a PLAINTEXT listener that may
#                                        do anything, to make topics, messages
#                                        and a consumer group with lag
#                                        (compose.kafka.yaml has all of these;
#                                        scripts/run-kafka.sh sets them up)
#   VIGIL_IT_NGINX_URL                   an nginx stub_status page
# CI starts them as service containers; tests/integration/backends has
# them for a machine of your own (scripts/run-pack.sh, compose.*.yaml).
#
# For each pack: it is off until enabled; vigil pack enable puts its jobs in
# the configuration; each job runs and reports what the server says; a
# server that is down reads as up 0; and its metrics reach a backend. For
# postgres also: a long query and transaction are seen, a session idle in
# its transaction and one blocked behind its lock, a sort spilled to disk,
# dead rows and an unused replication slot, a replica from both sides; the
# other jobs say nothing while the server is down; a wrong password fails
# the run and says why, and the password is written nowhere. For mysql
# also: a row lock held by a transaction idle on its connection, with
# another waiting for it, and a deadlock; a replica from both sides; a wrong
# password and a server that is down. For redis also: keys in two
# databases, lookups that hit and miss, a blocked client, evictions at
# maxmemory and a snapshot; a replica from both sides; TLS against a CA, and
# refused when the certificate cannot be trusted or when asked without TLS;
# a server with no password; a wrong password, even where the server's
# default user would answer; a user that may not run INFO; and a server
# that is down. For mssql also: a session asleep with its transaction open
# and another blocked behind it, backups and an integrity check just done,
# Agent's jobs unreadable without their grants and then a failed one seen; an
# availability group from both sides; a certificate it cannot trust and a
# wrong password, which fail the run; and a server that is down. For kafka
# also: through an admin listener, a topic with messages, a group behind on
# it and a topic with one replica; the brokers' JMX; a certificate it cannot
# trust, which fails the run but is still read and reported untrusted; a
# wrong password; a cluster that is down; and no client configuration, with
# its password, left behind.
#
# Exit code: 0 all passed or skipped, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-svcpack.XXXXXX")
work=$(cd "$work" && pwd)
root=$work/root
pass=0
fail=0
hold=''
hold2=''

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
    fi
}
cleanup() {
    # The test's own clients, holding a transaction open, or waiting.
    [ -n "$hold" ] && kill "$hold" 2> /dev/null
    [ -n "$hold2" ] && kill "$hold2" 2> /dev/null
    rm -rf "$work"
}
trap cleanup EXIT

vigil() { bash "$root/app/vigil" --root "$root" "$@"; }
# The value job $1's last run printed for metric $2 (tags $3, if any).
printed() {
    grep -h " out metric $2 " "$root/logs/jobs/$1"/*.log 2> /dev/null | grep -- "${3-}" | tail -n 1 | awk '{ print $6 }'
}
# Sets env NAME=value in every line of the configuration that sets NAME.
set_env() { sed -i.bak "s#^env\( *\)= $1=.*#env\1= $1=$2#" "$root/config/vigil.config" && rm -f "$root/config/vigil.config.bak"; }

printf 'bash %s on %s\n' "$BASH_VERSION" "$(uname -s)"
case $(uname -s) in Darwin) os=macos ;; *) os=linux ;; esac
mkdir -p "$root"
cp -R "$repo/app" "$repo/vendor" "$root/"
vigil init --instance svcpack --backend file --no-pack > "$work/out" 2>&1
check 'init' 0 "$?"
for p in postgres mysql redis mssql kafka jvm nginx; do
    mkdir -p "$root/packs/$p"
    cp "$repo/packs/$p/pack.config" "$repo/packs/$p/$os"/* "$root/packs/$p/"
done
check 'the packs are off until enabled' 'off off off' "$(vigil pack list | awk '$1 == "postgres_status" || $1 == "postgres_size" || $1 == "nginx_status" { print $2 }' | tr '\n' ' ' | sed 's/ $//')"

# --- postgres ---------------------------------------------------------------
if [ -z "${VIGIL_IT_PG_HOST-}" ] || [ -z "${VIGIL_IT_PG_PASSWORD-}" ]; then
    printf '  SKIP  postgres: set VIGIL_IT_PG_HOST and VIGIL_IT_PG_PASSWORD\n'
elif ! command -v psql > /dev/null 2>&1; then
    printf '  SKIP  postgres: psql is not installed here\n'
else
    printf 'postgres at %s:%s\n' "$VIGIL_IT_PG_HOST" "${VIGIL_IT_PG_PORT:-5432}"
    printf '%s' "$VIGIL_IT_PG_PASSWORD" | vigil secret set POSTGRES_MONITOR_PASSWORD --stdin > /dev/null
    out=$(vigil pack enable postgres 2>&1)
    check 'postgres: enabled' 0 "$?"
    printf '%s\n' "$out" | sed 's/^/        /'
    check 'postgres: its jobs are on' 'on on' "$(vigil pack list | awk '$1 == "postgres_status" || $1 == "postgres_size" { print $2 }' | tr '\n' ' ' | sed 's/ $//')"
    check 'postgres: the password is a secret reference' 1 "$(grep -c '^secret *= PGPASSWORD=secret:POSTGRES_MONITOR_PASSWORD' "$root/config/vigil.config" | awk '{ print ($1 >= 1) }')"
    # As an operator points the jobs at a server.
    set_env PGHOST "$VIGIL_IT_PG_HOST"
    set_env PGPORT "${VIGIL_IT_PG_PORT:-5432}"
    check 'postgres: precheck is happy' 0 "$(vigil precheck > "$work/precheck" 2>&1; echo $?)"
    [ "$(cat "$work/precheck" | grep -c FAIL)" -eq 0 ] || sed 's/^/        /' "$work/precheck"

    # A transaction held open for the status job to see, by the same
    # read-only role.
    PGPASSWORD=$VIGIL_IT_PG_PASSWORD psql -X -q -h "$VIGIL_IT_PG_HOST" -p "${VIGIL_IT_PG_PORT:-5432}" -U vigil_monitor -d postgres \
        -c 'BEGIN; SELECT pg_sleep(30); COMMIT;' > /dev/null 2>&1 &
    hold=$!
    sleep 4
    vigil run postgres_status > "$work/out" 2>&1
    check 'postgres: status runs' 0 "$?"
    grep -h ' out metric ' "$root/logs/jobs/postgres_status"/*.log | sed 's/^[^ ]* [^ ]* out /        /'
    check 'postgres: up' 1 "$(printed postgres_status up)"
    check 'postgres: connections seen' yes "$([ "$(printed postgres_status connections)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: the limit' yes "$([ "$(printed postgres_status max_connections)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: a percentage of it' yes "$([ -n "$(printed postgres_status connections_pct)" ] && echo yes || echo no)"
    check 'postgres: the long query seen' yes "$([ "$(printed postgres_status longest_query_seconds)" -ge 2 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: the long transaction seen' yes "$([ "$(printed postgres_status longest_transaction_seconds)" -ge 2 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: commits counted' yes "$([ "$(printed postgres_status commits_count)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: cache hits' yes "$(v=$(printed postgres_status cache_hit_pct); [ "$v" -ge 0 ] 2> /dev/null && [ "$v" -le 100 ] && echo yes || echo no)"
    kill "$hold" 2> /dev/null
    hold=''

    vigil run postgres_size > "$work/out" 2>&1
    check 'postgres: size runs' 0 "$?"
    grep -h ' out metric ' "$root/logs/jobs/postgres_size"/*.log | sed 's/^[^ ]* [^ ]* out /        /'
    check 'postgres: the postgres database sized' yes "$([ "$(printed postgres_size size_bytes database=postgres)" -gt 0 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: no template database' 0 "$(grep -c 'database=template' "$root"/logs/jobs/postgres_size/*.log)"

    # The jobs from 1.2.0, on Linux and macOS.
    check 'postgres: the 1.2.0 jobs are on' 'on on on on on' "$(vigil pack list | awk '$1 ~ /^postgres_(activity|replication|wraparound|vacuum|io)$/ { print $2 }' | tr '\n' ' ' | sed 's/ $//')"
    pg() { PGPASSWORD=$VIGIL_IT_PG_PASSWORD psql -X -q -h "$VIGIL_IT_PG_HOST" -p "${VIGIL_IT_PG_PORT:-5432}" -U vigil_monitor -d postgres "$@"; }
    super() { PGPASSWORD=$VIGIL_IT_PG_SUPER_PASSWORD PGOPTIONS='-c client_min_messages=warning' psql -X -q -h "$VIGIL_IT_PG_HOST" -p "${VIGIL_IT_PG_PORT:-5432}" -U postgres -v ON_ERROR_STOP=1 "$@"; }
    shown() { grep -h ' out metric ' "$root/logs/jobs/$1"/*.log | tail -n "$2" | sed 's/^[^ ]* [^ ]* out /        /'; }

    # A session holds a lock, idle in its transaction; another waits for it.
    ( echo 'BEGIN; SELECT pg_advisory_xact_lock(4242);'; sleep 20 ) | pg > /dev/null 2>&1 &
    hold=$!
    sleep 2
    pg -c 'SELECT pg_advisory_lock(4242)' > /dev/null 2>&1 &
    waiter=$!
    sleep 4
    vigil run postgres_activity > "$work/out" 2>&1
    check 'postgres: activity runs' 0 "$?"
    shown postgres_activity 7
    check 'postgres: the session idle in its transaction' yes "$([ "$(printed postgres_activity idle_in_transaction)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: for some seconds' yes "$([ "$(printed postgres_activity longest_idle_in_transaction_seconds)" -ge 2 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: the session waiting on its lock' yes "$([ "$(printed postgres_activity waiting)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: blocked by it' yes "$([ "$(printed postgres_activity blocked)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: the wait timed' yes "$([ "$(printed postgres_activity longest_wait_seconds)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    kill "$hold" "$waiter" 2> /dev/null
    wait "$hold" "$waiter" 2> /dev/null
    hold=''

    vigil run postgres_wraparound > "$work/out" 2>&1
    check 'postgres: wraparound runs' 0 "$?"
    grep -h ' out metric ' "$root/logs/jobs/postgres_wraparound"/*.log | grep -e 'database=postgres' -e oldest | sed 's/^[^ ]* [^ ]* out /        /'
    check 'postgres: the postgres database aged' yes "$([ "$(printed postgres_wraparound xid_age_count database=postgres)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: and far from the limit' 0 "$(printed postgres_wraparound xid_pct database=postgres)"
    check 'postgres: template0 too, which vacuum must also freeze' yes "$([ -n "$(printed postgres_wraparound xid_age_count database=template0)" ] && echo yes || echo no)"

    # A sort larger than work_mem spills to disk.
    pg -c "SET work_mem = '64kB'; SELECT count(*) FROM (SELECT g FROM generate_series(1, 300000) g ORDER BY g DESC) s;" > /dev/null
    sleep 2
    vigil run postgres_io > "$work/out" 2>&1
    check 'postgres: io runs' 0 "$?"
    shown postgres_io 5
    check 'postgres: the spill counted' yes "$([ "$(printed postgres_io temp_files_count)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: and its bytes' yes "$([ "$(printed postgres_io temp_bytes)" -ge 100000 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: WAL written' yes "$([ "$(printed postgres_io wal_bytes)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: checkpoints counted' yes "$([ -n "$(printed postgres_io checkpoints_timed_count)" ] && [ -n "$(printed postgres_io checkpoints_requested_count)" ] && echo yes || echo no)"

    # With the server's superuser: dead rows autovacuum may not touch, and a
    # replication slot nothing uses. The read-only role can make neither.
    if [ -n "${VIGIL_IT_PG_SUPER_PASSWORD-}" ]; then
        super -d orders -c 'DROP TABLE IF EXISTS vigil_it_ledger; CREATE TABLE vigil_it_ledger(id int) WITH (autovacuum_enabled = false);
            INSERT INTO vigil_it_ledger SELECT generate_series(1, 20000); DELETE FROM vigil_it_ledger;' > /dev/null
        super -d postgres -c "SELECT pg_create_physical_replication_slot('vigil_it_slot', true);" > /dev/null
        sleep 2
    else
        printf '  SKIP  postgres: dead rows and an unused slot: set VIGIL_IT_PG_SUPER_PASSWORD\n'
    fi
    vigil run postgres_vacuum > "$work/out" 2>&1
    check 'postgres: vacuum runs' 0 "$?"
    shown postgres_vacuum 6
    check 'postgres: autovacuum workers' yes "$([ "$(printed postgres_vacuum autovacuum_max_workers)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'postgres: each database it may connect to' yes "$([ -n "$(printed postgres_vacuum dead_tuples_count database=postgres)" ] && [ -n "$(printed postgres_vacuum dead_tuples_count database=orders)" ] && echo yes || echo no)"
    vigil run postgres_replication > "$work/out" 2>&1
    check 'postgres: replication runs' 0 "$?"
    shown postgres_replication 4
    check 'postgres: a primary' 0 "$(printed postgres_replication is_replica)"
    if [ -n "${VIGIL_IT_PG_SUPER_PASSWORD-}" ]; then
        check 'postgres: the dead rows' yes "$([ "$(printed postgres_vacuum dead_tuples_count database=orders)" -ge 20000 ] 2> /dev/null && echo yes || echo no)"
        check 'postgres: their table due' yes "$([ "$(printed postgres_vacuum tables_due_count database=orders)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
        check 'postgres: the unused slot' yes "$([ "$(printed postgres_replication slots_inactive)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
        check 'postgres: the WAL it keeps' yes "$([ -n "$(printed postgres_replication slot_retained_bytes slot=vigil_it_slot)" ] && echo yes || echo no)"
        super -d orders -c 'DROP TABLE vigil_it_ledger;' > /dev/null
        super -d postgres -c "SELECT pg_drop_replication_slot('vigil_it_slot');" > /dev/null
    fi

    # With a streaming replica of this server: the primary sees it, and the
    # replica says it is one and receives.
    if [ -n "${VIGIL_IT_PG_REPLICA_HOST-}" ]; then
        check 'postgres: the replica seen from the primary' yes "$([ "$(printed postgres_replication replicas)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
        check 'postgres: its lag' yes "$([ -n "$(printed postgres_replication lag_bytes replica=)" ] && echo yes || echo no)"
        set_env PGHOST "$VIGIL_IT_PG_REPLICA_HOST"
        set_env PGPORT "${VIGIL_IT_PG_REPLICA_PORT:-5432}"
        vigil run postgres_replication > "$work/out" 2>&1
        check 'postgres: replication runs on the replica' 0 "$?"
        shown postgres_replication 4
        check 'postgres: a replica' 1 "$(printed postgres_replication is_replica)"
        check 'postgres: receiving' 1 "$(printed postgres_replication receiver_up)"
        set_env PGHOST "$VIGIL_IT_PG_HOST"
        set_env PGPORT "${VIGIL_IT_PG_PORT:-5432}"
    else
        printf '  SKIP  postgres: a replica: set VIGIL_IT_PG_REPLICA_HOST (compose.replication.yaml)\n'
    fi

    # A wrong password fails the run and says why; it is not "down".
    printf 'not-the-password' | vigil secret set POSTGRES_MONITOR_PASSWORD --stdin > /dev/null
    vigil run postgres_status > "$work/out" 2>&1
    check 'postgres: a wrong password fails the run' 2 "$?"
    check 'postgres: and says why' yes "$(grep -q 'refused the login' "$root"/logs/jobs/postgres_status/*.log && echo yes || echo no)"
    printf '%s' "$VIGIL_IT_PG_PASSWORD" | vigil secret set POSTGRES_MONITOR_PASSWORD --stdin > /dev/null

    # A server that does not answer is a reading.
    set_env PGPORT 1
    vigil run postgres_status > "$work/out" 2>&1
    check 'postgres: a server that is down still runs' 0 "$?"
    check 'postgres: and reads as up 0' 0 "$(printed postgres_status up)"
    # The others print nothing then, and succeed: status has said it.
    before=$(grep -c ' out metric ' "$root"/logs/jobs/postgres_activity/*.log)
    vigil run postgres_activity > "$work/out" 2>&1
    check 'postgres: the other jobs succeed when it is down' 0 "$?"
    check 'postgres: and say nothing' "$before" "$(grep -c ' out metric ' "$root"/logs/jobs/postgres_activity/*.log)"
    set_env PGPORT "${VIGIL_IT_PG_PORT:-5432}"
fi

# --- mysql ------------------------------------------------------------------
if [ -z "${VIGIL_IT_MYSQL_HOST-}" ] || [ -z "${VIGIL_IT_MYSQL_PASSWORD-}" ]; then
    printf '  SKIP  mysql: set VIGIL_IT_MYSQL_HOST and VIGIL_IT_MYSQL_PASSWORD\n'
elif ! command -v mysql > /dev/null 2>&1 && ! command -v mariadb > /dev/null 2>&1; then
    printf '  SKIP  mysql: neither mysql nor mariadb is installed here\n'
else
    printf 'mysql at %s:%s\n' "$VIGIL_IT_MYSQL_HOST" "${VIGIL_IT_MYSQL_PORT:-3306}"
    myclient=$(command -v mysql || command -v mariadb)
    # The test's own sessions; their stderr (MariaDB's client warns there)
    # is not the test's business.
    myroot() {
        MYSQL_PWD=$VIGIL_IT_MYSQL_ROOT_PASSWORD "$myclient" --protocol=TCP -h "$VIGIL_IT_MYSQL_HOST" \
            -P "${VIGIL_IT_MYSQL_PORT:-3306}" -u root -N -B orders "$@" 2> /dev/null
    }
    jobs_on() { vigil pack list | awk '$1 ~ /^mysql_/ { print $2 }' | tr '\n' ' ' | sed 's/ $//'; }
    check 'mysql: off until enabled' 'off off off off off' "$(jobs_on)"
    out=$(vigil pack enable mysql 2>&1)
    check 'mysql: enabled' 0 "$?"
    printf '%s\n' "$out" | sed 's/^/        /'
    check 'mysql: its jobs are on' 'on on on on on' "$(jobs_on)"
    check 'mysql: the password is a secret reference' 1 "$(grep -c '^secret *= MYSQL_PWD=secret:MYSQL_MONITOR_PASSWORD' "$root/config/vigil.config" | awk '{ print ($1 >= 1) }')"
    printf '%s' "$VIGIL_IT_MYSQL_PASSWORD" | vigil secret set MYSQL_MONITOR_PASSWORD --stdin > /dev/null
    set_env MYSQL_HOST "$VIGIL_IT_MYSQL_HOST"
    set_env MYSQL_TCP_PORT "${VIGIL_IT_MYSQL_PORT:-3306}"
    check 'mysql: precheck is happy' 0 "$(vigil precheck > "$work/precheck" 2>&1; echo $?)"

    # With root: a transaction holds a row lock, idle on its connection, and
    # another statement waits for the row.
    if [ -n "${VIGIL_IT_MYSQL_ROOT_PASSWORD-}" ]; then
        printf 'DROP TABLE IF EXISTS vigil_it_ledger;
CREATE TABLE vigil_it_ledger (id INT PRIMARY KEY, v INT) ENGINE = InnoDB;
INSERT INTO vigil_it_ledger VALUES (1, 0), (2, 0);\n' | myroot
        ( echo 'BEGIN; UPDATE vigil_it_ledger SET v = v + 1 WHERE id = 1;'; sleep 20; echo 'ROLLBACK;' ) | myroot > /dev/null &
        hold=$!
        sleep 2
        echo 'UPDATE vigil_it_ledger SET v = v + 2 WHERE id = 1;' | myroot > /dev/null &
        waiter=$!
        sleep 4
    else
        printf '  SKIP  mysql: a held row lock and a deadlock: set VIGIL_IT_MYSQL_ROOT_PASSWORD\n'
    fi
    for j in status activity replication innodb size; do
        vigil run "mysql_$j" > "$work/out" 2>&1
        check "mysql: $j runs" 0 "$?"
        grep -h ' out metric ' "$root/logs/jobs/mysql_$j"/*.log | tail -n 10 | sed 's/^[^ ]* [^ ]* out /        /'
    done
    check 'mysql: up' 1 "$(printed mysql_status up)"
    check 'mysql: connections seen' yes "$([ "$(printed mysql_status connections)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'mysql: the limit' yes "$([ "$(printed mysql_status max_connections)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'mysql: statements counted' yes "$([ "$(printed mysql_status queries_count)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'mysql: a source' 0 "$(printed mysql_replication is_replica)"
    check 'mysql: the buffer pool' yes "$(v=$(printed mysql_innodb buffer_pool_used_pct); [ "$v" -ge 0 ] 2> /dev/null && [ "$v" -le 100 ] && echo yes || echo no)"
    check 'mysql: no warning taken for data' 0 "$(grep ' out metric ' "$root"/logs/jobs/mysql_*/*.log | grep -vcE ' out metric [a-z_]+ -?[0-9]+( [a-z]+=[A-Za-z0-9_.-]+)?$')"
    if [ -n "${VIGIL_IT_MYSQL_ROOT_PASSWORD-}" ]; then
        check 'mysql: the transaction idle on its connection' yes "$([ "$(printed mysql_activity idle_in_transaction)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
        check 'mysql: the statement waiting for its row' yes "$([ "$(printed mysql_activity waiting)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
        check 'mysql: the wait timed' yes "$([ "$(printed mysql_activity longest_wait_seconds)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
        check 'mysql: the waiting statement seen running' yes "$([ "$(printed mysql_status longest_query_seconds)" -ge 2 ] 2> /dev/null && echo yes || echo no)"
        check 'mysql: the table sized' yes "$([ "$(printed mysql_size size_bytes database=orders)" -gt 0 ] 2> /dev/null && echo yes || echo no)"
        kill "$hold" "$waiter" 2> /dev/null
        wait "$hold" "$waiter" 2> /dev/null
        hold=''
        # A deadlock: two transactions take the same two rows in opposite orders.
        before=$(printed mysql_innodb deadlocks_count)
        ( echo 'BEGIN; UPDATE vigil_it_ledger SET v = 1 WHERE id = 1;'; sleep 2; echo 'UPDATE vigil_it_ledger SET v = 1 WHERE id = 2;'; sleep 3; echo 'COMMIT;' ) | myroot > /dev/null &
        a=$!
        ( sleep 1; echo 'BEGIN; UPDATE vigil_it_ledger SET v = 2 WHERE id = 2;'; sleep 2; echo 'UPDATE vigil_it_ledger SET v = 2 WHERE id = 1;'; sleep 1; echo 'COMMIT;' ) | myroot > /dev/null &
        b=$!
        wait "$a" "$b" 2> /dev/null
        vigil run mysql_innodb > "$work/out" 2>&1
        check 'mysql: the deadlock counted' yes "$([ "$(printed mysql_innodb deadlocks_count)" -gt "${before:-0}" ] 2> /dev/null && echo yes || echo no)"
        echo 'DROP TABLE vigil_it_ledger;' | myroot
    fi

    # With a replica of this server: the source sees it, and the replica says
    # it is one, with both its threads running.
    if [ -n "${VIGIL_IT_MYSQL_REPLICA_HOST-}" ]; then
        check 'mysql: the replica seen from the source' yes "$([ "$(printed mysql_replication replicas)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
        set_env MYSQL_HOST "$VIGIL_IT_MYSQL_REPLICA_HOST"
        set_env MYSQL_TCP_PORT "${VIGIL_IT_MYSQL_REPLICA_PORT:-3306}"
        vigil run mysql_replication > "$work/out" 2>&1
        check 'mysql: replication runs on the replica' 0 "$?"
        grep -h ' out metric ' "$root/logs/jobs/mysql_replication"/*.log | tail -n 5 | sed 's/^[^ ]* [^ ]* out /        /'
        check 'mysql: a replica' 1 "$(printed mysql_replication is_replica)"
        check 'mysql: receiving' 1 "$(printed mysql_replication io_running channel=default)"
        check 'mysql: applying' 1 "$(printed mysql_replication sql_running channel=default)"
        check 'mysql: its lag' yes "$([ -n "$(printed mysql_replication lag_seconds channel=default)" ] && echo yes || echo no)"
        set_env MYSQL_HOST "$VIGIL_IT_MYSQL_HOST"
        set_env MYSQL_TCP_PORT "${VIGIL_IT_MYSQL_PORT:-3306}"
    else
        printf '  SKIP  mysql: a replica: set VIGIL_IT_MYSQL_REPLICA_HOST (compose.mysql.yaml)\n'
    fi

    # A wrong password fails the run and says why; it is not "down".
    printf 'not-the-password' | vigil secret set MYSQL_MONITOR_PASSWORD --stdin > /dev/null
    vigil run mysql_status > "$work/out" 2>&1
    check 'mysql: a wrong password fails the run' 2 "$?"
    check 'mysql: and says why' yes "$(grep -q 'refused the login' "$root"/logs/jobs/mysql_status/*.log && echo yes || echo no)"
    printf '%s' "$VIGIL_IT_MYSQL_PASSWORD" | vigil secret set MYSQL_MONITOR_PASSWORD --stdin > /dev/null

    # A server that does not answer is a reading; the other jobs say nothing.
    set_env MYSQL_TCP_PORT 1
    vigil run mysql_status > "$work/out" 2>&1
    check 'mysql: a server that is down still runs' 0 "$?"
    check 'mysql: and reads as up 0' 0 "$(printed mysql_status up)"
    before=$(grep -c ' out metric ' "$root"/logs/jobs/mysql_activity/*.log)
    vigil run mysql_activity > "$work/out" 2>&1
    check 'mysql: the other jobs succeed when it is down' 0 "$?"
    check 'mysql: and say nothing' "$before" "$(grep -c ' out metric ' "$root"/logs/jobs/mysql_activity/*.log)"
    set_env MYSQL_TCP_PORT "${VIGIL_IT_MYSQL_PORT:-3306}"
fi

# --- redis ------------------------------------------------------------------
if [ -z "${VIGIL_IT_REDIS_HOST-}" ] || [ -z "${VIGIL_IT_REDIS_PASSWORD-}" ]; then
    printf '  SKIP  redis: set VIGIL_IT_REDIS_HOST and VIGIL_IT_REDIS_PASSWORD\n'
elif ! command -v redis-cli > /dev/null 2>&1 && ! command -v valkey-cli > /dev/null 2>&1; then
    printf '  SKIP  redis: neither redis-cli nor valkey-cli is installed here\n'
else
    # The jobs have their password from Vigil, or none: never from this
    # test's own environment.
    unset REDISCLI_AUTH VALKEYCLI_AUTH
    rport=${VIGIL_IT_REDIS_PORT:-6379}
    printf 'redis at %s:%s\n' "$VIGIL_IT_REDIS_HOST" "$rport"
    rclient=$(command -v redis-cli || command -v valkey-cli)
    # The test's own commands, as admin, which may do anything.
    radmin() {
        REDISCLI_AUTH=$VIGIL_IT_REDIS_ADMIN_PASSWORD "$rclient" -h "$VIGIL_IT_REDIS_HOST" -p "$rport" --user admin "$@" 2> /dev/null
    }
    rjobs_on() { vigil pack list | awk '$1 ~ /^redis_/ { print $2 }' | tr '\n' ' ' | sed 's/ $//'; }
    # Whether the last value job $1 printed for $2 (tags $3) is a number
    # from $4 to $5.
    between() { local v; v=$(printed "$1" "$2" "${3-}"); awk -v v="$v" -v a="$4" -v b="$5" 'BEGIN { print (v ~ /^-?[0-9]+(\.[0-9]+)?$/ && v + 0 >= a && v + 0 <= b) ? "yes" : "no [" v "]" }'; }
    # The redis jobs' TLS lines: REDIS_TLS=$1 and REDIS_CACERT=$2, each left
    # out when empty, as an operator adds them under REDIS_PORT.
    tls_env() {
        awk -v tls="$1" -v ca="$2" '
            /^env *= REDIS_(TLS|CACERT)=/ { next }
            { print }
            /^env *= REDIS_PORT=/ {
                if (tls != "") print "env         = REDIS_TLS=" tls
                if (ca != "") print "env         = REDIS_CACERT=" ca
            }' "$root/config/vigil.config" > "$work/cfg" && cat "$work/cfg" > "$root/config/vigil.config"
    }
    # Its last run's log, for what it said.
    said() {
        local f rid
        f=$(ls "$root/logs/jobs/$1"/*.log | tail -n 1)
        rid=$(tail -n 1 "$f" | awk '{ print $2 }')
        grep " $rid " "$f" | grep -q -- "$2" && echo yes || echo no
    }
    runs() { vigil run "$1" > "$work/out" 2>&1; echo $?; }
    check 'redis: off until enabled' 'off off off off off' "$(rjobs_on)"
    out=$(vigil pack enable redis 2>&1)
    check 'redis: enabled' 0 "$?"
    printf '%s\n' "$out" | sed 's/^/        /'
    check 'redis: its jobs are on' 'on on on on on' "$(rjobs_on)"
    check 'redis: the password is a secret reference' 1 "$(grep -c '^secret *= REDISCLI_AUTH=secret:REDIS_MONITOR_PASSWORD' "$root/config/vigil.config" | awk '{ print ($1 >= 1) }')"
    printf '%s' "$VIGIL_IT_REDIS_PASSWORD" | vigil secret set REDIS_MONITOR_PASSWORD --stdin > /dev/null
    set_env REDIS_HOST "$VIGIL_IT_REDIS_HOST"
    set_env REDIS_PORT "$rport"
    check 'redis: precheck is happy' 0 "$(vigil precheck > "$work/precheck" 2>&1; echo $?)"

    # With admin: a lookup that hits and one that misses; more data than
    # maxmemory allows, when there is a limit, so the server evicts; then
    # keys in two databases, some expiring; a client blocked on a list no one
    # writes; and a snapshot. The lookups come first, and the keys two
    # seconds after the fill: the server's LRU clock ticks once a second, and
    # a key written in the same second as the fill may be evicted with it.
    if [ -n "${VIGIL_IT_REDIS_ADMIN_PASSWORD-}" ]; then
        radmin SET vigil_it:key:1 1 > /dev/null
        radmin GET vigil_it:key:1 > /dev/null
        radmin GET vigil_it:no-such-key > /dev/null
        maxmem=$(radmin CONFIG GET maxmemory | tail -n 1 | tr -d '\r')
        if [ "${maxmem:-0}" -gt 0 ] 2> /dev/null; then
            n=$((maxmem / 4096 / 2000 + 1))
            for i in $(seq 1 $((n * 2))); do
                radmin EVAL "for i = 1, 2000 do redis.call('SET', 'vigil_it:fill:' .. ARGV[1] .. ':' .. i, string.rep('x', 4096)) end" 0 "$i" > /dev/null
            done
            sleep 2
        fi
        for i in 1 2 3 4 5; do radmin SET "vigil_it:key:$i" "$i" > /dev/null; done
        radmin -n 3 SET vigil_it:expiring 1 EX 600 > /dev/null
        radmin BLPOP vigil_it:never 25 > /dev/null &
        hold=$!
        radmin BGSAVE > /dev/null
        for _ in $(seq 1 30); do
            radmin INFO persistence | tr -d '\r' | grep -q '^rdb_bgsave_in_progress:0' && break
            sleep 1
        done
        sleep 2
    else
        printf '  SKIP  redis: keys, lookups, a blocked client, evictions and a snapshot: set VIGIL_IT_REDIS_ADMIN_PASSWORD\n'
    fi
    for j in status memory replication persistence keyspace; do
        check "redis: $j runs" 0 "$(runs "redis_$j")"
        grep -h ' out metric ' "$root/logs/jobs/redis_$j"/*.log | tail -n 20 | sed 's/^[^ ]* [^ ]* out /        /'
    done
    check 'redis: up' 1 "$(printed redis_status up)"
    check 'redis: what it is' yes "$(grep -h ' out metric info 1 server=' "$root"/logs/jobs/redis_status/*.log | grep -qE 'server=(redis|valkey) version=[0-9][0-9.]* mode=standalone$' && echo yes || echo no)"
    check 'redis: not loading' 0 "$(printed redis_status loading)"
    check 'redis: clients seen' yes "$(between redis_status clients '' 1 100000)"
    check 'redis: the limit' yes "$(between redis_status max_clients '' 1 10000000)"
    check 'redis: clients against it' yes "$(between redis_status clients_pct '' 0 100)"
    check 'redis: commands counted' yes "$(between redis_status commands_count '' 1 1e18)"
    check 'redis: memory used' yes "$(between redis_memory used_bytes '' 1 1e15)"
    check 'redis: memory from the system' yes "$(between redis_memory rss_bytes '' 1 1e15)"
    check 'redis: the limit and its policy' yes "$(grep -h ' out metric max_bytes [0-9]* policy=[a-z-]*$' "$root"/logs/jobs/redis_memory/*.log > /dev/null && echo yes || echo no)"
    check 'redis: fragmentation' yes "$(between redis_memory fragmentation_ratio '' 0 100000)"
    check 'redis: a primary' 0 "$(printed redis_replication is_replica)"
    check 'redis: the last snapshot worked' 1 "$(printed redis_persistence last_save_ok)"
    check 'redis: its age' yes "$(between redis_persistence last_save_age_seconds '' 0 1e9)"
    check 'redis: the append-only file is fine' 1 "$(printed redis_persistence aof_last_write_ok)"
    check 'redis: keys in db0' yes "$(between redis_keyspace keys db=db0 0 1e12)"
    check 'redis: no warning taken for data' 0 "$(grep ' out metric ' "$root"/logs/jobs/redis_*/*.log | grep -vcE ' out metric [a-z_]+ -?[0-9]+(\.[0-9]+)?( [a-z]+=[A-Za-z0-9_.-]+)*$')"
    if [ -n "${VIGIL_IT_REDIS_ADMIN_PASSWORD-}" ]; then
        check 'redis: a lookup that hit' yes "$(between redis_status hits_count '' 1 1e18)"
        check 'redis: one that missed' yes "$(between redis_status misses_count '' 1 1e18)"
        check 'redis: the hit rate' yes "$(between redis_status hit_pct '' 0 100)"
        check 'redis: the blocked client' yes "$(between redis_status blocked_clients '' 1 100000)"
        check 'redis: keys in db3' yes "$(between redis_keyspace keys db=db3 1 1e12)"
        check 'redis: expiring in db3' yes "$(between redis_keyspace expires db=db3 1 1e12)"
        check 'redis: the snapshot just written' yes "$(between redis_persistence last_save_age_seconds '' 0 60)"
        check 'redis: its fork timed' yes "$(between redis_persistence last_fork_usec '' 1 1e9)"
        if [ "${maxmem:-0}" -gt 0 ] 2> /dev/null; then
            check 'redis: keys evicted at maxmemory' yes "$(between redis_status evicted_keys_count '' 1 1e18)"
            check 'redis: memory against the limit' yes "$(between redis_memory used_pct '' 50 150)"
            check 'redis: the policy that evicts' yes "$(grep -h ' out metric max_bytes ' "$root"/logs/jobs/redis_memory/*.log | tail -n 1 | grep -q 'policy=allkeys-lru$' && echo yes || echo no)"
        fi
        kill "$hold" 2> /dev/null
        wait "$hold" 2> /dev/null
        hold=''
    fi

    # With a replica of this server: the primary sees it in step, and the
    # replica says it is one, linked and up to date.
    if [ -n "${VIGIL_IT_REDIS_REPLICA_HOST-}" ]; then
        check 'redis: the replica seen from the primary' yes "$(between redis_replication replicas '' 1 1000)"
        check 'redis: in step' 1 "$(printed redis_replication online replica=)"
        check 'redis: its lag in bytes' yes "$(between redis_replication lag_bytes replica= 0 1e15)"
        check 'redis: its lag in seconds' yes "$(between redis_replication lag_seconds replica= 0 1e9)"
        set_env REDIS_HOST "$VIGIL_IT_REDIS_REPLICA_HOST"
        set_env REDIS_PORT "${VIGIL_IT_REDIS_REPLICA_PORT:-6379}"
        check 'redis: replication runs on the replica' 0 "$(runs redis_replication)"
        grep -h ' out metric ' "$root/logs/jobs/redis_replication"/*.log | tail -n 5 | sed 's/^[^ ]* [^ ]* out /        /'
        check 'redis: a replica' 1 "$(printed redis_replication is_replica)"
        check 'redis: its link up' 1 "$(printed redis_replication link_up)"
        check 'redis: heard from the primary' yes "$(between redis_replication last_io_seconds '' 0 60)"
        check 'redis: no copy under way' 0 "$(printed redis_replication sync_in_progress)"
        if [ -n "${VIGIL_IT_REDIS_ADMIN_PASSWORD-}" ]; then
            check 'redis: keyspace runs on the replica' 0 "$(runs redis_keyspace)"
            check 'redis: the keys copied over' yes "$(between redis_keyspace keys db=db3 1 1e12)"
        fi
        set_env REDIS_HOST "$VIGIL_IT_REDIS_HOST"
        set_env REDIS_PORT "$rport"
    else
        printf '  SKIP  redis: a replica: set VIGIL_IT_REDIS_REPLICA_HOST (compose.redis.yaml)\n'
    fi

    # TLS: the server's certificate checked against the CA given; one that
    # cannot be trusted, and plain TCP to a TLS port, fail the run. This
    # server's default user is open: with no password the jobs read it as
    # that user, and a wrong password must still fail, though the default
    # user would answer.
    if [ -n "${VIGIL_IT_REDIS_TLS_HOST-}" ] && [ -n "${VIGIL_IT_REDIS_CACERT-}" ]; then
        set_env REDIS_HOST "$VIGIL_IT_REDIS_TLS_HOST"
        set_env REDIS_PORT "${VIGIL_IT_REDIS_TLS_PORT:-6379}"
        tls_env 1 "$VIGIL_IT_REDIS_CACERT"
        check 'redis: TLS, against its CA' 0 "$(runs redis_status)"
        check 'redis: TLS: up' 1 "$(printed redis_status up)"
        check 'redis: TLS: the other jobs too' '0 0 0 0' "$(for j in memory replication persistence keyspace; do runs "redis_$j"; done | tr '\n' ' ' | sed 's/ $//')"
        tls_env 1 ''
        check 'redis: TLS: a certificate it cannot trust fails the run' 2 "$(runs redis_status)"
        check 'redis: and says why' yes "$(said redis_status 'INFO failed')"
        tls_env 0 ''
        check 'redis: plain TCP to a TLS port fails the run' 2 "$(runs redis_status)"
        tls_env 1 "$VIGIL_IT_REDIS_CACERT"
        printf 'not-the-password' | vigil secret set REDIS_MONITOR_PASSWORD --stdin > /dev/null
        check 'redis: a wrong password fails, though the default user is open' 2 "$(runs redis_status)"
        check 'redis: and says why' yes "$(said redis_status 'refused the login')"
        printf '%s' "$VIGIL_IT_REDIS_PASSWORD" | vigil secret set REDIS_MONITOR_PASSWORD --stdin > /dev/null
        # No password at all, as on a server with none: the secret lines go.
        cp "$root/config/vigil.config" "$work/cfg.keep"
        grep -v '^secret *= REDISCLI_AUTH=' "$work/cfg.keep" > "$root/config/vigil.config"
        check 'redis: with no password, as the default user' 0 "$(runs redis_status)"
        check 'redis: up' 1 "$(printed redis_status up)"
        cat "$work/cfg.keep" > "$root/config/vigil.config"
        tls_env '' ''
        set_env REDIS_HOST "$VIGIL_IT_REDIS_HOST"
        set_env REDIS_PORT "$rport"
    else
        printf '  SKIP  redis: TLS: set VIGIL_IT_REDIS_TLS_HOST and VIGIL_IT_REDIS_CACERT (compose.redis.yaml)\n'
    fi

    # A wrong password fails the run and says why; it is not "down".
    printf 'not-the-password' | vigil secret set REDIS_MONITOR_PASSWORD --stdin > /dev/null
    check 'redis: a wrong password fails the run' 2 "$(runs redis_status)"
    check 'redis: and says why' yes "$(said redis_status 'refused the login')"
    printf '%s' "$VIGIL_IT_REDIS_PASSWORD" | vigil secret set REDIS_MONITOR_PASSWORD --stdin > /dev/null
    # A user that may not run INFO.
    set_env REDIS_USER vigil_noinfo
    check 'redis: a user that may not run INFO fails the run' 2 "$(runs redis_memory)"
    check 'redis: and says why' yes "$(said redis_memory 'NOPERM')"
    set_env REDIS_USER vigil_monitor

    # A server that does not answer is a reading; the other jobs say nothing.
    set_env REDIS_PORT 1
    check 'redis: a server that is down still runs' 0 "$(runs redis_status)"
    check 'redis: and reads as up 0' 0 "$(printed redis_status up)"
    before=$(grep -c ' out metric ' "$root"/logs/jobs/redis_memory/*.log)
    check 'redis: the other jobs succeed when it is down' 0 "$(runs redis_memory)"
    check 'redis: and say nothing' "$before" "$(grep -c ' out metric ' "$root"/logs/jobs/redis_memory/*.log)"
    set_env REDIS_PORT "$rport"
    # And it is up again, for the backend.
    runs redis_status > /dev/null
fi

# --- mssql ------------------------------------------------------------------
if [ -z "${VIGIL_IT_MSSQL_HOST-}" ] || [ -z "${VIGIL_IT_MSSQL_PASSWORD-}" ]; then
    printf '  SKIP  mssql: set VIGIL_IT_MSSQL_HOST and VIGIL_IT_MSSQL_PASSWORD\n'
elif ! command -v sqlcmd > /dev/null 2>&1 && [ ! -x /opt/mssql-tools18/bin/sqlcmd ]; then
    printf '  SKIP  mssql: sqlcmd is not installed here\n'
else
    # The jobs have their password, server and CA from Vigil: never from
    # this test's own environment.
    unset SQLCMDPASSWORD MSSQL_HOST MSSQL_PORT MSSQL_USER MSSQL_CACERT MSSQL_CERT_NAME SSL_CERT_FILE
    mport=${VIGIL_IT_MSSQL_PORT:-1433}
    printf 'mssql at %s:%s\n' "$VIGIL_IT_MSSQL_HOST" "$mport"
    mclient=$(command -v sqlcmd || echo /opt/mssql-tools18/bin/sqlcmd)
    # The test's own SQL, as sa, on stdin; the password in the environment.
    msa() {
        SQLCMDPASSWORD=$VIGIL_IT_MSSQL_SA_PASSWORD SSL_CERT_FILE=${VIGIL_IT_MSSQL_CACERT-} \
            "$mclient" -S "tcp:$VIGIL_IT_MSSQL_HOST,${2:-$mport}" -U sa -d master -Nm -l 10 -h -1 -W -b -i /dev/stdin <<< "SET NOCOUNT ON; $1" 2>&1
    }
    mjobs_on() { vigil pack list | awk '$1 ~ /^mssql_/ { print $2 }' | sort | uniq -c | awk '{ print $2 "=" $1 }' | tr '\n' ' ' | sed 's/ $//'; }
    between() { local v; v=$(printed "$1" "$2" "${3-}"); awk -v v="$v" -v a="$4" -v b="$5" 'BEGIN { print (v ~ /^-?[0-9]+(\.[0-9]+)?$/ && v + 0 >= a && v + 0 <= b) ? "yes" : "no [" v "]" }'; }
    # The mssql jobs' MSSQL_CACERT line, $1, or none when empty, as an
    # operator adds it under MSSQL_PORT.
    ca_env() {
        awk -v ca="$1" '
            /^env *= MSSQL_CACERT=/ { next }
            { print }
            /^env *= MSSQL_PORT=/ { if (ca != "") print "env         = MSSQL_CACERT=" ca }' "$root/config/vigil.config" > "$work/cfg" && cat "$work/cfg" > "$root/config/vigil.config"
    }
    said() {
        local f rid
        f=$(ls "$root/logs/jobs/$1"/*.log | tail -n 1)
        rid=$(tail -n 1 "$f" | awk '{ print $2 }')
        grep " $rid " "$f" | grep -q -- "$2" && echo yes || echo no
    }
    runs() { vigil run "$1" > "$work/out" 2>&1; echo $?; }
    # activity first, while the waiter waits.
    mjobs='activity status performance cpu replication waits io memory tempdb connections databases health config backups agent'
    check 'mssql: off until enabled' 'off=15' "$(mjobs_on)"
    out=$(vigil pack enable mssql 2>&1)
    check 'mssql: enabled' 0 "$?"
    printf '%s\n' "$out" | sed 's/^/        /'
    check 'mssql: its jobs are on' 'on=15' "$(mjobs_on)"
    check 'mssql: the password is a secret reference' 15 "$(grep -c '^secret *= SQLCMDPASSWORD=secret:MSSQL_MONITOR_PASSWORD' "$root/config/vigil.config")"
    printf '%s' "$VIGIL_IT_MSSQL_PASSWORD" | vigil secret set MSSQL_MONITOR_PASSWORD --stdin > /dev/null
    set_env MSSQL_HOST "$VIGIL_IT_MSSQL_HOST"
    set_env MSSQL_PORT "$mport"
    [ -n "${VIGIL_IT_MSSQL_CACERT-}" ] && ca_env "$VIGIL_IT_MSSQL_CACERT"
    check 'mssql: precheck is happy' 0 "$(vigil precheck > "$work/precheck" 2>&1; echo $?)"

    # As sa: a table, a full backup and a log backup, an integrity check, a
    # session asleep with its transaction open holding a row lock and
    # another blocked behind it, and an Agent job that fails.
    if [ -n "${VIGIL_IT_MSSQL_SA_PASSWORD-}" ]; then
        db=${VIGIL_IT_MSSQL_DATABASE:-vigil_it}
        msa "IF DB_ID('$db') IS NULL BEGIN CREATE DATABASE [$db]; ALTER DATABASE [$db] SET RECOVERY FULL; END" > /dev/null
        msa "USE [$db]; IF OBJECT_ID('dbo.t') IS NULL CREATE TABLE dbo.t (id int PRIMARY KEY, v int); IF NOT EXISTS (SELECT 1 FROM dbo.t) INSERT dbo.t VALUES (1, 0), (2, 0);" > /dev/null
        msa "BACKUP DATABASE [$db] TO DISK = N'/var/opt/mssql/data/$db.bak' WITH INIT; BACKUP LOG [$db] TO DISK = N'/var/opt/mssql/data/$db.trn' WITH INIT;" > /dev/null
        msa "DBCC CHECKDB([$db]) WITH NO_INFOMSGS;" > /dev/null
        msa "USE msdb; IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'vigil_it_failing') EXEC dbo.sp_delete_job @job_name = N'vigil_it_failing';
            EXEC dbo.sp_add_job @job_name = N'vigil_it_failing';
            EXEC dbo.sp_add_jobstep @job_name = N'vigil_it_failing', @step_name = N'fail', @subsystem = N'TSQL', @command = N'RAISERROR(''vigil test'', 16, 1);';
            EXEC dbo.sp_add_jobserver @job_name = N'vigil_it_failing';
            EXEC dbo.sp_start_job @job_name = N'vigil_it_failing';" > /dev/null
        # The holder: asleep, its transaction open, until the test ends it.
        { printf 'SET NOCOUNT ON; USE [%s]; BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1;\nGO\n' "$db"; sleep 160; } |
            SQLCMDPASSWORD=$VIGIL_IT_MSSQL_SA_PASSWORD SSL_CERT_FILE=${VIGIL_IT_MSSQL_CACERT-} "$mclient" -S "tcp:$VIGIL_IT_MSSQL_HOST,$mport" -U sa -Nm -l 10 > /dev/null 2>&1 &
        hold=$!
        sleep 3
        # The waiter, blocked behind it, gives up after 150 seconds.
        msa "SET LOCK_TIMEOUT 150000; USE [$db]; UPDATE dbo.t SET v = v + 1 WHERE id = 1;" > /dev/null &
        hold2=$!
        sleep 8
    else
        printf '  SKIP  mssql: a database, backups, CHECKDB, blocking and an Agent job: set VIGIL_IT_MSSQL_SA_PASSWORD\n'
    fi
    for j in $mjobs; do
        check "mssql: $j runs" 0 "$(runs "mssql_$j")"
        grep -h ' out metric ' "$root/logs/jobs/mssql_$j"/*.log | tail -n 12 | sed 's/^[^ ]* [^ ]* out /        /'
    done
    check 'mssql: up' 1 "$(printed mssql_status up)"
    check 'mssql: what it is' yes "$(grep -h ' out metric info 1 release=' "$root"/logs/jobs/mssql_status/*.log | grep -qE 'release=20(19|22|25) version=1[5-7]\.[0-9.]+ update=[A-Za-z0-9]+ edition=[a-z]+ os=(linux|windows)$' && echo yes || echo no)"
    check 'mssql: its uptime' yes "$(between mssql_status uptime_seconds '' 1 1e10)"
    check 'mssql: connections' yes "$(between mssql_status connections '' 1 100000)"
    check 'mssql: requests counted' yes "$(between mssql_performance batch_requests_count '' 1 1e18)"
    check 'mssql: page life' yes "$(between mssql_performance page_life_expectancy_seconds '' 0 1e10)"
    check 'mssql: the buffer cache hit ratio' yes "$(between mssql_performance buffer_cache_hit_pct '' 0 100)"
    check 'mssql: workers against the most' yes "$(between mssql_cpu workers_pct '' 0.01 100)"
    # SQL Server records its CPU once a minute: none yet on a server just
    # started.
    for _ in $(seq 1 12); do [ -n "$(printed mssql_cpu sql_pct)" ] && break; sleep 10; runs mssql_cpu > /dev/null; done
    check 'mssql: SQL Server CPU' yes "$(between mssql_cpu sql_pct '' 0 100)"
    check 'mssql: waits by kind' yes "$(between mssql_waits wait_ms_count kind=disk_read 0 1e18)"
    check 'mssql: reads, file by file' yes "$(between mssql_io reads_count 'database=master file=master kind=data' 1 1e18)"
    check 'mssql: memory it aims for' yes "$(between mssql_memory target_bytes '' 1 1e15)"
    check 'mssql: the plan cache' yes "$(between mssql_memory plan_cache_bytes '' 1 1e15)"
    check 'mssql: tempdb free' yes "$(between mssql_tempdb free_pct '' 0 100)"
    check 'mssql: our connections encrypted' yes "$(between mssql_connections connections encrypted=yes 1 100000)"
    check 'mssql: master online' 1 "$(printed mssql_databases online database=master)"
    check 'mssql: log use' yes "$(between mssql_databases log_used_pct database=master 0 100)"
    check 'mssql: virtual log files' yes "$(between mssql_health vlfs database=master 1 1e6)"
    check 'mssql: disk space' yes "$(between mssql_health volume_free_pct volume= 0 100)"
    check 'mssql: no damaged pages' 0 "$(printed mssql_health suspect_pages)"
    check 'mssql: xp_cmdshell off' 0 "$(printed mssql_config xp_cmdshell)"
    check 'mssql: Agent jobs not readable without their grants' 0 "$(printed mssql_agent readable)"
    check 'mssql: no warning taken for data' 0 "$(grep ' out metric ' "$root"/logs/jobs/mssql_*/*.log | grep -vcE ' out metric [a-z_]+ -?[0-9]+(\.[0-9]+)?( [a-z0-9_]+=[A-Za-z0-9_.-]+)*$')"
    if [ -n "${VIGIL_IT_MSSQL_SA_PASSWORD-}" ]; then
        check 'mssql: a request blocked' yes "$(between mssql_activity requests_blocked '' 1 1000)"
        check 'mssql: and its head blocker' yes "$(between mssql_activity head_blockers '' 1 1000)"
        check 'mssql: asleep with a transaction open' yes "$(between mssql_activity idle_in_transaction '' 1 1000)"
        check 'mssql: for some seconds' yes "$(between mssql_activity idle_in_transaction_seconds '' 3 120)"
        check 'mssql: the open transaction' yes "$(between mssql_activity oldest_transaction_seconds '' 3 120)"
        check 'mssql: the wait is a lock' yes "$(grep -h ' out metric longest_wait_seconds ' "$root"/logs/jobs/mssql_activity/*.log | tail -n 1 | grep -q 'type=LCK_M_' && echo yes || echo no)"
        check 'mssql: the database online' 1 "$(printed mssql_databases online "database=$db")"
        check 'mssql: in full recovery' yes "$(grep -h " out metric recovery 1 database=$db model=full" "$root"/logs/jobs/mssql_databases/*.log > /dev/null && echo yes || echo no)"
        check 'mssql: checked today' 0 "$(printed mssql_health checkdb_age_days "database=$db")"
        check 'mssql: its full backup just taken' yes "$(between mssql_backups full_age_seconds "database=$db" 0 3600)"
        check 'mssql: and its log backup' yes "$(between mssql_backups log_age_seconds "database=$db" 0 3600)"
        check 'mssql: no differential' -1 "$(printed mssql_backups diff_age_seconds "database=$db")"
        msa "USE msdb; IF USER_ID('vigil_monitor') IS NULL CREATE USER vigil_monitor FOR LOGIN vigil_monitor; GRANT SELECT ON dbo.sysjobs TO vigil_monitor; GRANT SELECT ON dbo.sysjobhistory TO vigil_monitor; GRANT SELECT ON dbo.sysjobactivity TO vigil_monitor; GRANT SELECT ON dbo.syssessions TO vigil_monitor;" > /dev/null
        check 'mssql: agent runs with its grants' 0 "$(runs mssql_agent)"
        grep -h ' out metric ' "$root/logs/jobs/mssql_agent"/*.log | tail -n 6 | sed 's/^[^ ]* [^ ]* out /        /'
        check 'mssql: Agent jobs readable' 1 "$(printed mssql_agent readable)"
        check 'mssql: Agent running' 1 "$(printed mssql_status agent_running)"
        check 'mssql: the failed job seen' yes "$(between mssql_agent job_failed_24h job=vigil_it_failing 1 100)"
        check 'mssql: failures counted' yes "$(between mssql_agent failed_24h '' 1 1000)"
        msa "USE msdb; DROP USER vigil_monitor; EXEC dbo.sp_delete_job @job_name = N'vigil_it_failing';" > /dev/null
        kill "$hold" "$hold2" 2> /dev/null
        wait "$hold" "$hold2" 2> /dev/null
        hold='' hold2=''
    fi

    if [ -n "${VIGIL_IT_MSSQL_REPLICA_HOST-}" ]; then
        check 'mssql: the primary seen' 1 "$(printed mssql_replication primary 'replica=mssql-primary')"
        check 'mssql: the secondary connected' 1 "$(printed mssql_replication connected 'replica=mssql-secondary')"
        check 'mssql: healthy' 2 "$(printed mssql_replication health 'replica=mssql-secondary')"
        check 'mssql: its database synchronized' 2 "$(printed mssql_replication sync_state 'replica=mssql-secondary database=')"
        check 'mssql: its send queue' yes "$(between mssql_replication send_queue_bytes 'replica=mssql-secondary database=' 0 1e15)"
        set_env MSSQL_HOST "$VIGIL_IT_MSSQL_REPLICA_HOST"
        set_env MSSQL_PORT "${VIGIL_IT_MSSQL_REPLICA_PORT:-1433}"
        check 'mssql: replication runs on the secondary' 0 "$(runs mssql_replication)"
        grep -h ' out metric ' "$root/logs/jobs/mssql_replication"/*.log | tail -n 6 | sed 's/^[^ ]* [^ ]* out /        /'
        check 'mssql: a secondary' 0 "$(printed mssql_replication primary 'replica=mssql-secondary')"
        check 'mssql: its database, from its side' 2 "$(printed mssql_replication sync_state 'replica=mssql-secondary database=')"
        set_env MSSQL_HOST "$VIGIL_IT_MSSQL_HOST"
        set_env MSSQL_PORT "$mport"
    else
        printf '  SKIP  mssql: an availability group: set VIGIL_IT_MSSQL_REPLICA_HOST (compose.mssql.yaml)\n'
    fi

    if [ -n "${VIGIL_IT_MSSQL_CACERT-}" ]; then
        ca_env ''
        check 'mssql: a certificate it cannot trust fails the run' 2 "$(runs mssql_status)"
        check 'mssql: and says why' yes "$(said mssql_status 'certificate')"
        ca_env "$VIGIL_IT_MSSQL_CACERT"
    fi
    printf 'not-the-Password1' | vigil secret set MSSQL_MONITOR_PASSWORD --stdin > /dev/null
    check 'mssql: a wrong password fails the run' 2 "$(runs mssql_status)"
    check 'mssql: and says why' yes "$(said mssql_status 'Login failed')"
    printf '%s' "$VIGIL_IT_MSSQL_PASSWORD" | vigil secret set MSSQL_MONITOR_PASSWORD --stdin > /dev/null
    # Not config/: the secret store is there, and holds it by design.
    leaks=$(grep -rlF -- "$VIGIL_IT_MSSQL_PASSWORD" "$root/logs" "$root/metrics" "$root/state" "$root/spool" 2> /dev/null)
    check 'mssql: the password is written nowhere' '' "$(printf '%s' "$leaks" | sed "s#^$root/##" | tr '
' ' ' | sed 's/ $//')"

    set_env MSSQL_PORT 1
    check 'mssql: a server that is down still runs' 0 "$(runs mssql_status)"
    check 'mssql: and reads as up 0' 0 "$(printed mssql_status up)"
    before=$(grep -c ' out metric ' "$root"/logs/jobs/mssql_databases/*.log)
    check 'mssql: the other jobs succeed when it is down' 0 "$(runs mssql_databases)"
    check 'mssql: and say nothing' "$before" "$(grep -c ' out metric ' "$root"/logs/jobs/mssql_databases/*.log)"
    set_env MSSQL_PORT "$mport"
    runs mssql_status > /dev/null
fi

# --- kafka ------------------------------------------------------------------
if [ -z "${VIGIL_IT_KAFKA_BOOTSTRAP-}" ] || [ -z "${VIGIL_IT_KAFKA_PASSWORD-}" ] || [ -z "${VIGIL_IT_KAFKA_HOME-}" ]; then
    printf '  SKIP  kafka: set VIGIL_IT_KAFKA_BOOTSTRAP, VIGIL_IT_KAFKA_PASSWORD and VIGIL_IT_KAFKA_HOME\n'
elif [ -z "${JAVA_HOME-}" ] && ! command -v java > /dev/null 2>&1; then
    printf '  SKIP  kafka: java is not installed here\n'
else
    # The jobs have their cluster, password and CA from Vigil: never from this
    # test's own environment.
    unset KAFKA_BOOTSTRAP KAFKA_SECURITY KAFKA_SASL_MECHANISM KAFKA_USER KAFKA_PASSWORD KAFKA_CACERT KAFKA_CERT KAFKA_KEY KAFKA_CLIENT_CONFIG KAFKA_JMX KAFKA_TLS_ENDPOINTS
    printf 'kafka at %s\n' "$VIGIL_IT_KAFKA_BOOTSTRAP"
    kjobs='status quorum brokers replication reassignment consumers groups topics logdirs transactions config security features throughput requests jvm controller connections tls'
    kjobs_on() { vigil pack list | awk '$1 ~ /^kafka_/ { print $2 }' | sort | uniq -c | awk '{ print $2 "=" $1 }' | tr '\n' ' ' | sed 's/ $//'; }
    kbetween() { local v; v=$(printed "$1" "$2" "${3-}"); awk -v v="$v" -v a="$4" -v b="$5" 'BEGIN { print (v ~ /^-?[0-9]+(\.[0-9]+)?$/ && v + 0 >= a && v + 0 <= b) ? "yes" : "no [" v "]" }'; }
    ksaid() {
        local f rid
        f=$(ls "$root/logs/jobs/$1"/*.log | tail -n 1)
        rid=$(tail -n 1 "$f" | awk '{ print $2 }')
        grep " $rid " "$f" | grep -q -- "$2" && echo yes || echo no
    }
    kruns() { vigil run "$1" > "$work/out" 2>&1; echo $?; }
    check 'kafka: off until enabled' 'off=19' "$(kjobs_on)"
    out=$(vigil pack enable kafka 2>&1)
    check 'kafka: enabled' 0 "$?"
    printf '%s\n' "$out" | sed 's/^/        /'
    check 'kafka: its jobs are on' 'on=19' "$(kjobs_on)"
    check 'kafka: the password is a secret reference, in the jobs that log in' 14 "$(grep -c '^secret *= KAFKA_PASSWORD=secret:KAFKA_MONITOR_PASSWORD' "$root/config/vigil.config")"
    printf '%s' "$VIGIL_IT_KAFKA_PASSWORD" | vigil secret set KAFKA_MONITOR_PASSWORD --stdin > /dev/null
    set_env KAFKA_BOOTSTRAP "$VIGIL_IT_KAFKA_BOOTSTRAP"
    set_env KAFKA_HOME "$VIGIL_IT_KAFKA_HOME"
    set_env KAFKA_CACERT "${VIGIL_IT_KAFKA_CACERT-}"
    [ -n "${VIGIL_IT_KAFKA_JMX-}" ] && set_env KAFKA_JMX "$VIGIL_IT_KAFKA_JMX"
    check 'kafka: precheck is happy' 0 "$(vigil precheck > "$work/precheck" 2>&1; echo $?)"

    # Through the admin listener: a topic with messages, part of them read by a
    # group that then stops (lag), and a topic with a single replica.
    if [ -n "${VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP-}" ]; then
        # Names of this run's own, so a run after another on the same cluster
        # finds its own counts.
        kid=$$
        kadmin() { local t=$1; shift; "$VIGIL_IT_KAFKA_HOME/bin/$t.sh" --bootstrap-server "$VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP" "$@"; }
        kadmin kafka-topics --create --if-not-exists --topic vigil_it_orders_$kid --partitions 6 > /dev/null 2>&1
        kadmin kafka-topics --create --if-not-exists --topic vigil_it_single_$kid --partitions 1 --replication-factor 1 > /dev/null 2>&1
        "$VIGIL_IT_KAFKA_HOME/bin/kafka-producer-perf-test.sh" --topic vigil_it_orders_$kid --num-records 1000 --record-size 100 --throughput -1 \
            --producer-props "bootstrap.servers=$VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP" acks=all > /dev/null 2>&1
        kadmin kafka-console-consumer --topic vigil_it_orders_$kid --group vigil_it_billing_$kid --from-beginning --max-messages 300 > /dev/null 2>&1
        kworkload=yes
    else
        printf '  SKIP  kafka: a topic, messages and a group with lag: set VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP\n'
        kworkload=''
    fi
    for j in $kjobs; do
        check "kafka: $j runs" 0 "$(kruns "kafka_$j")"
        grep -h ' out metric ' "$root/logs/jobs/kafka_$j"/*.log | tail -n 8 | sed 's/^[^ ]* [^ ]* out /        /'
    done
    check 'kafka: up' 1 "$(printed kafka_status up)"
    check 'kafka: what it is' yes "$(grep -h ' out metric info 1 cluster_id=' "$root"/logs/jobs/kafka_status/*.log | grep -qE 'cluster_id=[A-Za-z0-9_-]+ kraft=(yes|no)$' && echo yes || echo no)"
    check 'kafka: its brokers' yes "$(kbetween kafka_status brokers '' 1 10000)"
    check 'kafka: none fenced' 0 "$(printed kafka_status brokers_fenced)"
    check 'kafka: every partition has a leader' 0 "$(printed kafka_replication offline)"
    check 'kafka: the topics it sees' yes "$(kbetween kafka_replication topics '' 1 1e9)"
    check 'kafka: the brokers it reads from' yes "$(kbetween kafka_logdirs dirs '' 1 1e6)"
    check 'kafka: data on disk' yes "$(kbetween kafka_logdirs broker_size_bytes '' 1 1e18)"
    check 'kafka: ACLs are checked' 1 "$(printed kafka_security authorizer)"
    check 'kafka: SCRAM users, counted' yes "$(kbetween kafka_security scram_users '' 1 1e9)"
    # Finalized features, metadata.version among them, are KRaft's: a
    # cluster on ZooKeeper has none.
    if grep -qh ' out metric info 1 cluster_id=.* kraft=no$' "$root"/logs/jobs/kafka_status/*.log; then
        check 'kafka: no finalized features on ZooKeeper' 0 "$(printed kafka_features features)"
    else
        check 'kafka: metadata.version named' yes "$(grep -h ' out metric metadata_version 1 version=' "$root"/logs/jobs/kafka_features/*.log | grep -q 'supported=' && echo yes || echo no)"
    fi
    # run-kafka.sh holds a transaction open: it is seen as ongoing.
    if [ -n "${VIGIL_IT_KAFKA_TXN-}" ]; then
        check 'kafka: a transaction held open, seen' yes "$(kbetween kafka_transactions ongoing '' 1 1e9)"
    fi
    check 'kafka: unclean leader election off' 0 "$(printed kafka_config unclean_leader_election)"
    check 'kafka: TLS on its listener' 1 "$(printed kafka_tls tls)"
    check 'kafka: its certificates trusted' 0 "$(grep -h ' out metric trusted ' "$root"/logs/jobs/kafka_tls/*.log | tail -n "$(printed kafka_tls endpoints)" | grep -c ' trusted 0 ')"
    if [ -n "$kworkload" ]; then
        check 'kafka: a group behind on a topic' 700 "$(printed kafka_consumers lag "group=vigil_it_billing_$kid topic=vigil_it_orders_$kid")"
        check 'kafka: messages written, counted' 1000 "$(printed kafka_topics messages_count topic=vigil_it_orders_$kid)"
        check 'kafka: the topic has 6 partitions' 6 "$(printed kafka_topics partitions topic=vigil_it_orders_$kid)"
        check 'kafka: a topic with one replica, seen' yes "$(kbetween kafka_topics rf1_topics '' 1 1e6)"
        check 'kafka: the group, empty now' yes "$(grep -h " out metric members 0 group=vigil_it_billing_$kid " "$root"/logs/jobs/kafka_groups/*.log > /dev/null && echo yes || echo no)"
    fi
    if [ -n "${VIGIL_IT_KAFKA_JMX-}" ]; then
        check 'kafka: JMX answers' yes "$(grep -h ' out metric jmx_up ' "$root"/logs/jobs/kafka_throughput/*.log | grep -q ' jmx_up 1 ' && ! grep -h ' out metric jmx_up 0 ' "$root"/logs/jobs/kafka_throughput/*.log | grep -q . && echo yes || echo no)"
        check 'kafka: messages in, counted' yes "$(grep -h ' out metric messages_in_count ' "$root"/logs/jobs/kafka_throughput/*.log | awk '$6 > 0 { f = 1 } END { print f ? "yes" : "no" }')"
        check 'kafka: one active controller' 1 "$(grep -h ' out metric active_controller ' "$root"/logs/jobs/kafka_controller/*.log | tail -n 20 | awk '{ s += $6 } END { print s }')"
        check 'kafka: heap read' yes "$(grep -h ' out metric heap_used_bytes ' "$root"/logs/jobs/kafka_jvm/*.log | awk '$6 > 0 { f = 1 } END { print f ? "yes" : "no" }')"
        check 'kafka: logins counted' yes "$(grep -h ' out metric logins_count ' "$root"/logs/jobs/kafka_connections/*.log | awk '$6 > 0 { f = 1 } END { print f ? "yes" : "no" }')"
    fi

    # Failures: a certificate it cannot trust and a wrong password fail the run
    # and say why; a cluster that is down reads as up 0.
    if [ -n "${VIGIL_IT_KAFKA_CACERT-}" ]; then
        set_env KAFKA_CACERT ''
        check 'kafka: a certificate it cannot trust fails the run' 2 "$(kruns kafka_status)"
        check 'kafka: and says why' yes "$(ksaid kafka_status 'certificate')"
        check 'kafka: the certificate is still read' 0 "$(kruns kafka_tls)"
        check 'kafka: and reported untrusted' yes "$(ksaid kafka_tls ' trusted 0 ')"
        set_env KAFKA_CACERT "$VIGIL_IT_KAFKA_CACERT"
    fi
    printf 'not-the-password' | vigil secret set KAFKA_MONITOR_PASSWORD --stdin > /dev/null
    check 'kafka: a wrong password fails the run' 2 "$(kruns kafka_status)"
    check 'kafka: and says why' yes "$(ksaid kafka_status 'refused the login')"
    printf '%s' "$VIGIL_IT_KAFKA_PASSWORD" | vigil secret set KAFKA_MONITOR_PASSWORD --stdin > /dev/null
    # Not config/: the secret store is there, and holds it by design.
    leaks=$(grep -rlF -- "$VIGIL_IT_KAFKA_PASSWORD" "$root/logs" "$root/metrics" "$root/state" "$root/spool" 2> /dev/null)
    check 'kafka: the password is written nowhere' '' "$(printf '%s' "$leaks" | sed "s#^$root/##" | tr '\n' ' ' | sed 's/ $//')"
    check 'kafka: no client configuration is left behind' '' "$(ls -d "${TMPDIR:-/tmp}"/vigil-kafka.* 2> /dev/null)"
    set_env KAFKA_BOOTSTRAP 'localhost:1'
    check 'kafka: a cluster that is down still runs' 0 "$(kruns kafka_status)"
    check 'kafka: and reads as up 0' 0 "$(printed kafka_status up)"
    before=$(grep -c ' out metric ' "$root"/logs/jobs/kafka_replication/*.log)
    check 'kafka: the other jobs succeed when it is down' 0 "$(kruns kafka_replication)"
    check 'kafka: and say nothing' "$before" "$(grep -c ' out metric ' "$root"/logs/jobs/kafka_replication/*.log)"
    set_env KAFKA_BOOTSTRAP "$VIGIL_IT_KAFKA_BOOTSTRAP"
    kruns kafka_status > /dev/null
    kruns kafka_consumers > /dev/null
fi

# --- jvm --------------------------------------------------------------------
if [ -z "${VIGIL_IT_JVM_TARGETS-}" ] || [ -z "${VIGIL_IT_JVM_PASSWORD-}" ]; then
    printf '  SKIP  jvm: set VIGIL_IT_JVM_TARGETS and VIGIL_IT_JVM_PASSWORD (scripts/run-jvm.sh sets them up)\n'
elif [ -z "${JAVA_HOME-}" ] && ! command -v java > /dev/null 2>&1; then
    printf '  SKIP  jvm: java is not installed here\n'
else
    # The jobs have their JVMs, password and CA from Vigil: never from this
    # test's own environment.
    unset JVM_TARGETS JVM_JMX_USER JVM_JMX_PASSWORD JVM_CACERT JVM_MBEANS JVM_DUMP_DIRS
    printf 'jvm: %s\n' "$VIGIL_IT_JVM_TARGETS"
    jjobs_on() { vigil pack list | awk '$1 ~ /^jvm_/ { print $2 }' | sort | uniq -c | awk '{ print $2 "=" $1 }' | tr '\n' ' ' | sed 's/ $//'; }
    # The value job jvm_$1's last run printed for metric $2 of JVM $3 (with
    # text $4 in its line, if given).
    jval() { grep -h " out metric $2 " "$root/logs/jobs/jvm_$1"/*.log 2> /dev/null | grep -E " jvm=$3( |\$)" | grep -- "${4-}" | tail -n 1 | awk '{ print $6 }'; }
    jbetween() { local v; v=$(jval "$1" "$2" "$3" "${6-}"); awk -v v="$v" -v a="$4" -v b="$5" 'BEGIN { print (v ~ /^-?[0-9]+(\.[0-9]+)?$/ && v + 0 >= a && v + 0 <= b) ? "yes" : "no [" v "]" }'; }
    jsaid() {
        local f rid
        f=$(ls "$root/logs/jobs/jvm_$1"/*.log | tail -n 1)
        rid=$(tail -n 1 "$f" | awk '{ print $2 }')
        grep " $rid " "$f" | grep -q -- "$2" && echo yes || echo no
    }
    jrun() { vigil run "jvm_$1" > "$work/out" 2>&1; echo $?; }
    check 'jvm: off until enabled' 'off=41' "$(jjobs_on)"
    out=$(vigil pack enable jvm 2>&1)
    check 'jvm: enabled' 0 "$?"
    printf '%s\n' "$out" | sed 's/^/        /'
    check 'jvm: its jobs are on' 'on=41' "$(jjobs_on)"
    check 'jvm: no secret line until JMX asks for one' 0 "$(grep -c '^secret *= JVM_JMX_PASSWORD=' "$root/config/vigil.config")"
    # JMX with a password: a secret line on each job, as packs/README.md says.
    awk '{ print } /^env *= JVM_CACERT=/ { print "secret      = JVM_JMX_PASSWORD=secret:JVM_JMX_PASSWORD" }' "$root/config/vigil.config" > "$work/cfg" &&
        cat "$work/cfg" > "$root/config/vigil.config"
    check 'jvm: the password is a secret reference, on every job' 41 "$(grep -c '^secret *= JVM_JMX_PASSWORD=secret:JVM_JMX_PASSWORD' "$root/config/vigil.config")"
    printf '%s' "$VIGIL_IT_JVM_PASSWORD" | vigil secret set JVM_JMX_PASSWORD --stdin > /dev/null
    set_env JVM_TARGETS "$VIGIL_IT_JVM_TARGETS"
    set_env JVM_JMX_USER operator
    set_env JVM_CACERT "${VIGIL_IT_JVM_CACERT-}"
    set_env JVM_DUMP_DIRS "${VIGIL_IT_JVM_DUMPS-}"
    check 'jvm: precheck is happy' 0 "$(vigil precheck > "$work/precheck" 2>&1; echo $?)"

    jlist=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$repo/packs/jvm/pack.config")
    failed=''
    for j in $jlist; do
        [ "$(jrun "$j")" = 0 ] || failed="$failed $j"
    done
    check 'jvm: every job runs' '' "$failed"
    for j in $failed; do sed 's/^/        /' "$root/logs/jobs/jvm_$j"/*.log | tail -n 4; done

    # Each tier reaches the JVMs it should.
    for v in j8 j11 j17 j21 j25 nojmx host plain; do check "jvm: $v is up" 1 "$(jval status up "$v")"; done
    for v in j8 j11 j17 j21 j25 host; do check "jvm: $v answers over JMX" 1 "$(jval status tier_jmx "$v")"; done
    for v in j8 j11 j17 j21 j25 nojmx host plain; do check "jvm: $v's process is found" 1 "$(jval process running "$v")"; done
    check "jvm: the counters of a JVM of this account are read" 1 "$(jval status tier_counters plain)"
    check "jvm: and of one in a container, as this account" 1 "$(jval status tier_counters j21)"
    check "jvm: a JVM run as root keeps its counters from this account" 0 "$(jval status tier_counters nojmx)"
    check 'jvm: Java 8 says what it is' yes "$(grep -h ' out metric info 1 jvm=j8 ' "$root"/logs/jobs/jvm_status/*.log | tail -n 1 | grep -q 'version=1\.8\.' && echo yes || echo no)"
    check 'jvm: its feature release' 8 "$(jval release_age feature_version j8)"
    check 'jvm: Java 25 too' 25 "$(jval release_age feature_version j25)"

    # Memory.
    check 'jvm: the heap, over JMX' yes "$(jbetween heap used_percent j21 0.1 100)"
    check 'jvm: and from the counters alone' yes "$(jbetween heap used_bytes plain 1 1e12)"
    check 'jvm: old gen after a collection' yes "$(jbetween pools after_gc_bytes j21 1 1e12 G1_Old_Gen)"
    check 'jvm: metaspace' yes "$(jbetween metaspace metaspace_used_bytes j17 1 1e12)"
    check 'jvm: direct buffers leaking' yes "$(jbetween buffers used_bytes j11 50000000 1e12 pool=direct)"
    check 'jvm: native memory, where it is tracked' 1 "$(jval native tracking j11)"
    check 'jvm: and not where it is not' 0 "$(jval native tracking j21)"
    check 'jvm: memory outside the heap' yes "$(jbetween native_overhead outside_heap_bytes j11 1 1e12)"

    # Collection.
    check 'jvm: collections, over JMX' yes "$(jbetween gc collections_total j8 1 1e12)"
    check 'jvm: and from the counters' yes "$(jbetween gc collections_total plain 1 1e12)"
    check "jvm: ZGC's concurrent cycles apart from its pauses" yes "$(jbetween gc_cycles concurrent_cycles j17 1 1e12)"
    check 'jvm: the last collection' yes "$(jbetween gc_last duration_ms j21 0 1e9)"
    check 'jvm: allocation, per second' yes "$(jbetween allocation allocation_bytes_per_second j17 1 1e13)"
    check 'jvm: pauses in a Java 8 GC log' yes "$(jbetween gclog pauses j8 1 1e9)"
    check 'jvm: in a ZGC log' yes "$(jbetween gclog pauses j17 1 1e9)"
    check 'jvm: in a G1 log' yes "$(jbetween gclog pauses j21 1 1e9)"
    check "jvm: G1's humongous allocations, from its log" yes "$(jbetween gclog_detail humongous_allocations_in_log j21 1 1e9)"
    check 'jvm: promotion, from the counters' yes "$(jbetween promotion tenuring_threshold plain 0 100)"

    # Threads.
    check 'jvm: a deadlock, in a container' 2 "$(jval deadlocks deadlocked j21)"
    check 'jvm: and on this machine' 2 "$(jval deadlocks deadlocked host)"
    check 'jvm: and none where there is none' 0 "$(jval deadlocks deadlocked j17)"
    check 'jvm: the deadlocked threads, named' yes "$(grep -h ' out metric thread 1 jvm=j21 thread=deadlock-a waits_on=java.lang.Object' "$root"/logs/jobs/jvm_deadlocks/*.log | grep -q 'held_by=deadlock-b' && echo yes || echo no)"
    check 'jvm: leaked threads, over JMX' yes "$(jbetween threads live j8 40 1e6)"
    check 'jvm: and from the counters' yes "$(jbetween threads live plain 40 1e6)"
    check 'jvm: threads blocked on a lock' yes "$(jbetween contention blocked j17 1 100)"
    check 'jvm: the busy thread, by name' yes "$(jbetween hot_threads cpu_percent j25 1 1000 thread=busy-loop)"
    check "jvm: virtual threads' carriers" yes "$(jbetween virtual_threads carriers j21 1 1000)"

    # The runtime.
    check 'jvm: classloaders leaking' yes "$(jbetween classloaders loaders j11 10 1e6)"
    check 'jvm: classes, from the counters' yes "$(jbetween classes loaded plain 100 1e7)"
    check 'jvm: the JIT' yes "$(jbetween jit compile_seconds j21 0 1e6)"
    check 'jvm: safepoints, from the counters' yes "$(jbetween safepoints safepoints plain 1 1e12)"
    check 'jvm: Flight Recorder there' 1 "$(jval jfr available j17)"
    check 'jvm: MBeans of your own' yes "$(jbetween mbeans value j21 1 1e6 attribute=ThreadCount)"

    # Trouble, settings and security.
    check 'jvm: a crash report' yes "$(jbetween crashes crash_reports_day j17 1 100)"
    check 'jvm: a heap dump, after out-of-memory' yes "$(jbetween oom heap_dumps_day j21 1 100)"
    check 'jvm: heap dump on out-of-memory, set' 1 "$(jval flags heap_dump_on_oom j21)"
    check 'jvm: and not set' 0 "$(jval flags heap_dump_on_oom j17)"
    check 'jvm: a debugger listening beyond this machine' 1 "$(jval security debug_agent_remote j25)"
    check 'jvm: and none' 0 "$(jval security debug_agent j21)"
    check 'jvm: JMX without TLS' 1 "$(jval security jmx_no_tls j8)"
    check 'jvm: JMX with a password' 0 "$(jval security jmx_no_password j8)"
    check 'jvm: the JVMs on this machine' yes "$(grep -h ' out metric jvms ' "$root"/logs/jobs/jvm_discovery/*.log | tail -n 1 | awk '{ print ($6 >= 8) ? "yes" : "no [" $6 "]" }')"

    # A readonly JMX user reads attributes, and is told what it may not run.
    set_env JVM_JMX_USER monitor
    check 'jvm: a readonly user still runs' 0 "$(jrun deadlocks)"
    check 'jvm: and is told an operation needs readwrite' yes "$(jsaid deadlocks 'needs readwrite access')"
    check 'jvm: and reads attributes' yes "$(jbetween heap used_bytes j21 1 1e12)"
    set_env JVM_JMX_USER operator

    # A wrong password and a certificate it cannot trust fail the run, and say why.
    printf 'not-the-password' | vigil secret set JVM_JMX_PASSWORD --stdin > /dev/null
    check 'jvm: a wrong password fails the run' 1 "$(jrun heap)"
    check 'jvm: and says why' yes "$(jsaid heap 'refused the login')"
    printf '%s' "$VIGIL_IT_JVM_PASSWORD" | vigil secret set JVM_JMX_PASSWORD --stdin > /dev/null
    if [ -n "${VIGIL_IT_JVM_CACERT-}" ]; then
        set_env JVM_CACERT ''
        check 'jvm: a certificate it cannot trust fails the run' 1 "$(jrun heap)"
        check 'jvm: and says why' yes "$(jsaid heap 'certificate is not trusted')"
        set_env JVM_CACERT "$VIGIL_IT_JVM_CACERT"
    fi

    # A JMX port that does not answer, and a JVM that is not running.
    set_env JVM_TARGETS 'gone: jmx=127.0.0.1:1; absent: main=-Dvigil.it=nowhere'
    check 'jvm: JMX that does not answer still runs' 0 "$(jrun status)"
    check 'jvm: and reads as jmx_up 0' 0 "$(jval status jmx_up gone)"
    check 'jvm: a JVM not running reads as running 0' 0 "$(printf '%s' "$(jrun process)" > /dev/null; jval process running absent)"
    set_env JVM_TARGETS "$VIGIL_IT_JVM_TARGETS"
    vigil run jvm_heap > /dev/null 2>&1
    check 'jvm: the password is written nowhere' '' "$(grep -rlF -- "$VIGIL_IT_JVM_PASSWORD" "$root/logs" "$root/state" "$root/spool" "$root/metrics" "$root/config/vigil.config" 2> /dev/null)"
fi

# --- nginx ------------------------------------------------------------------
if [ -z "${VIGIL_IT_NGINX_URL-}" ]; then
    printf '  SKIP  nginx: set VIGIL_IT_NGINX_URL\n'
else
    printf 'nginx at %s\n' "$VIGIL_IT_NGINX_URL"
    vigil pack enable nginx > "$work/out" 2>&1
    check 'nginx: enabled' 0 "$?"
    set_env NGINX_STATUS_URL "$VIGIL_IT_NGINX_URL"
    # Requests for it to count.
    base=${VIGIL_IT_NGINX_URL%/*}
    for _ in 1 2 3 4 5; do curl -s -o /dev/null "$base/"; done
    vigil run nginx_status > "$work/out" 2>&1
    check 'nginx: status runs' 0 "$?"
    grep -h ' out metric ' "$root/logs/jobs/nginx_status"/*.log | sed 's/^[^ ]* [^ ]* out /        /'
    check 'nginx: up' 1 "$(printed nginx_status up)"
    check 'nginx: requests counted' yes "$([ "$(printed nginx_status requests_count)" -ge 5 ] 2> /dev/null && echo yes || echo no)"
    check 'nginx: connections seen' yes "$([ "$(printed nginx_status active_connections)" -ge 1 ] 2> /dev/null && echo yes || echo no)"
    check 'nginx: none dropped' 0 "$(printed nginx_status dropped_count)"
    set_env NGINX_STATUS_URL 'http://127.0.0.1:1/nginx_status'
    vigil run nginx_status > "$work/out" 2>&1
    check 'nginx: a server that is down still runs' 0 "$?"
    check 'nginx: and reads as up 0' 0 "$(printed nginx_status up)"
fi

# What ran reaches the backend.
vigil supervise --once > /dev/null 2>&1
sleep 3
vigil supervise --once > /dev/null 2>&1
if [ -n "${VIGIL_IT_PG_HOST-}" ] && [ -n "${VIGIL_IT_PG_PASSWORD-}" ] && command -v psql > /dev/null 2>&1; then
    check 'postgres: metrics reach the backend' yes "$(grep -q '^postgres_connections{' "$root/metrics/vigil.prom" && echo yes || echo no)"
    check 'postgres: the 1.2.0 jobs reach it too' yes "$(grep -q '^postgres_activity_blocked{' "$root/metrics/vigil.prom" && grep -q '^postgres_wraparound_xid_pct{.*database="postgres"' "$root/metrics/vigil.prom" && echo yes || echo no)"
    check 'postgres: sizes reach the backend' yes "$(grep -q '^postgres_database_size_bytes{.*database="postgres"' "$root/metrics/vigil.prom" && echo yes || echo no)"
    check 'postgres: the password is written nowhere' '' "$(grep -rlF -- "$VIGIL_IT_PG_PASSWORD" "$root/logs" "$root/state" "$root/spool" "$root/metrics" "$root/config/vigil.config" 2> /dev/null)"
fi
if [ -n "${VIGIL_IT_MYSQL_HOST-}" ] && [ -n "${VIGIL_IT_MYSQL_PASSWORD-}" ] && { command -v mysql || command -v mariadb; } > /dev/null 2>&1; then
    check 'mysql: metrics reach the backend' yes "$(grep -q '^mysql_connections{' "$root/metrics/vigil.prom" && grep -q '^mysql_activity_waiting{' "$root/metrics/vigil.prom" && echo yes || echo no)"
    check 'mysql: the password is written nowhere' '' "$(grep -rlF -- "$VIGIL_IT_MYSQL_PASSWORD" "$root/logs" "$root/state" "$root/spool" "$root/metrics" "$root/config/vigil.config" 2> /dev/null)"
fi
if [ -n "${VIGIL_IT_REDIS_HOST-}" ] && [ -n "${VIGIL_IT_REDIS_PASSWORD-}" ] && { command -v redis-cli || command -v valkey-cli; } > /dev/null 2>&1; then
    check 'redis: metrics reach the backend' yes "$(grep -q '^redis_up{' "$root/metrics/vigil.prom" && grep -q '^redis_memory_used_bytes{' "$root/metrics/vigil.prom" && grep -q '^redis_keyspace_keys{.*db="db0"' "$root/metrics/vigil.prom" && echo yes || echo no)"
    check 'redis: the password is written nowhere' '' "$(grep -rlF -- "$VIGIL_IT_REDIS_PASSWORD" "$root/logs" "$root/state" "$root/spool" "$root/metrics" "$root/config/vigil.config" 2> /dev/null)"
fi
if [ -n "${VIGIL_IT_KAFKA_BOOTSTRAP-}" ] && [ -n "${VIGIL_IT_KAFKA_PASSWORD-}" ] && [ -n "${VIGIL_IT_KAFKA_HOME-}" ]; then
    check 'kafka: metrics reach the backend' yes "$(grep -q '^kafka_up{' "$root/metrics/vigil.prom" && grep -q '^kafka_consumer_total_lag{' "$root/metrics/vigil.prom" && echo yes || echo no)"
fi
if [ -n "${VIGIL_IT_JVM_TARGETS-}" ] && [ -n "${VIGIL_IT_JVM_PASSWORD-}" ]; then
    check 'jvm: metrics reach the backend' yes "$(grep -q '^jvm_heap_used_bytes{' "$root/metrics/vigil.prom" && grep -q '^jvm_deadlocks_deadlocked{' "$root/metrics/vigil.prom" && echo yes || echo no)"
fi
if [ -n "${VIGIL_IT_NGINX_URL-}" ]; then
    check 'nginx: metrics reach the backend' yes "$(grep -q '^nginx_requests_count{' "$root/metrics/vigil.prom" && echo yes || echo no)"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
