#!/usr/bin/env bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# run-clickhouse.sh - the clickhouse pack against a real cluster in trouble
# on purpose, and an older single server, with its evidence kept like the
# other runs'.
#
#   scripts/run-clickhouse.sh
#
# It starts compose.clickhouse.yaml: 26.8, two replicas of one shard with
# ClickHouse Keeper, and 25.8, one server. As the admin (default), on each:
# the read-only user the pack asks for (vigil), and on ch1 one with no
# grant. In 26.8: a replicated table; a table whose limits are low (10
# parts delay an insert, 20 refuse it) with its merges stopped, then 25
# inserts of one row each; a part of it detached; a mutation that fails on
# every row; statements that fail; a query that runs for minutes; ch2's
# fetches stopped while ch1 takes inserts. Every job is run against ch1,
# ch2 and 25.8, and what it reads is checked; then
# tests/integration/service-packs.sh runs the pack through Vigil. Then ch2
# stops (a replica missing), Keeper stops (the replicas read-only), a part
# of 25.8's is damaged while it is stopped (detached as broken when it
# starts), 25.8 stops (up 0); a wrong password, and the user with no grant.
# The passwords are made here, into this run's own folder, and kept out of
# the evidence. VIGIL_IT_CH_HOLD (below) keeps the cluster up for other
# machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: ClickHouse runs in containers'
for p in curl jq openssl; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
file=compose.clickhouse.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-ch-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-ch --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }

(umask 077 && for u in admin vigil nogrant sysonly; do openssl rand -hex 16 > "$work/$u.pw"; done)
export CH_ADMIN_PASSWORD; CH_ADMIN_PASSWORD=$(cat "$work/admin.pw")
slow=''
trap '[ -z "$slow" ] || kill "$slow" 2> /dev/null; dc down -v > /dev/null 2>&1; evidence_save "$(cat "$work/admin.pw")" "$(cat "$work/vigil.pw")" "$(cat "$work/nogrant.pw")" "$(cat "$work/sysonly.pw")"; rm -rf "$work"' EXIT
evidence_start pack-clickhouse "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/clickhouse/linux

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'ClickHouse would not start'; }
# sql <port> <statement>: as the admin, its login on curl's standard input.
sql() {
    printf '%s' "$2" > "$work/q"
    printf 'header = "X-ClickHouse-User: default"\nheader = "X-ClickHouse-Key: %s"\n' "$CH_ADMIN_PASSWORD" |
        curl -sS -m 120 -K - --data-binary "@$work/q" "http://127.0.0.1:$1/"
}
# as <user> <port> <statement>: the same as another user; its HTTP status.
as() {
    printf '%s' "$3" > "$work/q"
    printf 'header = "X-ClickHouse-User: %s"\nheader = "X-ClickHouse-Key: %s"\n' "$1" "$(cat "$work/$1.pw")" |
        curl -sS -m 30 -K - --data-binary "@$work/q" -o "$work/as.out" -w '%{http_code}' "http://127.0.0.1:$2/"
}
for p in 18123 18124 18125; do
    for _ in $(seq 1 60); do [ "$(sql $p 'SELECT 1' 2> /dev/null)" = 1 ] && break; sleep 2; done
    [ "$(sql $p 'SELECT 1' 2> /dev/null)" = 1 ] || { dc logs --tail 20; die "ClickHouse on $p did not answer"; }
done
for _ in $(seq 1 30); do [ "$(sql 18123 "SELECT count() > 0 FROM system.zookeeper WHERE path = '/'" 2> /dev/null)" = 1 ] && break; sleep 2; done
printf 'clickhouse  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }
said() { grep -q -- "$2" "$work/$1.out" && echo yes || echo no; }
# run <job> [<label>]: the job's script, its output shown and kept.
run() {
    printf '\n$ bash packs/clickhouse/linux/%s.sh%s\n' "$1" "${2:+   ($2)}"
    bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    cat "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err"
}
quiet() { bash "$pack/$1.sh" > "$work/$1.out" 2> /dev/null; }
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/clickhouse/pack.config")
use() { export CLICKHOUSE_URL=http://127.0.0.1:$1 CLICKHOUSE_USER=vigil CLICKHOUSE_PASSWORD; CLICKHOUSE_PASSWORD=$(cat "$work/vigil.pw"); }

say "The users, as the admin: vigil, read-only, on each server; nogrant and sysonly on ch1."
for p in 18123 18124 18125; do
    sql $p "CREATE USER vigil IDENTIFIED WITH sha256_password BY '$(cat "$work/vigil.pw")' SETTINGS readonly = 1" || die "cannot make vigil on $p"
    sql $p 'GRANT SELECT ON system.*, SHOW TABLES ON *.* TO vigil' || die "cannot grant vigil on $p"
done
sql 18123 "CREATE USER nogrant IDENTIFIED WITH sha256_password BY '$(cat "$work/nogrant.pw")' SETTINGS readonly = 1" || die 'cannot make nogrant'
sql 18123 "CREATE USER sysonly IDENTIFIED WITH sha256_password BY '$(cat "$work/sysonly.pw")' SETTINGS readonly = 1" || die 'cannot make sysonly'
sql 18123 'GRANT SELECT ON system.* TO sysonly' || die 'cannot grant sysonly'
echo "users    vigil: readonly = 1, SELECT ON system.*, SHOW TABLES ON *.*; nogrant: readonly = 1, no grant; sysonly: readonly = 1, SELECT ON system.* alone"
check 'vigil may not write: the server refuses it' yes "$(c=$(as vigil 18123 'CREATE TABLE default.x (a Int8) ENGINE = Memory'); [ "$c" != 200 ] && echo yes || echo "no [$c]")"
sed 's/^/        /' "$work/as.out"

say "26.8 in trouble on purpose, as the admin."
# A query that runs for minutes: one row a second, 300 rows.
printf 'header = "X-ClickHouse-User: default"\nheader = "X-ClickHouse-Key: %s"\n' "$CH_ADMIN_PASSWORD" |
    curl -sS -m 330 -K - --data-binary 'SELECT sleepEachRow(1) FROM numbers(300) SETTINGS max_block_size = 1' \
        'http://127.0.0.1:18123/?query_id=vigil-it-slow' > /dev/null 2>&1 &
slow=$!
started=$(date +%s)
echo 'query    vigil-it-slow: SELECT sleepEachRow(1) FROM numbers(300), one row a block'
sql 18123 'CREATE DATABASE app ON CLUSTER c' > /dev/null || die 'cannot make app'
sql 18123 "CREATE TABLE app.events ON CLUSTER c (t DateTime DEFAULT now(), k UInt32, v String)
    ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/app/events', '{replica}') ORDER BY k" > /dev/null || die 'cannot make app.events'
sql 18123 "INSERT INTO app.events (k, v) SELECT number, 'x' FROM numbers(10000)"
echo 'table    app.events: ReplicatedMergeTree on ch1 and ch2, 10,000 rows'
sql 18123 'CREATE TABLE app.tiny (k UInt32) ENGINE = MergeTree ORDER BY k
    SETTINGS parts_to_delay_insert = 10, parts_to_throw_insert = 20, max_delay_to_insert = 1' || die 'cannot make app.tiny'
sql 18123 'SYSTEM STOP MERGES app.tiny'
refused=0
for i in $(seq 1 25); do sql 18123 "INSERT INTO app.tiny VALUES ($i)" 2>&1 | grep -q 'TOO_MANY_PARTS' && refused=$((refused + 1)); done
echo "table    app.tiny: merges stopped; 25 inserts of one row: 10 parts delay one, 20 refuse it ($refused refused)"
part=$(sql 18123 "SELECT name FROM system.parts WHERE database = 'app' AND table = 'tiny' AND active ORDER BY name LIMIT 1")
sql 18123 "ALTER TABLE app.tiny DETACH PART '$part'"
echo "part     app.tiny $part: detached by hand"
sql 18123 "CREATE TABLE app.m (k UInt32, v String) ENGINE = MergeTree ORDER BY k"
sql 18123 "INSERT INTO app.m SELECT number, 'x' FROM numbers(1000)"
sql 18123 'ALTER TABLE app.m UPDATE v = toString(throwIf(k >= 0)) WHERE 1'
echo 'mutation app.m: UPDATE v = toString(throwIf(k >= 0)), which fails on every row'
for i in 1 2 3; do sql 18123 'SELECT * FROM app.nope' > /dev/null 2>&1; done
echo 'sql      three SELECTs from a table that is not there'
# ch2 stops fetching: what ch1 takes waits in ch2's queue.
sql 18124 'SYSTEM STOP FETCHES app.events'
for i in 1 2 3 4 5; do sql 18123 "INSERT INTO app.events (k, v) SELECT number, 'y' FROM numbers(100)"; done
echo 'ch2      SYSTEM STOP FETCHES app.events; then 5 inserts into ch1'
for _ in $(seq 1 30); do [ "$(sql 18123 "SELECT latest_fail_reason != '' FROM system.mutations WHERE table = 'm' AND NOT is_done")" = 1 ] && break; sleep 2; done
wait_s=$((started + 65 - $(date +%s)))
[ "$wait_s" -le 0 ] || { printf '(waiting %s s: the query has run for over 60 s)\n' "$wait_s"; sleep "$wait_s"; }

say "26.8, ch1: every job, as the pack's scripts print it, as vigil."
use 18123
for j in $jobs; do run "$j"; done
say "26.8, ch1: what they read."
for j in $jobs; do check "ch1: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
check 'ch1: up, its version' '1 yes' "$(val status up '') $(has status info 'version=26\.8\.')"
check 'ch1: its memory, and its limit (90% of the 1 GB cgroup)' 'yes 966367641' "$(least status memory_bytes '' 1) $(val status memory_limit_bytes '')"
check 'ch1: the partition with most parts: app.tiny, 19 after one detached' yes "$(least status max_parts_in_partition '' 19)"
check 'ch1: inserts delayed, and refused' 'yes yes' "$(least status inserts_delayed_count '' 1) $(least status inserts_rejected_count '' 1)"
check 'ch1: the refused inserts are as many as the server refused' "$refused" "$(val status inserts_rejected_count '')"
check 'ch1: failed queries counted: all, select, insert' 'yes yes yes' "$(least status failed_queries_count 'kind=all' 4) $(least status failed_queries_count 'kind=select' 3) $(least status failed_queries_count 'kind=insert' 1)"
check 'ch1: one Keeper session, no replica read-only' '1 0' "$(val status keeper_sessions '') $(val status readonly_replicas '')"
check 'ch1: app.tiny first, by its parts' yes "$(grep '^metric table_parts ' "$work/tables.out" | head -n 1 | grep -q 'table=app.tiny' && echo yes || echo no)"
check 'ch1: app.tiny: 19 parts in one partition' '19 1 19' "$(val tables table_parts 'table=app.tiny') $(val tables table_partitions 'table=app.tiny') $(val tables table_max_parts 'table=app.tiny')"
check 'ch1: app.events: its rows' yes "$(least tables table_rows 'table=app.events' 10500)"
check 'ch1: one replicated table, two replicas, both active' '1 2 2' "$(val replication replicated '') $(val replication table_replicas 'table=app.events') $(val replication table_replicas_active 'table=app.events')"
check 'ch1: none read-only, none missing' '0 0' "$(val replication readonly '') $(val replication replicas_missing '')"
# log_pointer is one past the last entry read: up to date, it is 0, not -1.
check 'ch1: up to date: no log entry behind' 0 "$(val replication table_log_behind 'table=app.events')"
check 'ch1: the failing mutation' '1 1 1' "$(val merges mutations '') $(val merges mutations_failing '') $(val merges mutation_failing 'table=app.m')"
check 'ch1: and its parts still to do' yes "$(least merges mutation_parts_to_do 'table=app.m' 1)"
check 'ch1: the part detached by hand' 1 "$(val merges detached_parts 'reason=manual')"
check 'ch1: broken and unexpected: none, but read' '0 0' "$(val merges detached_parts 'reason=broken') $(val merges detached_parts 'reason=unexpected')"
check 'ch1: a disk, how full' 'yes yes' "$(least disks disks '' 1) $(has disks used_pct 'disk=default')"
check 'ch1: the slow query, over 60 s' 'yes yes yes' "$(least queries slow '' 1) $(least queries longest_seconds '' 60) $(has queries query_seconds 'user=default kind=Select id=vigil-it-slow')"
check 'ch1: its own SELECT is not counted' no "$(has queries query_seconds 'user=vigil')"
check 'ch1: the errors, by name' 'yes yes' "$(least queries errors_count 'name=UNKNOWN_TABLE' 3) $(least queries errors_count 'name=TOO_MANY_PARTS' 1)"
CLICKHOUSE_MOST=2 bash "$pack/tables.sh" > "$work/most.out" 2>&1
check 'CLICKHOUSE_MOST=2: two tables, the rest counted' 'yes 2' "$(grep -q '^metric tables_not_shown [1-9]' "$work/most.out" && echo yes || echo no) $(grep -c '^metric table_parts ' "$work/most.out")"

say "26.8, ch2, its fetches stopped: what waits in its queue."
use 18124
for _ in $(seq 1 20); do quiet replication; [ "$(least replication table_queue_inserts 'table=app.events' 5)" = yes ] && break; sleep 2; done
sleep 3
run replication 'fetches stopped'
check 'ch2: the five inserts wait in its queue' 'yes yes' "$(least replication table_queue 'table=app.events' 5) $(least replication table_queue_inserts 'table=app.events' 5)"
check 'ch2: and it is behind' 'yes yes' "$(least replication table_delay_seconds 'table=app.events' 1) $(least replication table_queue_oldest_seconds 'table=app.events' 1)"
run status 'fetches stopped'
check 'ch2: its queue, in the server status too' yes "$(least status replica_queue '' 5)"
sql 18124 'SYSTEM START FETCHES app.events'
for _ in $(seq 1 30); do quiet replication; [ "$(val replication table_queue 'table=app.events')" = 0 ] && break; sleep 2; done
check 'ch2: fetches started: its queue empties' 0 "$(val replication table_queue 'table=app.events')"

say "25.8, one server, no Keeper: every job."
use 18125
for j in $jobs; do run "$j"; done
for j in $jobs; do check "25.8: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
check '25.8: up, its version' '1 yes' "$(val status up '') $(has status info 'version=25\.8\.')"
check '25.8: no Keeper: no session, nothing replicated' '0 0' "$(val status keeper_sessions '') $(val replication replicated '')"

say "Logins and grants, on ch1."
use 18123
CLICKHOUSE_PASSWORD=not-the-password bash "$pack/status.sh" > "$work/wrong.out" 2>&1
check 'a wrong password fails the run' 1 "$?"
check 'and says so' yes "$(said wrong 'ClickHouse refused the login')"
sed 's/^/        /' "$work/wrong.out"
CLICKHOUSE_USER=nogrant CLICKHOUSE_PASSWORD=$(cat "$work/nogrant.pw") bash "$pack/tables.sh" > "$work/nogrant.out" 2>&1
check 'a user with no grant fails the run' 1 "$?"
check 'and says which grant' yes "$(said nogrant 'GRANT SELECT ON system.\*, SHOW TABLES ON \*.\* TO nogrant')"
sed 's/^/        /' "$work/nogrant.out"
# Without SHOW TABLES, ClickHouse leaves out of the system tables every
# table but its own: the run succeeds, and sees none of them.
CLICKHOUSE_USER=sysonly CLICKHOUSE_PASSWORD=$(cat "$work/sysonly.pw") bash "$pack/tables.sh" > "$work/sysonly.out" 2>&1
check 'SELECT ON system.* alone: the run succeeds, and no table of app is seen' '0 0' "$? $(grep -c 'table=app\.' "$work/sysonly.out")"
CLICKHOUSE_URL=http://127.0.0.1:18126 bash "$pack/status.sh" > "$work/down.out" 2>&1
check 'nothing listening: the run succeeds, up 0' '0 yes' "$? $(grep -q '^metric up 0$' "$work/down.out" && echo yes || echo no)"

say "The pack through Vigil, against ch1."
export VIGIL_IT_CLICKHOUSE_URL=http://127.0.0.1:18123 VIGIL_IT_CLICKHOUSE_USER=vigil
export VIGIL_IT_CLICKHOUSE_PASSWORD; VIGIL_IT_CLICKHOUSE_PASSWORD=$(cat "$work/vigil.pw")
unset CLICKHOUSE_URL CLICKHOUSE_USER CLICKHOUSE_PASSWORD
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_CH_HOLD=<file>: the cluster stays up, vigil's password in
# <file>.d/ (this account's alone), for the tests of other machines (macOS,
# Windows), until <file> is deleted.
if [ -n "${VIGIL_IT_CH_HOLD-}" ]; then
    (umask 077 && mkdir -p "$VIGIL_IT_CH_HOLD.d" && cp "$work/vigil.pw" "$VIGIL_IT_CH_HOLD.d/")
    : > "$VIGIL_IT_CH_HOLD"
    printf 'hold     the cluster stays up, on 18123-18125, until %s is deleted\n' "$VIGIL_IT_CH_HOLD"
    while [ -e "$VIGIL_IT_CH_HOLD" ]; do sleep 5; done
    rm -rf "$VIGIL_IT_CH_HOLD.d"
fi
kill "$slow" 2> /dev/null
sql 18123 "KILL QUERY WHERE query_id = 'vigil-it-slow' SYNC" > /dev/null 2>&1
slow=''

use 18123
say "ch2 stops: ch1 has a replica missing."
dc stop ch2 > /dev/null 2>&1
for _ in $(seq 1 30); do quiet replication; [ "$(val replication replicas_missing '')" = 1 ] && break; sleep 2; done
run replication 'ch2 stopped'
check 'ch2 stopped: one replica missing' '1 1 2' "$(val replication replicas_missing '') $(val replication table_replicas_active 'table=app.events') $(val replication table_replicas 'table=app.events')"
dc start ch2 > /dev/null 2>&1
for _ in $(seq 1 60); do quiet replication; [ "$(val replication replicas_missing '')" = 0 ] && break; sleep 2; done
check 'ch2 back: none missing' 0 "$(val replication replicas_missing '')"

say "Keeper stops: the replicated tables turn read-only."
dc stop keeper > /dev/null 2>&1
for _ in $(seq 1 45); do quiet replication; [ "$(val replication readonly '')" = 1 ] && break; sleep 2; done
run replication 'Keeper stopped'
run status 'Keeper stopped'
check 'Keeper stopped: the replication job still runs' 'exit 0' "$(tail -n 1 "$work/replication.err")"
check 'Keeper stopped: app.events read-only' '1 1' "$(val replication readonly '') $(val replication table_readonly 'table=app.events')"
# Its session stays counted while the server retries Keeper: read-only is
# what says so.
check 'Keeper stopped: the server status counts a replica read-only' yes "$(least status readonly_replicas '' 1)"
dc start keeper > /dev/null 2>&1
for _ in $(seq 1 60); do quiet replication; [ "$(val replication readonly '')" = 0 ] && break; sleep 2; done
check 'Keeper back: none read-only' 0 "$(val replication readonly '')"

say "25.8: a part damaged while the server is stopped; it is detached as broken when it starts."
sql 18125 'CREATE TABLE default.b (k UInt32, v String) ENGINE = MergeTree ORDER BY k'
sql 18125 'INSERT INTO default.b SELECT number, toString(number) FROM numbers(100000)'
bpath=$(sql 18125 "SELECT path FROM system.parts WHERE database = 'default' AND table = 'b' AND active LIMIT 1")
dc stop ch25 > /dev/null 2>&1
docker run --rm --entrypoint sh -v vigil-ch_ch25:/var/lib/clickhouse "$(dc config --images | grep ':25\.' | head -n 1)" \
    -c 'f=$(ls "$1"*.bin | head -n 1); truncate -s 100 "$f" && echo "damaged  ${f##*/}: truncated to 100 bytes"' sh "$bpath"
dc start ch25 > /dev/null 2>&1
for _ in $(seq 1 60); do [ "$(sql 18125 'SELECT 1' 2> /dev/null)" = 1 ] && break; sleep 2; done
use 18125
run merges 'a part damaged'
check '25.8: the damaged part, detached as broken when it started' yes "$(grep -qE '^metric detached_parts [1-9][0-9]* reason=broken$' "$work/merges.out" && echo yes || echo no)"

say "25.8 stops: every job still runs, and reads up 0."
dc stop ch25 > /dev/null 2>&1
for j in $jobs; do
    bash "$pack/$j.sh" > "$work/$j.out" 2>&1
    check "25.8 stopped: $j: the run succeeds, up 0" '0 yes' "$? $(grep -q '^metric up 0$' "$work/$j.out" && echo yes || echo no)"
done
cat "$work/status.out"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
