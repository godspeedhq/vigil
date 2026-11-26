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
# run-cassandra.sh - the cassandra pack against a real cluster in trouble on
# purpose, and an older single node, with its evidence kept like the other
# runs'.
#
#   VIGIL_IT_CASSANDRA_JDK=<a JDK 17 or later> scripts/run-cassandra.sh
#
# It builds the pack as a release does (its _probe.jar compiled, with
# tools/release/client-jar.sh and the JDK in VIGIL_IT_CASSANDRA_JDK or
# JAVA_HOME), then starts compose.cassandra.yaml: 5.0, three nodes, and
# 4.1, one, each with JMX open to other hosts and a password, read as
# monitorRole (read-only, by the JDK's own access file). With cqlsh and
# nodetool, in the cluster: a keyspace of three replicas; rows loaded; a
# table whose autocompaction is off, flushed again and again (SSTables);
# a partition of cells that expired (tombstones a read scans); writes at
# CONSISTENCY ALL with a replica paused (timeouts). Every job is run
# against c1 and 4.1, and what it reads is checked; then a wrong password,
# nothing listening, and a jar that is not the one the scripts carry. Then
# tests/integration/service-packs.sh runs the pack through Vigil. Then c3
# stops (a node down, writes at ALL unavailable, hints), and c2 is drained.
# The passwords are made here, into this run's own folder, and kept out of
# the evidence. VIGIL_IT_CASSANDRA_HOLD keeps it up for other machines'
# tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: Cassandra runs in containers'
command -v openssl > /dev/null 2>&1 || die 'openssl not found'
file=compose.cassandra.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-cass-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-cass --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
(umask 077 && openssl rand -hex 16 > "$work/monitor.pw" && openssl rand -hex 16 > "$work/control.pw")
printf 'monitorRole %s\ncontrolRole %s\n' "$(cat "$work/monitor.pw")" "$(cat "$work/control.pw")" > "$work/jmx" && chmod 444 "$work/jmx"
export CASSANDRA_JMX_FILE=$work/jmx
trap 'docker unpause vigil-cass-c2-1 > /dev/null 2>&1; dc down -v > /dev/null 2>&1; evidence_save "$(cat "$work/monitor.pw")" "$(cat "$work/control.pw")"; rm -rf "$work"' EXIT
evidence_start pack-cassandra "$bk_dir/$file" "$0" "$@"

# The pack as a release builds it: its jar compiled and its digest in the scripts.
pack=$work/pack
mkdir -p "$pack" && cp "$bk_repo/packs/cassandra/pack.config" "$bk_repo/packs/cassandra/linux"/* "$pack/" || die 'cannot copy the pack'
JAVA_HOME=${VIGIL_IT_CASSANDRA_JDK:-${JAVA_HOME-}} bash "$bk_repo/tools/release/client-jar.sh" "$pack" > "$work/jars.log" 2>&1 ||
    { cat "$work/jars.log"; die 'cannot build the pack'"'"'s jar'; }
sed 's/^client-jar: [^ ]*\/\(_[a-z]*\.jar\)/jar      \1/' "$work/jars.log"
printf 'java     %s\n' "$(java -version 2>&1 | head -n 1)"

# A node ready: CQL listening. One at a time: three bootstrapping at once
# would not form a ring.
ready() {
    for _ in $(seq 1 120); do docker logs "vigil-cass-$1-1" 2>&1 | grep -q 'Starting listening for CQL clients' && return 0; sleep 3; done
    dc logs --tail 30 "$1"; die "$1 did not start"
}
dc up -d c1 c41 > "$work/up.log" 2>&1 || { cat "$work/up.log"; die 'Cassandra would not start'; }
ready c1; ready c41
dc up -d c2 > /dev/null 2>&1; ready c2
dc up -d c3 > /dev/null 2>&1; ready c3
port() { case $1 in c1) echo 17199 ;; c2) echo 17299 ;; c3) echo 17399 ;; c41) echo 17419 ;; esac; }
# nt <node> <args>: nodetool on the node, as controlRole, its password from
# the file (-pwf), never on a command line.
nt() { local n=$1; shift; docker exec "vigil-cass-$n-1" nodetool -u controlRole -pwf /etc/cassandra/jmxremote.password -h 127.0.0.1 -p "$(port "$n")" "$@"; }
# cql <node> <statements>: through cqlsh, on the node, from a file.
cql() {
    printf '%s\n' "$2" > "$work/q.cql"
    docker cp "$work/q.cql" "vigil-cass-$1-1:/tmp/q.cql" > /dev/null
    docker exec "vigil-cass-$1-1" cqlsh -f /tmp/q.cql 2>&1
}
for _ in $(seq 1 60); do [ "$(nt c1 status 2> /dev/null | grep -c '^UN ')" = 3 ] && break; sleep 3; done
[ "$(nt c1 status 2> /dev/null | grep -c '^UN ')" = 3 ] || { nt c1 status; die 'the cluster did not form'; }
printf 'cassandra  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+ .*$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }
run() {
    printf '\n$ bash packs/cassandra/linux/%s.sh%s\n' "$1" "${2:+   ($2)}"
    bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    cat "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err"
}
quiet() { bash "$pack/$1.sh" > "$work/$1.out" 2> /dev/null; }
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$pack/pack.config")
targets='c1: jmx=localhost:17199; c41: jmx=localhost:17419'
export CASSANDRA_JMX=$targets CASSANDRA_JMX_USER=monitorRole CASSANDRA_JMX_PASSWORD
CASSANDRA_JMX_PASSWORD=$(cat "$work/monitor.pw")

say "The cluster in trouble on purpose, with cqlsh and nodetool."
cql c1 "CREATE KEYSPACE app WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 3};
CREATE TABLE app.events (id int, r int, v text, PRIMARY KEY (id, r));
CREATE TABLE app.tomb (p int, c int, v text, PRIMARY KEY (p, c));" > /dev/null || die 'cannot make the keyspace'
cql c41 "CREATE KEYSPACE app WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};
CREATE TABLE app.events (id int PRIMARY KEY, v text);" > /dev/null
# On every node: a read at ONE may be served by any of the three, and each
# counts only the reads it serves.
for n in c1 c2 c3; do nt "$n" disableautocompaction app events; done
# 400 partitions, a row added to each in each of 8 rounds, each round
# flushed to an SSTable of its own, autocompaction off: a partition is in
# all 8, and a read of it looks in each. (A row rewritten whole would not
# do: Cassandra reads the newest SSTable first and stops once it has all.)
for r in $(seq 1 8); do
    for i in $(seq 1 400); do printf '%d,%d,row of round %d\n' "$i" "$r" "$r"; done > "$work/e.csv"
    docker cp "$work/e.csv" vigil-cass-c1-1:/tmp/e.csv > /dev/null
    cql c1 "COPY app.events (id, r, v) FROM '/tmp/e.csv';" > /dev/null
    for n in c1 c2 c3; do nt "$n" flush app events; done
done
echo 'app.events  400 partitions, a row added to each in 8 rounds, keyspace of three replicas; autocompaction off on each node, flushed after each round'
# A partition of 3,000 cells that expire in a second: tombstones to a read.
for i in $(seq 1 3000); do printf '1,%d,x\n' "$i"; done > "$work/t.csv"
docker cp "$work/t.csv" vigil-cass-c1-1:/tmp/t.csv > /dev/null
cql c1 "COPY app.tomb (p, c, v) FROM '/tmp/t.csv' WITH TTL = 1;" > /dev/null
sleep 3
for i in 1 2 3 4 5; do cql c1 "CONSISTENCY ONE; SELECT count(*) FROM app.tomb WHERE p = 1;" > /dev/null; done
echo 'app.tomb    3,000 cells in one partition, expired (TTL 1 s), read five times'
# Reads that look in many SSTables.
q=''; for i in $(seq 1 25 400); do q="$q SELECT v FROM app.events WHERE id = $i;"; done
for i in 1 2 3; do cql c1 "CONSISTENCY ONE; $q" > /dev/null; done
echo 'reads       48 by key on c1, at ONE'
# Writes at ALL with c2 paused: c1 waits for it, and gives up.
docker pause vigil-cass-c2-1 > /dev/null
for i in 1 2 3; do cql c1 "CONSISTENCY ALL; INSERT INTO app.events (id, r, v) VALUES (9000$i, 0, 'needs all three');" > "$work/all.$i" 2>&1; done
docker unpause vigil-cass-c2-1 > /dev/null
echo "c2 paused   3 writes at ALL: $(grep -ho 'WriteTimeout\|Unavailable\|Operation timed out' "$work"/all.* | sort | uniq -c | tr -s ' ' | tr '\n' ';' | sed 's/;$//')"
for _ in $(seq 1 30); do [ "$(nt c1 status 2> /dev/null | grep -c '^UN ')" = 3 ] && break; sleep 2; done
sleep 5

say "5.0, c1, and 4.1: every job, as the pack's scripts print it, as monitorRole."
for j in $jobs; do run "$j"; done
say "What they read."
for j in $jobs; do check "$j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
check 'c1: JMX answers, its version, normal' '1 yes 1' "$(val status jmx_up 'node=c1') $(has status version 'node=c1 .*version=5\.0\.') $(val status normal 'node=c1')"
check 'c1: gossip and CQL running; three nodes up, none down' '1 1 3 0' "$(val status gossip_up 'node=c1') $(val status native_up 'node=c1') $(val status nodes_up 'node=c1') $(val status nodes_down 'node=c1')"
check 'c1: the data it holds' yes "$(least status load_bytes 'node=c1' 50000)"
check '4.1: JMX answers, its version, normal, alone' '1 yes 1 1' "$(val status jmx_up 'node=c41') $(has status version 'node=c41 .*version=4\.1\.') $(val status normal 'node=c41') $(val status nodes_up 'node=c41')"
check 'c1: reads and writes coordinated, and their latency' 'yes yes yes' "$(least requests requests_count 'node=c1 .*scope=Read$' 48) $(least requests requests_count 'node=c1 .*scope=Write$' 1) $(has requests latency_p99_ms 'node=c1 .*scope=Read$')"
check 'c1: writes at ALL timed out, c2 paused' yes "$(least requests timeouts_count 'node=c1 .*scope=Write$' 1)"
check 'c1: thread pools read; none blocked' 'yes 0' "$(has threads pending 'node=c1 .*scope=MutationStage$') $(grep -E '^metric blocked [1-9]' "$work/threads.out" | wc -l | tr -d ' ')"
check 'c1: dropped messages, as one total' yes "$(has threads dropped_total_count 'node=c1')"
check 'c1: app.events, 8 SSTables and more (autocompaction off)' yes "$(least tables sstables 'node=c1 .*keyspace=app scope=events' 8)"
check 'c1: a read looked in several SSTables' yes "$(least tables sstables_per_read_p99 'node=c1 .*keyspace=app scope=events' 2)"
check 'c1: a read scanned the 3,000 tombstones' yes "$(least tables tombstones_per_read_p99 'node=c1 .*keyspace=app scope=tomb' 2000)"
check "c1: Cassandra's own keyspaces left out" no "$(has tables sstables 'keyspace=system')"
check 'c1: the key cache, its hit rate' yes "$(has tables key_cache_hit_pct 'node=c1')"

say "Logins, nothing listening, and a jar that is not the scripts' own."
CASSANDRA_JMX_PASSWORD=not-the-password bash "$pack/status.sh" > "$work/wrong.out" 2>&1
rcw=$?
check 'a wrong password fails the run, and says the login was refused' '1 yes' "$rcw $(grep -q 'refused the login' "$work/wrong.out" && echo yes || echo no)"
sed 's/^/        /' "$work/wrong.out"
CASSANDRA_JMX='gone: jmx=localhost:17999' bash "$pack/status.sh" > "$work/down.out" 2>&1
check 'nothing listening: the run succeeds, jmx_up 0' '0 yes' "$? $(grep -q '^metric jmx_up 0 node=gone' "$work/down.out" && echo yes || echo no)"
cp -R "$pack" "$work/bad" && printf 'x' | dd of="$work/bad/_probe.jar" bs=1 seek=100 conv=notrunc 2> /dev/null
bash "$work/bad/status.sh" > "$work/bad.out" 2>&1
check 'a jar that does not match its digest: refused' '1 yes' "$? $(grep -qi 'digest\|sha-256' "$work/bad.out" && echo yes || echo no)"
sed 's/^/        /' "$work/bad.out"

say "The pack through Vigil, against c1 and 4.1."
export VIGIL_IT_PROBE_PACK=cassandra VIGIL_IT_PROBE_PACK_DIR=$pack VIGIL_IT_PROBE_TARGETS=$targets VIGIL_IT_PROBE_USER=monitorRole \
    VIGIL_IT_PROBE_PASSWORD=$CASSANDRA_JMX_PASSWORD VIGIL_IT_PROBE_EXPECT=cassandra_normal
unset CASSANDRA_JMX CASSANDRA_JMX_USER CASSANDRA_JMX_PASSWORD
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
unset VIGIL_IT_PROBE_PACK VIGIL_IT_PROBE_PACK_DIR VIGIL_IT_PROBE_TARGETS VIGIL_IT_PROBE_USER VIGIL_IT_PROBE_PASSWORD VIGIL_IT_PROBE_EXPECT
export CASSANDRA_JMX=$targets CASSANDRA_JMX_USER=monitorRole CASSANDRA_JMX_PASSWORD
CASSANDRA_JMX_PASSWORD=$(cat "$work/monitor.pw")
# VIGIL_IT_CASSANDRA_HOLD=<file>: the nodes stay up, monitorRole's password
# and the built pack in <file>.d/ (this account's alone), for the tests of
# other machines, until <file> is deleted.
if [ -n "${VIGIL_IT_CASSANDRA_HOLD-}" ]; then
    (umask 077 && mkdir -p "$VIGIL_IT_CASSANDRA_HOLD.d" && cp "$work/monitor.pw" "$VIGIL_IT_CASSANDRA_HOLD.d/" && cp -R "$pack" "$VIGIL_IT_CASSANDRA_HOLD.d/pack")
    : > "$VIGIL_IT_CASSANDRA_HOLD"
    printf 'hold     the nodes stay up, JMX on 17199, 17299, 17399 and 17419, until %s is deleted\n' "$VIGIL_IT_CASSANDRA_HOLD"
    while [ -e "$VIGIL_IT_CASSANDRA_HOLD" ]; do sleep 5; done
    rm -rf "$VIGIL_IT_CASSANDRA_HOLD.d"
fi

say "c3 stops: c1 sees a node down; writes at ALL are unavailable; hints are kept for c3."
dc stop c3 > /dev/null 2>&1
for _ in $(seq 1 30); do quiet status; [ "$(val status nodes_down 'node=c1')" = 1 ] && break; sleep 2; done
before=$(val requests unavailables_count 'node=c1 .*scope=Write$')
for i in 1 2 3; do cql c1 "CONSISTENCY ALL; INSERT INTO app.events (id, r, v) VALUES (9100$i, 0, 'needs all three');" > /dev/null 2>&1; done
for i in $(seq 1 20); do cql c1 "CONSISTENCY QUORUM; INSERT INTO app.events (id, r, v) VALUES (9200$i, 0, 'two of three will do');" > /dev/null 2>&1; done
sleep 3
run status 'c3 stopped'
run requests 'c3 stopped'
check 'c3 stopped: c1 sees one node down, two up' '1 2' "$(val status nodes_down 'node=c1') $(val status nodes_up 'node=c1')"
check 'c3 stopped: writes at ALL refused at once (unavailable)' yes "$(least requests unavailables_count 'node=c1 .*scope=Write$' $(( ${before:-0} + 3 )))"
check 'c3 stopped: hints written for it' yes "$(least status hints_count 'node=c1' 1)"
dc start c3 > /dev/null 2>&1; ready c3

say "c2 is drained: it stops taking requests, and leaves gossip."
nt c2 drain
export CASSANDRA_JMX='c2: jmx=localhost:17299'
run status 'c2 drained'
check 'drained: mode DRAINED, not normal; gossip and CQL stopped' 'yes 0 0 0' "$(has status mode 'node=c2 .*mode=DRAINED') $(val status normal 'node=c2') $(val status gossip_up 'node=c2') $(val status native_up 'node=c2')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
