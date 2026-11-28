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
# run-nats.sh - the nats pack against real NATS servers in trouble on
# purpose, with its evidence kept like the other runs'.
#
#   scripts/run-nats.sh
#
# It starts compose.nats.yaml: a JetStream cluster of three NATS 2.15
# servers, a NATS 2.14 alone with little storage and few connections, and a
# NATS 2.15 with neither JetStream nor a cluster. With nats-box it makes, on
# the cluster, a stream of orders with a consumer behind, its messages
# fetched and not acked, then redelivered; a stream with a 64 KB limit,
# filled; and a client that subscribes and stops reading, which the server
# cuts off. On the 2.14 server, a stream that fills its storage, and 15
# clients of the 20 it allows. Each job runs against each server, and what it
# read is checked. Then a server of the cluster stops (its peers say which;
# its replicas fall behind), then a second (the cluster loses its majority:
# no meta leader, streams with no leader, not healthy), and both start again.
# Then tests/integration/service-packs.sh runs the pack through Vigil.
# VIGIL_IT_NATS_HOLD (below) keeps them up for other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: NATS runs in containers'
for p in curl jq; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
file=compose.nats.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-nats-it.XXXXXX") || exit 1
root=$work/none
export NATS_CONF=$work/conf
mkdir -p "$NATS_CONF"
dc() { docker compose -p vigil-nats --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
box=natsio/nats-box:${NATS_BOX_VERSION:-0.20.2}
# nb <script>: a script in nats-box, on the compose network.
nb() { docker run --rm --network vigil-nats_default "$box" sh -c "$1"; }
trap 'docker rm -f vigil-nats-stuck vigil-nats-clients > /dev/null 2>&1; dc down -v > /dev/null 2>&1; evidence_save; rm -rf "$work"' EXIT

for n in n1 n2 n3; do
    cat > "$NATS_CONF/$n.conf" << EOF
server_name: $n
listen: 0.0.0.0:4222
http: 0.0.0.0:8222
max_pending: 1MB
jetstream { store_dir: /data }
cluster {
  name: c1
  listen: 0.0.0.0:6222
  routes: [$(for o in n1 n2 n3; do [ "$o" = "$n" ] || printf 'nats://%s:6222, ' "$o"; done | sed 's/, $//')]
}
EOF
done
cat > "$NATS_CONF/s14.conf" << 'EOF'
server_name: s14
listen: 0.0.0.0:4222
http: 0.0.0.0:8222
max_connections: 20
jetstream { store_dir: /data, max_file_store: 2MB, max_memory_store: 1MB }
EOF
chmod 755 "$NATS_CONF"
chmod 644 "$NATS_CONF"/*
evidence_start pack-nats "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/nats/linux
[ "$(uname -s)" = Darwin ] && pack=$bk_repo/packs/nats/macos

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'NATS would not start'; }
for p in 18222 18223 18224 18232 18242; do
    for _ in $(seq 1 60); do curl -sf -o /dev/null "http://127.0.0.1:$p/healthz" && break; sleep 1; done
    curl -sf -o /dev/null "http://127.0.0.1:$p/healthz" || { dc logs --tail 20; die "NATS on $p never became healthy"; }
done
printf 'nats     %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
docker pull -q "$box" > /dev/null 2>&1

# The trouble, made with the nats CLI.
c='nats -s nats://n1:4222'
nb "$c stream add ORDERS --subjects='orders.>' --replicas=3 --storage=file --defaults > /dev/null &&
    $c consumer add ORDERS billing --pull --ack=explicit --wait=2s --defaults > /dev/null &&
    $c pub orders.new --count=500 'order {{Count}}' > /dev/null 2>&1 &&
    $c consumer next ORDERS billing --count=50 --no-ack > /dev/null 2>&1 && sleep 3 &&
    $c consumer next ORDERS billing --count=50 --no-ack > /dev/null 2>&1 &&
    $c stream add LIMITED --subjects='limited.>' --replicas=3 --storage=file --max-bytes=64KB --discard=new --defaults > /dev/null &&
    head -c 1024 /dev/zero | tr '\\0' x > /tmp/kb && $c pub limited.x --count=200 \"\$(cat /tmp/kb)\" > /dev/null 2>&1; echo made" > "$work/made.log" 2>&1
grep -q made "$work/made.log" || { cat "$work/made.log"; die 'the streams could not be made'; }
echo 'cluster  ORDERS (R3): 500 orders, consumer billing fetched 50 without acking, then 50 again after its 2s ack wait; LIMITED (R3, 64 KB, discard new): 200 KB sent'
# A client that subscribes and stops reading: its output goes to a pipe
# nobody reads.
docker run -d --name vigil-nats-stuck --network vigil-nats_default "$box" sh -c \
    '(printf "CONNECT {\"verbose\":false,\"name\":\"stuck-reader\"}\r\nSUB firehose 1\r\n"; sleep 600) | nc n1 4222 | sleep 600' > /dev/null
sleep 2
nb "head -c 2048 /dev/zero | tr '\\0' y > /tmp/kb && $c pub firehose --count=4000 \"\$(cat /tmp/kb)\" > /dev/null 2>&1; echo sent" > /dev/null 2>&1
echo 'slow     stuck-reader subscribed to firehose on n1 and never read; 8 MB published to it'
s='nats -s nats://s14:4222'
nb "$s stream add BIG --subjects='big.>' --storage=file --defaults > /dev/null && head -c 4096 /dev/zero | tr '\\0' z > /tmp/kb && $s pub big.x --count=1000 \"\$(cat /tmp/kb)\" > /dev/null 2>&1; echo made" > /dev/null 2>&1
docker run -d --name vigil-nats-clients --network vigil-nats_default "$box" sh -c \
    'for i in $(seq 1 15); do nats -s nats://s14:4222 sub "idle.$i" > /dev/null 2>&1 & done; sleep 3600' > /dev/null
sleep 5
echo 's14      BIG: 4 MB published into 2 MB of storage; 15 clients of the 20 allowed'

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
# val <out> <metric> [<tag text>]: the first value; sum <metric> [<tag
# text>] <outs...>: added up.
val() { grep -E "^metric $2 [^ ]+( .*)?${3-}" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$1" -v a="$2" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
sumof() { local m=$1 t=$2; shift 2; cat "${@/#/$work/}" | awk -v m="$m" -v t="$t" '$1 == "metric" && $2 == m && index($0, t) { s += $3 } END { print s + 0 }'; }
run() {
    printf '\n$ NATS_URL=%s bash packs/nats/linux/%s.sh%s\n' "$NATS_URL" "$1" "${3:+   ($3)}"
    bash "$pack/$1.sh" > "$work/$2.out" 2> "$work/$2.err"
    printf 'exit %s\n' "$?" >> "$work/$2.err"
    grep -v '_not_shown 0$' "$work/$2.out"
    grep -v '^exit 0$' "$work/$2.err"
}
quiet() { NATS_URL=http://127.0.0.1:$1 bash "$pack/$2.sh" > "$work/$3.out" 2> /dev/null; }

say "The cluster, NATS 2.15: every job on each of its three servers."
for p in 18222 18223 18224; do
    export NATS_URL=http://127.0.0.1:$p
    for j in status cluster jetstream; do run "$j" "$j-$p"; done
done
say "What they read."
for p in 18222 18223 18224; do
    for j in status cluster jetstream; do check "$p: $j runs" 'exit 0' "$(tail -n 1 "$work/$j-$p.err")"; done
done
check 'each healthy, 2.15.3, in cluster c1, JetStream on' '1 1 1 yes' "$(val status-18222 healthy) $(val status-18223 healthy) $(val status-18224 healthy) $(grep -q 'server=n1 version=2.15.3 cluster=c1 jetstream=on' "$work/status-18222.out" && echo yes || echo no)"
check 'each has routes to the other two, named' '2 2 2 yes' "$(val cluster-18222 route_peers) $(val cluster-18223 route_peers) $(val cluster-18224 route_peers) $(grep -q 'route_peer 1 peer=n2' "$work/cluster-18222.out" && grep -q 'route_peer 1 peer=n3' "$work/cluster-18222.out" && echo yes || echo no)"
check 'one meta leader, which has no server behind' '1 0' "$(sumof meta_is_leader '' jetstream-18222.out jetstream-18223.out jetstream-18224.out) $(sumof meta_replicas_behind '' jetstream-18222.out jetstream-18223.out jetstream-18224.out)"
check 'each stream counted once, by its leader' '2 1 1' "$(sumof streams_led '' jetstream-18222.out jetstream-18223.out jetstream-18224.out) $(sumof stream_messages stream=ORDERS jetstream-18222.out jetstream-18223.out jetstream-18224.out | awk '{ print ($1 == 500) }') $(sumof consumers_led '' jetstream-18222.out jetstream-18223.out jetstream-18224.out)"
check 'billing: 450 not given yet, 50 waiting for acks, redelivered, named' '450 50 yes' "$(sumof consumer_pending 'stream=ORDERS consumer=billing' jetstream-18222.out jetstream-18223.out jetstream-18224.out) $(sumof consumer_ack_pending 'consumer=billing' jetstream-18222.out jetstream-18223.out jetstream-18224.out) $(least "$(sumof consumer_redelivered 'consumer=billing' jetstream-18222.out jetstream-18223.out jetstream-18224.out)" 1)"
check 'LIMITED: at its 64 KB, by its leader' yes "$(least "$(sumof stream_used_pct stream=LIMITED jetstream-18222.out jetstream-18223.out jetstream-18224.out)" 90)"
check 'the client that stopped reading: cut off, as a slow client' 'yes yes' "$(least "$(val status-18222 slow_consumers_count)" 1) $(least "$(val status-18222 slow_consumer_clients_count)" 1)"

say "NATS 2.14 alone, JetStream with 2 MB of file storage and 20 connections at most."
export NATS_URL=http://127.0.0.1:18232
for j in status cluster jetstream; do run "$j" "$j-18232"; done
for j in status cluster jetstream; do check "2.14: $j runs" 'exit 0' "$(tail -n 1 "$work/$j-18232.err")"; done
check '2.14: its version; alone' 'yes 0' "$(grep -q 'version=2.14.10 cluster=none jetstream=on' "$work/status-18232.out" && echo yes || echo no) $(val cluster-18232 clustered)"
check '2.14: 15 clients or more, of 20: 75% or more' 'yes yes' "$(least "$(val status-18232 connections)" 15) $(least "$(val status-18232 connections_pct)" 75)"
check '2.14: its storage nearly full' yes "$(least "$(val jetstream-18232 storage_pct)" 80)"
check '2.14: alone, it leads its stream; no meta cluster' '1 no' "$(val jetstream-18232 streams_led) $(grep -q meta_ "$work/jetstream-18232.out" && echo yes || echo no)"

say "NATS 2.15 with neither JetStream nor a cluster."
export NATS_URL=http://127.0.0.1:18242
for j in status cluster jetstream; do run "$j" "$j-18242"; done
check 'plain: JetStream off, alone; each job says so and stops' 'jetstream=off 0 0' "$(grep -o 'jetstream=off' "$work/status-18242.out") $(val cluster-18242 clustered) $(val jetstream-18242 jetstream)"

say "A server of the cluster, n3, stops."
dc stop n3 > /dev/null 2>&1
for _ in $(seq 1 60); do
    quiet 18222 cluster c1
    quiet 18222 jetstream j1
    quiet 18223 jetstream j2
    [ "$(val c1 route_peers)" = 1 ] && [ "$(sumof stream_replicas_behind '' j1.out j2.out)" -ge 2 ] && break
    sleep 2
done
export NATS_URL=http://127.0.0.1:18222
run cluster c1 'n3 stopped'
run jetstream j1 'n3 stopped'
export NATS_URL=http://127.0.0.1:18223
run jetstream j2 'n3 stopped'
check 'n3 stopped: n1 has one peer, n2' '1 yes' "$(val c1 route_peers) $(grep -q 'route_peer 1 peer=n2' "$work/c1.out" && echo yes || echo no)"
check 'n3 stopped: its replica behind on both streams, named' 'yes yes' "$(grep -h 'stream_behind 1 stream=ORDERS replica=n3' "$work/j1.out" "$work/j2.out" | grep -c . | awk '{ print ($1 == 1) ? "yes" : "no" }') $(grep -h 'stream_behind 1 stream=LIMITED replica=n3' "$work/j1.out" "$work/j2.out" | grep -c . | awk '{ print ($1 == 1) ? "yes" : "no" }')"
check 'n3 stopped: still a meta leader; the streams have leaders' '1 0' "$(sumof meta_is_leader '' j1.out j2.out) $(sumof streams_no_leader '' j1.out j2.out)"

say "A second, n2, stops: n1 is alone, a minority."
dc stop n2 > /dev/null 2>&1
for _ in $(seq 1 60); do quiet 18222 jetstream j1; [ "$(val j1 meta_leader_known)" = 0 ] && [ "$(val j1 streams_no_leader)" = 2 ] && break; sleep 2; done
for _ in $(seq 1 30); do quiet 18222 status s1; [ "$(val s1 healthy)" = 0 ] && break; sleep 2; done
export NATS_URL=http://127.0.0.1:18222
run status s1 'n2 and n3 stopped'
run jetstream j1 'n2 and n3 stopped'
check 'a minority: no meta leader; both streams with no leader; not healthy' '0 2 0' "$(val j1 meta_leader_known) $(val j1 streams_no_leader) $(val s1 healthy)"

say "Both start again."
dc start n2 n3 > /dev/null 2>&1
for _ in $(seq 1 90); do
    quiet 18222 jetstream j1; quiet 18223 jetstream j2; quiet 18224 jetstream j3; quiet 18222 status s1
    [ "$(sumof meta_is_leader '' j1.out j2.out j3.out)" = 1 ] && [ "$(sumof stream_replicas_behind '' j1.out j2.out j3.out)" = 0 ] && [ "$(sumof streams_led '' j1.out j2.out j3.out)" = 2 ] && [ "$(val s1 healthy)" = 1 ] && break
    sleep 2
done
check 'together again: one meta leader, the streams led, no replica behind, healthy' '1 2 0 1' "$(sumof meta_is_leader '' j1.out j2.out j3.out) $(sumof streams_led '' j1.out j2.out j3.out) $(sumof stream_replicas_behind '' j1.out j2.out j3.out) $(val s1 healthy)"

say "Nothing listening."
for j in status cluster jetstream; do
    NATS_URL=http://127.0.0.1:18299 bash "$pack/$j.sh" > "$work/down.out" 2>&1
    check "nothing listening: $j: up 0, the run succeeding" '0 metric up 0' "$? $(cat "$work/down.out")"
done

say "The pack through Vigil, against n1 (and, for up 0, a port nothing listens on)."
export VIGIL_IT_OBS_NATS=NATS_URL=http://127.0.0.1:18222 VIGIL_IT_OBS_NATS_DOWN=NATS_URL=http://127.0.0.1:18299
unset NATS_URL
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_NATS_HOLD=<file>: NATS stays up for the tests of other machines,
# until <file> is deleted.
if [ -n "${VIGIL_IT_NATS_HOLD-}" ]; then
    : > "$VIGIL_IT_NATS_HOLD"
    printf 'hold     NATS stays up (18222 to 18224, 18232, 18242) until %s is deleted\n' "$VIGIL_IT_NATS_HOLD"
    while [ -e "$VIGIL_IT_NATS_HOLD" ]; do sleep 5; done
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
