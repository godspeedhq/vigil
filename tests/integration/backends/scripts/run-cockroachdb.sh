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
# run-cockroachdb.sh - the cockroachdb pack against a real cluster in trouble
# on purpose, and a single node, with its evidence kept like the other runs'.
#
#   scripts/run-cockroachdb.sh
#
# It starts compose.cockroachdb.yaml: 26.4.1, three nodes, secure (its node
# certificate made to last ten days), and 25.4.21, one node, insecure.
# 26.4.1 is CockroachDB's own Linux binary, checked against its published
# SHA-256 and kept in VIGIL_IT_CRDB_CACHE (default ~/.cache/vigil-it): its
# images need an x86-64-v3 CPU. In 26.4.1, as root: a user with the three
# read-only system privileges the pack asks for (vigil), one with none; a
# workload, statements that fail, a full scan, transactions restarted on
# purpose; a backup that fails, a changefeed to a sink that never answers,
# another paused, a backup schedule paused, and an upgrade held back
# (cluster.preserve_downgrade_option). Every job is run against both and
# what it reads is checked; then the user with no privileges, a wrong
# password and a node that is down; then tests/integration/service-packs.sh
# runs the pack through Vigil. At the end, 26.4.1's nodes leave: one stops
# (unavailable, then dead), comes back, is decommissioned and recommissioned;
# then two stop, and the last has no quorum. The passwords are made here,
# into this run's own folder, and kept out of the evidence.
# VIGIL_IT_CRDB_HOLD (below) keeps the cluster up for other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: CockroachDB runs in containers'
for p in curl jq openssl sha256sum tar; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
file=compose.cockroachdb.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-crdb-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-crdb --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }

# CockroachDB 26.4.1's binary, checked against the SHA-256 Cockroach Labs
# publishes beside it.
v26=v26.4.1
cache=${VIGIL_IT_CRDB_CACHE:-$HOME/.cache/vigil-it}
export CRDB26=$cache/cockroach-$v26.linux-amd64
if [ ! -x "$CRDB26/cockroach" ]; then
    mkdir -p "$cache" || die "cannot make $cache"
    t=cockroach-$v26.linux-amd64.tgz
    curl -sSfL -o "$work/$t" "https://binaries.cockroachdb.com/$t" || die "cannot download $t"
    want=$(curl -sSfL "https://binaries.cockroachdb.com/$t.sha256sum" | awk '{ print $1 }')
    got=$(sha256sum "$work/$t" | awk '{ print $1 }')
    [ -n "$want" ] && [ "$want" = "$got" ] || die "$t does not match its published SHA-256"
    tar -xzf "$work/$t" -C "$cache" || die "cannot unpack $t"
    rm -f "$work/$t"
fi

(umask 077 && openssl rand -hex 16 > "$work/vigil.pw" && openssl rand -hex 16 > "$work/nopriv.pw")
trap 'dc down -v > /dev/null 2>&1; evidence_save "$(cat "$work/vigil.pw")" "$(cat "$work/nopriv.pw")"; rm -rf "$work"' EXIT
evidence_start pack-cockroachdb "$bk_dir/$file" "$0" "$@"
printf 'crdb26   %s, its binary (checked against its published SHA-256 when downloaded): %s\n' "$v26" "$(sha256sum "$CRDB26/cockroach" | cut -c1-16)..."
pack=$bk_repo/packs/cockroachdb/linux

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'CockroachDB would not start'; }
c26() { docker exec -i vigil-crdb-crdb1-1 /opt/cockroach/cockroach "$@" --certs-dir=/certs --host=crdb1; }
sq() { c26 sql --format=tsv; }
sq25() { docker exec -i vigil-crdb-crdb25-1 /cockroach/cockroach sql --insecure --format=tsv; }
for _ in $(seq 1 30); do c26 init > /dev/null 2>&1 && break; c26 node ls > /dev/null 2>&1 && break; sleep 2; done
for _ in $(seq 1 60); do [ "$(c26 node ls --format=tsv 2> /dev/null | grep -c '^[0-9]')" -eq 3 ] && break; sleep 2; done
[ "$(c26 node ls --format=tsv 2> /dev/null | grep -c '^[0-9]')" -eq 3 ] || { dc logs --tail 20; die '26.4.1 did not form a cluster of 3'; }
for _ in $(seq 1 60); do curl -sf http://127.0.0.1:18090/health?ready=1 > /dev/null && break; sleep 2; done
docker cp vigil-crdb-crdb1-1:/certs/ca.crt "$work/ca.crt" > /dev/null
printf 'cockroachdb  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
# Node IDs follow the order nodes joined: by address, from the cluster.
id_of() { c26 node status --format=tsv 2> /dev/null | awk -v a="$1:26257" '$2 == a { print $1 }'; }

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
most() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 <= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }
# run <job> [<label>]: the job's script, its output shown and kept.
run() {
    printf '\n$ bash packs/cockroachdb/linux/%s.sh%s\n' "$1" "${2:+   ($2)}"
    bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    cat "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err"
}
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/cockroachdb/pack.config")
url26=https://localhost:18081
use26() { export COCKROACH_URL=${1:-$url26} COCKROACH_CACERT=$work/ca.crt COCKROACH_USER=vigil; export COCKROACH_PASSWORD; COCKROACH_PASSWORD=$(cat "$work/vigil.pw"); }

say "26.4.1 in trouble on purpose, as root."
{
    printf "CREATE USER vigil WITH PASSWORD '%s';\n" "$(cat "$work/vigil.pw")"
    printf 'GRANT SYSTEM VIEWCLUSTERMETADATA, VIEWCLUSTERSETTING, VIEWJOB TO vigil;\n'
    printf "CREATE USER nopriv WITH PASSWORD '%s';\n" "$(cat "$work/nopriv.pw")"
} | sq > /dev/null || die 'cannot make the users'
echo 'users    vigil (VIEWCLUSTERMETADATA, VIEWCLUSTERSETTING, VIEWJOB), nopriv (none)'
w='postgresql://root@crdb1:26257?sslmode=verify-full&sslrootcert=/certs/ca.crt&sslcert=/certs/client.root.crt&sslkey=/certs/client.root.key'
docker exec vigil-crdb-crdb1-1 /opt/cockroach/cockroach workload init kv "$w" > /dev/null 2>&1
docker exec vigil-crdb-crdb1-1 /opt/cockroach/cockroach workload run kv --duration=20s --max-rate=40 --concurrency=4 "$w" > /dev/null 2>&1
echo 'workload kv, 20 seconds, at most 40 operations a second'
# One statement at a time: cockroach sql stops a batch at its first error.
for s in "CREATE TABLE t (id INT PRIMARY KEY, v STRING, w INT)" \
    "INSERT INTO t SELECT i, 'x', i FROM generate_series(1, 1000) AS g(i)" \
    "SELECT count(*) FROM t WHERE w = 7" \
    "SET allow_unsafe_internals = true; SET statement_timeout = '5s'; SELECT crdb_internal.force_retry('300ms')" \
    "SET CLUSTER SETTING kv.rangefeed.enabled = true" \
    "SET CLUSTER SETTING cluster.preserve_downgrade_option = '26.4'" \
    "SET CLUSTER SETTING server.time_until_store_dead = '1m15s'"; do
    echo "$s;" | sq > /dev/null 2>&1 || printf 'note     refused: %s\n' "$s"
done
for i in 1 2 3; do echo 'SELECT 1 / 0;' | sq > /dev/null 2>&1; done
echo 'sql      a table of 1,000 rows; a full scan; transactions restarted (force_retry); three statements that fail (1 / 0)'
echo "CREATE CHANGEFEED FOR TABLE t INTO 'webhook-https://127.0.0.1:9/never?insecure_tls_skip_verify=true' WITH resolved = '5s';" | sq > /dev/null
echo "CREATE CHANGEFEED FOR TABLE t INTO 'webhook-https://127.0.0.1:9/paused?insecure_tls_skip_verify=true';" | sq > /dev/null
echo "PAUSE JOBS SELECT job_id FROM [SHOW CHANGEFEED JOBS] WHERE sink_uri LIKE '%paused%';" | sq > /dev/null
echo 'changefeeds  one to a sink that never answers; another, paused'
# A backup that fails as a job: its folder is a file.
docker exec vigil-crdb-crdb1-1 sh -c 'mkdir -p /data/extern && : > /data/extern/blocked'
echo "BACKUP DATABASE defaultdb INTO 'nodelocal://1/blocked/backups' WITH DETACHED;" | sq > /dev/null
echo "CREATE SCHEDULE nightly FOR BACKUP DATABASE defaultdb INTO 'nodelocal://1/backups' RECURRING '@daily' FULL BACKUP ALWAYS WITH SCHEDULE OPTIONS first_run = '2099-01-01';" | sq > /dev/null
echo "PAUSE SCHEDULES SELECT id FROM [SHOW SCHEDULES] WHERE label = 'nightly';" | sq > /dev/null
echo 'backups  one into a folder that is a file (fails); a nightly schedule, paused'
echo 'settings cluster.preserve_downgrade_option = 26.4; server.time_until_store_dead = 1m15s'
for _ in $(seq 1 30); do
    [ "$(echo "SELECT count(*) FROM [SHOW JOBS] WHERE job_type = 'BACKUP' AND status = 'failed';" | sq | tail -n 1)" -ge 1 ] 2> /dev/null && break
    sleep 2
done
sleep 20

say "26.4.1, node 1: every job, as the pack's scripts print it, as vigil."
use26
for j in $jobs; do run "$j"; done
say "26.4.1: what they read."
for j in $jobs; do check "26.4.1: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
check '26.4.1: up and ready' '1 1' "$(val status up '') $(val status ready '')"
check '26.4.1: its version' yes "$(has status info 'version=v26.4.1')"
check '26.4.1: three nodes live, as node 1 sees them' 3 "$(val status live_nodes '')"
check '26.4.1: the node certificate, ten days or fewer' yes "$(most status cert_days 'cert=node' 10)"
check '26.4.1: and the fewest days, the node one' "$(val status cert_days 'cert=node')" "$(val status cert_days_min '')"
check '26.4.1: ranges on node 1' yes "$(least replication ranges '' 1)"
check '26.4.1: none unavailable' 0 "$(val replication ranges_unavailable '')"
check '26.4.1: a disk, its size' yes "$(least storage disk_bytes '' 1)"
check '26.4.1: the write-ahead log fsynced' yes "$(least storage wal_fsyncs_count '' 1)"
check '26.4.1: SELECTs counted' yes "$(least sql selects_count '' 1)"
check '26.4.1: the statements that failed' yes "$(least sql failures_count '' 3)"
check '26.4.1: the full scan' yes "$(least sql full_scans_count '' 1)"
check '26.4.1: the transactions restarted' yes "$(least sql restarts_count '' 1)"
check '26.4.1: the cluster: 3 nodes, 3 live, none dead' '3 3 0' "$(val cluster nodes '') $(val cluster live '') $(val cluster dead '')"
check '26.4.1: its version, 26.4, not behind its nodes' '1 0' "$(val cluster cluster_version 'version=26.4') $(val cluster upgrade_pending '')"
check '26.4.1: the upgrade held back, seen' 1 "$(val cluster downgrade_preserved '')"
check '26.4.1: the failed backup' yes "$(has jobs job_failed 'type=BACKUP')"
check '26.4.1: the paused changefeed' yes "$(has jobs job_paused_seconds 'type=CHANGEFEED')"
check '26.4.1: the paused schedule' 1 "$(val jobs schedules_paused '')"
check '26.4.1: the changefeed that cannot send' yes "$(least jobs changefeeds '' 1)"
check '26.4.1: and how far behind it is' yes "$(least jobs changefeed_behind_seconds '' 5)"
check '26.4.1: no job description printed' 0 "$(grep -c '127.0.0.1:9\|webhook\|nodelocal' "$work/jobs.out")"

say "25.4.21, one node, insecure: every job, with no login."
export COCKROACH_URL=http://127.0.0.1:18090 COCKROACH_USER='' COCKROACH_CACERT=''
for j in $jobs; do run "$j"; done
for j in $jobs; do check "25.4.21: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
check '25.4.21: up, ready, its version' '1 1 yes' "$(val status up '') $(val status ready '') $(has status info 'version=v25.4.21')"
check '25.4.21: insecure: no certificate' no "$(has status cert_days '')"
check '25.4.21: the cluster: one node, live' '1 1' "$(val cluster nodes '') $(val cluster live '')"

say "Logins and privileges, on 26.4.1."
use26
COCKROACH_USER=nopriv COCKROACH_PASSWORD=$(cat "$work/nopriv.pw") bash "$pack/cluster.sh" > "$work/nopriv.out" 2>&1
check 'a user without VIEWCLUSTERMETADATA fails the cluster job' 1 "$?"
check 'and says which privilege' yes "$(grep -q 'VIEWCLUSTERMETADATA' "$work/nopriv.out" && echo yes || echo no)"
sed 's/^/        /' "$work/nopriv.out"
COCKROACH_PASSWORD=not-the-password bash "$pack/cluster.sh" > "$work/wrong.out" 2>&1
check 'a wrong password fails the run' 1 "$?"
check 'and says so' yes "$(grep -q 'CockroachDB refused the login (HTTP 401)' "$work/wrong.out" && echo yes || echo no)"
sed 's/^/        /' "$work/wrong.out"
COCKROACH_PASSWORD='' bash "$pack/jobs.sh" > "$work/nopw.out" 2>&1
check 'a user with no password set fails, and says how to set it' yes "$(grep -q 'vigil secret set COCKROACH_PASSWORD' "$work/nopw.out" && echo yes || echo no)"
for j in status replication storage sql cluster; do
    COCKROACH_URL=http://127.0.0.1:1 bash "$pack/$j.sh" > "$work/down.out" 2>&1
    check "a node that does not answer: $j still runs, up 0" '0 yes' "$? $(grep -q '^metric up 0$' "$work/down.out" && echo yes || echo no)"
done

say "The pack through Vigil."
export VIGIL_IT_CRDB_URL=$url26 VIGIL_IT_CRDB_USER=vigil VIGIL_IT_CRDB_CACERT=$work/ca.crt
export VIGIL_IT_CRDB_PASSWORD; VIGIL_IT_CRDB_PASSWORD=$(cat "$work/vigil.pw")
unset COCKROACH_URL COCKROACH_USER COCKROACH_PASSWORD COCKROACH_CACERT
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_CRDB_HOLD=<file>: the clusters stay up, the CA and vigil's
# password in <file>.d/ (this account's alone), for the tests of other
# machines (macOS, Windows), until <file> is deleted.
if [ -n "${VIGIL_IT_CRDB_HOLD-}" ]; then
    (umask 077 && mkdir -p "$VIGIL_IT_CRDB_HOLD.d" && cp "$work/ca.crt" "$work/vigil.pw" "$VIGIL_IT_CRDB_HOLD.d/")
    : > "$VIGIL_IT_CRDB_HOLD"
    printf 'hold     the clusters stay up, on 18081-3 and 18090, until %s is deleted\n' "$VIGIL_IT_CRDB_HOLD"
    while [ -e "$VIGIL_IT_CRDB_HOLD" ]; do sleep 5; done
    rm -rf "$VIGIL_IT_CRDB_HOLD.d"
fi

use26
n3=$(id_of crdb3)
say "A node leaves 26.4.1: crdb3 (node $n3) stops."
dc stop crdb3 > /dev/null 2>&1
for _ in $(seq 1 30); do bash "$pack/status.sh" > "$work/status.out" 2> /dev/null; [ "$(val status live_nodes '')" = 2 ] && break; sleep 2; done
for _ in $(seq 1 45); do bash "$pack/replication.sh" > "$work/replication.out" 2> /dev/null; [ "$(least replication ranges_underreplicated '' 1)" = yes ] && break; sleep 2; done
# Stopped with SIGTERM, it drains first: draining, then unavailable when its
# liveness expires, then dead.
for _ in $(seq 1 30); do bash "$pack/cluster.sh" > "$work/cluster.out" 2> /dev/null; [ "$(val cluster live '')" = 2 ] && break; sleep 2; done
run status 'crdb3 stopped'
run replication 'crdb3 stopped'
run cluster 'crdb3 stopped'
check 'crdb3 stopped: node 1 sees two nodes live' 2 "$(val status live_nodes '')"
check 'crdb3 stopped: ranges under-replicated' yes "$(least replication ranges_underreplicated '' 1)"
check 'crdb3 stopped: the cluster: two live of three' '3 2' "$(val cluster nodes '') $(val cluster live '')"
check 'crdb3 stopped: it comes first, not live' yes "$(grep '^metric node_status ' "$work/cluster.out" | head -n 1 | grep -qE "node=$n3 status=(draining|unavailable|dead)" && echo yes || echo no)"
COCKROACH_URL=https://localhost:18083 bash "$pack/status.sh" > "$work/gone.out" 2>&1
check 'crdb3 stopped: its own status job reads up 0' '0 yes' "$? $(grep -q '^metric up 0$' "$work/gone.out" && echo yes || echo no)"
printf '\n(waiting for it to be declared dead: server.time_until_store_dead is 1m15s)\n'
for _ in $(seq 1 60); do bash "$pack/cluster.sh" > "$work/cluster.out" 2> /dev/null; [ "$(val cluster dead '')" = 1 ] && break; sleep 3; done
run cluster 'crdb3 stopped for longer than 1m15s'
check 'crdb3 dead' "1 yes" "$(val cluster dead '') $(has cluster node_status "node=$n3 status=dead")"

say "crdb3 comes back; then it is decommissioned, in a cluster of three that has nowhere to move its replicas."
dc start crdb3 > /dev/null 2>&1
for _ in $(seq 1 60); do bash "$pack/cluster.sh" > "$work/cluster.out" 2> /dev/null; [ "$(val cluster live '')" = 3 ] && break; sleep 3; done
check 'crdb3 back: three live' 3 "$(val cluster live '')"
# Its pre-flight checks refuse it, rightly: two nodes cannot hold three
# replicas. Skipped, it starts, and cannot finish: what the jobs should show.
printf '\n$ cockroach node decommission %s --wait=none --checks=skip\n' "$n3"
c26 node decommission "$n3" --wait=none --checks=skip 2>&1 | head -n 5
for _ in $(seq 1 30); do bash "$pack/replication.sh" > "$work/replication.out" 2> /dev/null; [ "$(least replication ranges_decommissioning '' 1)" = yes ] && break; sleep 2; done
run cluster "node $n3 decommissioning"
run replication "node $n3 decommissioning"
check "decommissioning: seen" "1 yes" "$(val cluster decommissioning '') $(has cluster node_status "node=$n3 status=decommissioning")"
check 'decommissioning: its ranges counted' yes "$(least replication ranges_decommissioning '' 1)"
c26 node recommission "$n3" > /dev/null 2>&1
for _ in $(seq 1 30); do bash "$pack/cluster.sh" > "$work/cluster.out" 2> /dev/null; [ "$(val cluster decommissioning '')" = 0 ] && break; sleep 2; done
check 'recommissioned: none decommissioning' 0 "$(val cluster decommissioning '')"

say "Two nodes stop: crdb2 and crdb3. Node 1 has no quorum."
dc stop crdb2 crdb3 > /dev/null 2>&1
sleep 20
run status 'no quorum'
check 'no quorum: the status job still runs' 'exit 0' "$(tail -n 1 "$work/status.err")"
check 'no quorum: node 1 up, and sees fewer than two live' '1 yes' "$(val status up '') $(most status live_nodes '' 1)"
run replication 'no quorum'
check 'no quorum: the replication job still runs' 'exit 0' "$(tail -n 1 "$work/replication.err")"
t0=$(date +%s)
run cluster 'no quorum'
check 'no quorum: the cluster job ends, within its 50 s max_runtime' yes "$([ $(($(date +%s) - t0)) -lt 50 ] && echo yes || echo no)"
dc start crdb2 crdb3 > /dev/null 2>&1

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
