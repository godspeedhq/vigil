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
# run-zookeeper.sh - the zookeeper pack against a real ensemble in trouble
# on purpose, with its evidence kept like the other runs'.
#
#   scripts/run-zookeeper.sh
#
# It starts compose.zookeeper.yaml: a 3.9.7 ensemble of three, a 3.8.8
# server, and a 3.9.7 server left with the default whitelist. With zkCli,
# in the ensemble: 200 znodes and one of 100 KB, and a client session held
# open with an ephemeral znode and two watches. The job is run against the
# ensemble and 3.8.8, and what it reads is checked; then the server that
# refuses the words, and nothing listening. Then
# tests/integration/service-packs.sh runs the pack through Vigil. Then the
# ensemble falls apart: a follower stops; the leader stops (an election);
# two stop, leaving zk3 (it serves nothing), then leaving zk1 (read-only
# mode). VIGIL_IT_ZK_HOLD (below) keeps it up for other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: ZooKeeper runs in containers'
file=compose.zookeeper.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-zk-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-zk --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
holder=''
trap 'exec 7>&- 2> /dev/null; [ -z "$holder" ] || wait "$holder" 2> /dev/null; dc down -v > /dev/null 2>&1; evidence_save; rm -rf "$work"' EXIT
evidence_start pack-zookeeper "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/zookeeper/linux

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'ZooKeeper would not start'; }
ens='127.0.0.1:12181; 127.0.0.1:12182; 127.0.0.1:12183'
all="$ens; 127.0.0.1:12188"

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }
# run <name> <servers> [<label>]: the job against those servers, its output
# shown and kept as <name>.
run() {
    printf '\n$ ZOOKEEPER_SERVERS=%s bash packs/zookeeper/linux/status.sh%s\n' "$2" "${3:+   ($3)}"
    ZOOKEEPER_SERVERS=$2 bash "$pack/status.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    cat "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err"
}
quiet() { ZOOKEEPER_SERVERS=$2 bash "$pack/status.sh" > "$work/$1.out" 2> /dev/null; }
# The server of the ensemble that leads, by its container: zk1, zk2, zk3.
leader() { quiet lead "$ens"; sed -n 's/^metric info 1 server=127.0.0.1:1218\([123]\) .*role=leader$/zk\1/p' "$work/lead.out"; }
port() { echo "127.0.0.1:1218${1#zk}"; }
for _ in $(seq 1 60); do quiet ready "$all"; [ "$(val ready servers_serving '')" = 4 ] && [ "$(val ready leaders '')" = 1 ] && break; sleep 2; done
[ "$(val ready servers_serving '')" = 4 ] || { dc logs --tail 20; die 'the ensemble did not form'; }
printf 'zookeeper  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say "The ensemble in use, with zkCli on zk1: znodes, a large one, a session holding an ephemeral znode and two watches."
big=$(head -c 75000 /dev/urandom | base64 | tr -d '\n' | head -c 100000)
{
    echo 'create /app root'
    for i in $(seq 1 200); do echo "create /app/n$i v$i"; done
    echo "create /app/big $big"
    echo quit
} | docker exec -i vigil-zk-zk1-1 zkCli.sh -server localhost:2181 > "$work/cli.log" 2>&1
echo 'znodes   /app, 200 children, and /app/big of 100,000 bytes'
mkfifo "$work/hold"
docker exec -i vigil-zk-zk1-1 zkCli.sh -server localhost:2181 < "$work/hold" > "$work/held.log" 2>&1 &
holder=$!
exec 7> "$work/hold"
printf 'create -e /app/lock held\nget -w /app/n1\nls -w /app\n' >&7
for _ in $(seq 1 30); do quiet use "$ens"; [ "$(least use ephemerals 'server=127.0.0.1:12181' 1)" = yes ] && break; sleep 1; done
echo 'session  one held open on zk1: an ephemeral znode (/app/lock), a watch on /app/n1 and one on /app'

say "The ensemble and 3.8.8: the job, as the pack's script prints it."
run all "$all"
lead=$(leader)
lp=$(port "$lead")
check 'the job runs' 'exit 0' "$(tail -n 1 "$work/all.err")"
check 'four servers, all up and serving, one leader' '4 4 4 1' "$(val all servers '') $(val all servers_up '') $(val all servers_serving '') $(val all leaders '')"
check 'the ensemble: its versions and roles' 'yes yes 2' "$(has all info "server=$lp version=3\.9\.7 role=leader") $(has all info 'server=127.0.0.1:12188 version=3\.8\.8 role=standalone') $(grep -c 'version=3\.9\.7 role=follower$' "$work/all.out")"
check 'the leader: both followers in sync, none pending' '2 2 0' "$(val all followers "server=$lp") $(val all followers_synced "server=$lp") $(val all pending_syncs "server=$lp")"
check 'the quorum: three' 3 "$(val all quorum_size "server=$lp")"
check 'none read-only' 0 "$(grep '^metric readonly ' "$work/all.out" | awk '{ s += $3 } END { print s + 0 }')"
for p in 12181 12182 12183; do
    check "127.0.0.1:$p: the 200 znodes and more, and the 100 KB in its data" 'yes yes' "$(least all znodes "server=127.0.0.1:$p" 205) $(least all data_bytes "server=127.0.0.1:$p" 100000)"
done
check 'the ephemeral znode, on every server of the ensemble' '1 1 1' "$(val all ephemerals 'server=127.0.0.1:12181') $(val all ephemerals 'server=127.0.0.1:12182') $(val all ephemerals 'server=127.0.0.1:12183')"
check 'the two watches, on zk1, where the session is' 'yes yes' "$(least all watches 'server=127.0.0.1:12181' 2) $(least all connections 'server=127.0.0.1:12181' 2)"
check 'file descriptors: open, and their share' 'yes yes' "$(least all fds_open 'server=127.0.0.1:12181' 1) $(has all fds_pct 'server=127.0.0.1:12181')"
check 'fsync and JVM pauses read' 'yes yes' "$(has all fsync_max_ms "server=$lp") $(has all jvm_pause_max_ms "server=$lp")"
check 'uptime, latency, packets' 'yes yes yes' "$(least all uptime_seconds "server=$lp" 1) $(has all latency_avg_ms "server=$lp") $(least all packets_received_count 'server=127.0.0.1:12181' 1)"

say "A server with the default whitelist (srvr alone), and nothing listening."
run refused "127.0.0.1:12189; 127.0.0.1:12188"
check 'refused: the run fails' 'exit 1' "$(tail -n 1 "$work/refused.err")"
check 'and names the server, the words, and the setting' yes "$(grep -q '127.0.0.1:12189 refuses ruok, mntr: add the words to its whitelist in zoo.cfg, 4lw.commands.whitelist=mntr,ruok,isro' "$work/refused.err" && echo yes || echo no)"
check 'it answers (up 1), and serves nothing to the pack (serving 0)' '1 0' "$(val refused up 'server=127.0.0.1:12189') $(val refused serving 'server=127.0.0.1:12189')"
check 'the other server is read all the same' 1 "$(val refused serving 'server=127.0.0.1:12188')"
run down '127.0.0.1:12199'
check 'nothing listening: the run succeeds, up 0' 'exit 0 0 0' "$(tail -n 1 "$work/down.err") $(val down up '') $(val down servers_up '')"
ZOOKEEPER_SERVERS='zk1:abc' bash "$pack/status.sh" > "$work/bad.out" 2>&1
check 'a server that is not host:port: the run fails, saying so' '1 yes' "$? $(grep -q "is not host or host:port" "$work/bad.out" && echo yes || echo no)"

say "The pack through Vigil."
export VIGIL_IT_ZOOKEEPER_SERVERS=$all
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_ZK_HOLD=<file>: the ensemble stays up for the tests of other
# machines (macOS, Windows), until <file> is deleted.
if [ -n "${VIGIL_IT_ZK_HOLD-}" ]; then
    : > "$VIGIL_IT_ZK_HOLD"
    printf 'hold     the ensemble stays up, on 12181-12183, 12188 and 12189, until %s is deleted\n' "$VIGIL_IT_ZK_HOLD"
    while [ -e "$VIGIL_IT_ZK_HOLD" ]; do sleep 5; done
fi
exec 7>&-
wait "$holder" 2> /dev/null
holder=''

lead=$(leader)
fol=zk1; [ "$lead" = zk1 ] && fol=zk2
say "A follower stops: $fol."
dc stop "$fol" > /dev/null 2>&1
for _ in $(seq 1 30); do quiet ens "$ens"; [ "$(val ens followers_synced "server=$(port "$lead")")" = 1 ] && break; sleep 2; done
run ens "$ens" "$fol stopped"
check "$fol stopped: two of three up and serving, still one leader" '3 2 2 1' "$(val ens servers '') $(val ens servers_up '') $(val ens servers_serving '') $(val ens leaders '')"
check "$fol stopped: the leader has one follower in sync" 1 "$(val ens followers_synced "server=$(port "$lead")")"
dc start "$fol" > /dev/null 2>&1
for _ in $(seq 1 30); do quiet ens "$ens"; [ "$(val ens servers_serving '')" = 3 ] && break; sleep 2; done

lead=$(leader)
# elect <out>: the elections the servers other than $lead have counted.
elect() { grep '^metric elections_count ' "$work/$1.out" | grep -v "server=$(port "$lead")\$" | awk '{ s += $3 } END { print s + 0 }'; }
before=$(elect ens)
say "The leader stops: $lead. The others elect another."
dc stop "$lead" > /dev/null 2>&1
for _ in $(seq 1 45); do quiet ens "$ens"; [ "$(val ens leaders '')" = 1 ] && [ "$(val ens servers_serving '')" = 2 ] && break; sleep 2; done
run ens "$ens" "$lead stopped"
new=$(sed -n 's/^metric info 1 server=127.0.0.1:1218\([123]\) .*role=leader$/zk\1/p' "$work/ens.out")
check "$lead stopped: a new leader, not $lead" 'yes 1' "$([ -n "$new" ] && [ "$new" != "$lead" ] && echo yes || echo "no [$new]") $(val ens leaders '')"
after=$(elect ens)
check "$lead stopped: the other two looked for a leader again (elections_count rose)" yes "$([ "$after" -gt "$before" ] && echo yes || echo "no [$before, then $after]")"
dc start "$lead" > /dev/null 2>&1
for _ in $(seq 1 30); do quiet ens "$ens"; [ "$(val ens servers_serving '')" = 3 ] && break; sleep 2; done

say "Two stop, leaving zk3, which has read-only mode off: it answers, and serves nothing."
dc stop zk1 zk2 > /dev/null 2>&1
for _ in $(seq 1 30); do quiet ens "$ens"; [ "$(val ens servers_up '')" = 1 ] && [ "$(val ens servers_serving '')" = 0 ] && break; sleep 2; done
run ens "$ens" 'zk1 and zk2 stopped'
check 'no quorum: zk3 up, serving nothing; no leader; the run succeeds' 'exit 0 1 0 0' "$(tail -n 1 "$work/ens.err") $(val ens up 'server=127.0.0.1:12183') $(val ens serving 'server=127.0.0.1:12183') $(val ens leaders '')"
dc start zk1 zk2 > /dev/null 2>&1
for _ in $(seq 1 45); do quiet ens "$ens"; [ "$(val ens servers_serving '')" = 3 ] && break; sleep 2; done

say "Two stop, leaving zk1, which has read-only mode on: it serves reads, and refuses writes."
dc stop zk2 zk3 > /dev/null 2>&1
for _ in $(seq 1 30); do quiet ens "$ens"; [ "$(val ens readonly 'server=127.0.0.1:12181')" = 1 ] && break; sleep 2; done
run ens "$ens" 'zk2 and zk3 stopped'
check 'read-only: zk1 serving, read-only, its role readonly; no leader' '1 1 yes 0' "$(val ens serving 'server=127.0.0.1:12181') $(val ens readonly 'server=127.0.0.1:12181') $(has ens info 'server=127.0.0.1:12181 .*role=readonly') $(val ens leaders '')"
dc start zk2 zk3 > /dev/null 2>&1

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
