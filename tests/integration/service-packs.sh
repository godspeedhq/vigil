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
# Integration test: the service packs (packs/postgres, packs/nginx) against
# real servers, on Linux and macOS. The twin of Service-Packs.ps1, which
# tests postgres on Windows (nginx has no Windows script).
#
# A pack is tested only when its server is given, and SKIPped otherwise:
#   VIGIL_IT_PG_HOST, VIGIL_IT_PG_PORT   a PostgreSQL server (default port 5432)
#   VIGIL_IT_PG_PASSWORD                 its vigil_monitor role's password; the
#                                        role has pg_monitor and nothing more
#   VIGIL_IT_PG_SUPER_PASSWORD           optional: its postgres superuser's, to
#                                        make dead rows and an unused slot
#   VIGIL_IT_PG_REPLICA_HOST, _PORT      optional: a streaming replica of it
#                                        (compose.replication.yaml)
#   VIGIL_IT_NGINX_URL                   an nginx stub_status page
# CI starts both as service containers; tests/integration/backends has
# them for a machine of your own (scripts/run-pack.sh).
#
# For each pack: it is off until enabled; vigil pack enable puts its jobs in
# the configuration; each job runs and reports what the server says; a
# server that is down reads as up 0; and its metrics reach a backend. For
# postgres also: a long query and transaction are seen, a session idle in
# its transaction and one blocked behind its lock, a sort spilled to disk,
# dead rows and an unused replication slot, a replica from both sides; the
# other jobs say nothing while the server is down; a wrong password fails
# the run and says why, and the password is written nowhere.
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
    # The test's own psql, holding a transaction open.
    [ -n "$hold" ] && kill "$hold" 2> /dev/null
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
for p in postgres nginx; do
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
if [ -n "${VIGIL_IT_NGINX_URL-}" ]; then
    check 'nginx: metrics reach the backend' yes "$(grep -q '^nginx_requests_count{' "$root/metrics/vigil.prom" && echo yes || echo no)"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
