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
# run-etcd.sh - the etcd pack against a real etcd cluster in trouble on
# purpose, and an older member alone, with its evidence kept like the other
# runs'.
#
#   scripts/run-etcd.sh
#
# It starts compose.etcd.yaml: a 3.6 cluster of three, and a 3.5 member
# with a 32 MiB quota. With etcdctl (in the containers): 500 keys, each
# written four times (history to compact); a watch held open; leases that
# expire. Every job is run against each member and what it reads is
# checked. Then the cluster loses its leader (the others elect one), then
# quorum (two of three stopped: no leader, a write that fails); the 3.5
# member's database is filled to its quota (the NOSPACE alarm, writes
# refused), then compacted, defragmented and its alarm disarmed. Then
# nothing listening and a page that is not there. Then
# tests/integration/service-packs.sh runs the pack through Vigil.
# VIGIL_IT_ETCD_HOLD (below) keeps the cluster up for other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: etcd runs in containers'
command -v curl > /dev/null 2>&1 || die 'curl not found'
file=compose.etcd.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-etcd-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-etcd --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
trap 'dc down -v > /dev/null 2>&1; evidence_save; rm -rf "$work"' EXIT
evidence_start pack-etcd "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/etcd/linux
[ "$(uname -s)" = Darwin ] && pack=$bk_repo/packs/etcd/macos

# Each member's metrics listener.
mport() { case $1 in e1) echo 12381 ;; e2) echo 12481 ;; e3) echo 12581 ;; e35) echo 12681 ;; esac; }
# ctl <member> <args>: etcdctl in the member's container, against itself;
# the image has no shell, so a value comes on etcdctl's standard input.
ctl() { local m=$1; shift; docker exec -i "vigil-etcd-$m-1" etcdctl --command-timeout=5s "$@"; }
healthy() { curl -sf "http://127.0.0.1:$(mport "$1")/health" > /dev/null; }

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'etcd would not start'; }
for m in e1 e2 e3 e35; do
    for _ in $(seq 1 60); do healthy "$m" && break; sleep 1; done
    healthy "$m" || { dc logs --tail 20 "$m"; die "$m never became healthy"; }
done
printf 'etcd     %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
say "The cluster in use, with etcdctl."
# b64 <text>: for etcd's HTTP gateway, which takes keys and values in base64.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
# 500 keys, each written four times: history for compaction to drop. Through
# e1's HTTP gateway (/v3/kv/put), many times faster than etcdctl in a
# container each time.
for round in 1 2 3 4; do
    for i in $(seq 1 500); do
        curl -sf -o /dev/null http://127.0.0.1:12379/v3/kv/put \
            -d "{\"key\":\"$(b64 "/app/key$i")\",\"value\":\"$(b64 "value$round")\"}" || die "put /app/key$i failed"
    done
done
echo 'keys     /app/key1 to /app/key500, each written 4 times'
# A watch held open on e1, for the watchers.
docker exec -d vigil-etcd-e1-1 etcdctl watch --prefix /app
echo 'watch    one, on /app, held open on e1'
# Two leases of 2 seconds, each with a key: they expire.
for n in 1 2; do
    id=$(curl -sf http://127.0.0.1:12379/v3/lease/grant -d '{"TTL":2}' | sed -n 's/.*"ID":"\([0-9]*\)".*/\1/p')
    curl -sf -o /dev/null http://127.0.0.1:12379/v3/kv/put -d "{\"key\":\"$(b64 "/lease/$n")\",\"value\":\"$(b64 x)\",\"lease\":\"$id\"}"
done
echo 'leases   two of 2 s, each with a key, left to expire'
sleep 5

pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }
run() {
    printf '\n$ ETCD_URL=%s bash packs/etcd/linux/%s.sh%s\n' "$ETCD_URL" "$1" "${2:+   ($2)}"
    bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    cat "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err"
}
quiet() { bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"; }
use() { export ETCD_URL="http://127.0.0.1:$(mport "$1")"; }
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/etcd/pack.config")

say "3.6, e1: every job, as the pack's scripts print it."
use e1
for j in $jobs; do run "$j"; done
say "3.6: what they read."
for j in $jobs; do check "e1: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
check 'e1: up, healthy, a leader, 3.6' '1 1 1 yes' "$(val status up '') $(val status healthy '') $(val status has_leader '') $(has status version 'version=3\.6\.')"
check 'e1: three members, the two others connected' '3 2 0' "$(val status members '') $(val status peers_active '') $(val status peers_unreachable '')"
check 'e1: proposals committed and applied, none waiting' 'yes 0' "$(least status proposals_applied_count '' 2000) $(val status proposals_pending '')"
leaders=0
for m in e1 e2 e3; do use "$m"; quiet status; leaders=$((leaders + $(val status is_leader ''))); done
check 'one leader among the three, as each member says of itself' 1 "$leaders"
use e1
check 'the keys, and the history to compact' 'yes yes' "$(least database keys '' 500) $(least database revisions_kept '' 2000)"
check 'the database, against its quota (2 GiB by default)' '2147483648 yes' "$(val database quota_bytes '') $(has database db_used_pct '')"
check 'the watch held open; the leases expired' 'yes yes' "$(least database watchers '' 1) $(least database leases_expired_count '' 2)"
check "the WAL's fsyncs and the backend's commits, timed" 'yes yes yes' "$(least disk wal_fsyncs_count '' 1) $(has disk wal_fsync_avg_ms '') $(has disk backend_commit_avg_ms '')"
check 'the round trip to its peers' yes "$(has disk peer_rtt_avg_ms '')"
check 'requests handled, by e1' yes "$(least requests requests_count '' 2000)"

say "3.6: the leader stops; the others elect another."
lead=''
for m in e1 e2 e3; do use "$m"; quiet status; [ "$(val status is_leader '')" = 1 ] && lead=$m; done
before=0
for m in e1 e2 e3; do [ "$m" = "$lead" ] && continue; use "$m"; quiet status; before=$(val status leader_changes_count ''); other=$m; break; done
dc stop "$lead" > /dev/null 2>&1
echo "stopped  $lead, the leader"
use "$other"
for _ in $(seq 1 30); do quiet status; [ "$(val status has_leader '')" = 1 ] && [ "$(val status peers_unreachable '')" = 1 ] && break; sleep 1; done
run status "$lead stopped"
check "$other: a new leader, elected; the old one unreachable" '1 1 1' "$(val status has_leader '') $(val status healthy '') $(val status peers_unreachable '')"
check "$other: the leader change counted" yes "$(least status leader_changes_count '' $((before + 1)))"
dc start "$lead" > /dev/null 2>&1
for _ in $(seq 1 30); do healthy "$lead" && break; sleep 1; done

say "3.6: two of three stop. No quorum: no leader, and a write fails."
for _ in $(seq 1 30); do quiet status; [ "$(val status peers_unreachable '')" = 0 ] && break; sleep 1; done
use e1
quiet status
pf=$(val status proposals_failed_count '')
dc stop e2 e3 > /dev/null 2>&1
echo 'stopped  e2 and e3'
for _ in $(seq 1 30); do quiet status; [ "$(val status has_leader '')" = 0 ] && break; sleep 1; done
printf 'lost' | ctl e1 put /app/during > "$work/put.log" 2>&1
grep -o 'desc = [^"]*' "$work/put.log" | head -n 1 | sed 's/^/write    /'
sleep 2
run status 'e2 and e3 stopped'
check 'e1: no leader, not healthy, the two others unreachable' '0 0 2' "$(val status has_leader '') $(val status healthy '') $(val status peers_unreachable '')"
check 'e1: and still up: no leader is a reading' '1 exit 0' "$(val status up '') $(tail -n 1 "$work/status.err")"
check 'e1: the write that failed, counted' yes "$(least status proposals_failed_count '' $((pf + 1)))"
run requests 'e2 and e3 stopped'
check 'e1: the request that failed, by its gRPC code' yes "$(least requests failed_count '' 1)"
dc start e2 e3 > /dev/null 2>&1
for m in e2 e3; do for _ in $(seq 1 30); do healthy "$m" && break; sleep 1; done; done

say "3.5, alone: its database filled to its quota of 32 MiB."
use e35
for j in $jobs; do quiet "$j"; check "e35: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err" 2> /dev/null || echo "exit $?")"; done
quiet status
check 'e35: 3.5, alone, its own leader' 'yes 1 1 0' "$(has status version 'version=3\.5\.') $(val status members '') $(val status is_leader '') $(val status peers_unreachable '')"
head -c 1048576 /dev/zero | tr '\0' x > "$work/mib"
for i in $(seq 1 40); do ctl e35 put "/big/$i" < "$work/mib" > "$work/put.log" 2>&1 || break; done
grep -o 'desc = [^"]*' "$work/put.log" | head -n 1 | sed "s/^/write    MiB $i: /"
ctl e35 alarm list | sed 's/^/alarm    /'
run status 'at its quota'
check 'e35: not healthy, its leader there: an alarm' '0 1' "$(val status healthy '') $(val status has_leader '')"
run database 'at its quota'
check 'e35: the database at its quota' yes "$(least database db_used_pct '' 99)"
run requests 'at its quota'
check 'e35: the write refused, as ResourceExhausted' yes "$(least requests failed 'code=ResourceExhausted' 1)"
rev=$(ctl e35 endpoint status -w fields | awk '/"Revision"/ { print $3 }')
ctl e35 compact "$rev" > /dev/null
ctl e35 defrag > /dev/null 2>&1
ctl e35 alarm disarm > /dev/null
echo "mended   compacted to revision $rev, defragmented, the alarm disarmed"
run status 'mended'
check 'e35: healthy again' 1 "$(val status healthy '')"
run database 'mended'
check 'e35: the space given back' yes "$(awk -v v="$(val database db_used_pct '')" 'BEGIN { print (v + 0 < 99) ? "yes" : "no [" v "]" }')"

say "Nothing listening, and a page that is not there."
ETCD_URL=http://127.0.0.1:12399 bash "$pack/status.sh" > "$work/down.out" 2>&1
check 'nothing listening: up 0, the run succeeding' '0 metric up 0' "$? $(cat "$work/down.out")"
ETCD_URL=http://127.0.0.1:12381/nothing bash "$pack/status.sh" > "$work/missing.out" 2>&1
check 'a page that is not there: up 0, said why' '0 yes' "$? $(grep -q 'no such page' "$work/missing.out" && echo yes || echo no)"

say "The pack through Vigil, against e1 (and, for up 0, a port nothing listens on)."
export VIGIL_IT_OBS_ETCD=ETCD_URL=http://127.0.0.1:12381 VIGIL_IT_OBS_ETCD_DOWN=ETCD_URL=http://127.0.0.1:12399
unset ETCD_URL
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_ETCD_HOLD=<file>: the cluster stays up, for the tests of other
# machines, until <file> is deleted.
if [ -n "${VIGIL_IT_ETCD_HOLD-}" ]; then
    : > "$VIGIL_IT_ETCD_HOLD"
    printf 'hold     the cluster stays up (metrics 12381, 12481, 12581, 12681) until %s is deleted\n' "$VIGIL_IT_ETCD_HOLD"
    while [ -e "$VIGIL_IT_ETCD_HOLD" ]; do sleep 5; done
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
