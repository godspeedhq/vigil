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
# run-rabbitmq.sh - the rabbitmq pack against real RabbitMQ with trouble on
# purpose, with its evidence kept like the other runs'.
#
#   scripts/run-rabbitmq.sh
#
# It starts compose.rabbitmq.yaml: a cluster of three RabbitMQ 4.2 nodes,
# RabbitMQ 4.1 past its memory watermark, and RabbitMQ 3.13 below its free
# disk limit. Then trouble, with RabbitMQ's own PerfTest and rabbitmqadmin:
# a quorum queue its consumer cannot keep up with, a queue nobody reads,
# messages dead-lettered for a queue's length and for their age, messages
# no queue takes, logins refused. Every job of the pack is run and what it
# reads is checked; then a node of the cluster is stopped and read again;
# then tests/integration/service-packs.sh runs the pack through Vigil. The
# nodes are taken down at the end.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: the nodes run in containers'
command -v curl > /dev/null 2>&1 || die 'curl not found: the pack reads its pages with curl'
file=compose.rabbitmq.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-rabbitmq-it.XXXXXX") || exit 1
root=$work/none
export RMQ_WORK=$work
dc() { docker compose -p vigil-rabbitmq --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
cookie=$(openssl rand -hex 20)
trap 'docker rm -f vigil-rabbitmq-perf > /dev/null 2>&1; dc down -v > /dev/null 2>&1; evidence_save "$cookie"; rm -rf "$work"' EXIT
evidence_start pack-rabbitmq "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/rabbitmq/linux
(umask 077 && printf '%s' "$cookie" > "$work/cookie")

dc up -d --wait > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; dc logs --tail 20; die 'the nodes would not start'; }
printf 'nodes    %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | grep -v cookie | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
docker exec vigil-rabbitmq-rmq-a-1 rabbitmqctl -q cluster_status 2>&1 | sed -n '/Running Nodes/,/Versions/p' | grep '^rabbit@' | sed 's/^/         /'

say() { printf '\n# %s\n' "$*"; }
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
most() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 <= a) ? "yes" : "no [" v "]" }'; }

say "Trouble, on the cluster."
net=vigil-rabbitmq_default
admin() { docker exec vigil-rabbitmq-rmq-a-1 rabbitmqadmin --non-interactive "$@" > /dev/null; }
admin declare queue --name idle --durable true
admin declare queue --name dlq --durable true
admin declare queue --name capped --durable true --arguments '{"x-max-length": 10, "x-dead-letter-exchange": "", "x-dead-letter-routing-key": "dlq"}'
admin declare queue --name late --durable true --arguments '{"x-message-ttl": 1000, "x-dead-letter-exchange": "", "x-dead-letter-routing-key": "dlq"}'
for i in $(seq 1 40); do
    admin publish message --routing-key idle --payload "waiting $i"
    admin publish message --routing-key capped --payload "capped $i"
    admin publish message --routing-key late --payload "late $i"
done
# Messages no queue takes, from an AMQP client (RabbitMQ counts a
# protocol's publishes; rabbitmqadmin's, over HTTP, it does not).
docker run --rm --network "$net" pivotalrabbitmq/perf-test:latest --uri amqp://guest:guest@rmq-a:5672 \
    --exchange vigil-nowhere --routing-key nowhere --producers 1 --consumers 0 --pmessages 40 > /dev/null 2>&1
# A quorum queue, fed faster than its one consumer takes from it.
docker run -d --name vigil-rabbitmq-perf --network "$net" pivotalrabbitmq/perf-test:latest \
    --uri amqp://guest:guest@rmq-a:5672 --queue orders --quorum-queue --producers 2 --consumers 1 \
    --rate 100 --consumer-rate 10 --qos 10 --time 900 > /dev/null 2>&1
# Logins refused.
for i in 1 2 3; do
    docker run --rm --network "$net" pivotalrabbitmq/perf-test:latest --uri amqp://guest:not-the-password@rmq-a:5672 --time 2 > /dev/null 2>&1
done
printf 'sent     on rmq-a: 40 messages to a queue nobody reads, 40 to a queue of 10 at most, 40 that expire, 40 no queue takes; 3 logins refused; a quorum queue fed 200 a second, read 10 a second\n'
sleep 60

targets='a=http://127.0.0.1:15691; b=http://127.0.0.1:15692; c=http://127.0.0.1:15693; v41=http://127.0.0.1:15694; v313=http://127.0.0.1:15695'
export RABBITMQ_TARGETS=$targets
say "Every job, as the pack's scripts print it."
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/rabbitmq/pack.config")
for j in $jobs; do
    printf '\n$ bash packs/rabbitmq/linux/%s.sh\n' "$j"
    bash "$pack/$j.sh" > "$work/$j.out" 2> "$work/$j.err"
    printf 'exit %s\n' "$?" >> "$work/$j.err"
    cat "$work/$j.out"
    grep -v '^exit 0$' "$work/$j.err"
done

say "What they read."
for j in $jobs; do check "rabbitmq: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
for t in a:4.2 b:4.2 c:4.2 v41:4.1 v313:3.13; do
    n=${t%%:*} v=${t#*:}
    check "$n: answers" 1 "$(val status up "node=$n\$")"
    check "$n: RabbitMQ $v" yes "$(grep -qE "^metric version 1 node=$n rabbitmq=${v//./\\.}\." "$work/status.out" && echo yes || echo no)"
done
check 'a: in a cluster of three' 2 "$(val cluster peers 'node=a$')"
check 'a: its links to b and c up' 2 "$(grep -c '^metric peer_up 1 node=a peer=rabbit@rmq-[bc]$' "$work/cluster.out")"
check 'a: no peer unreachable' 0 "$(val status unreachable_peers 'node=a$')"
check 'v41: past its memory watermark: the memory alarm on' 1 "$(val status alarm_memory 'node=v41$')"
check 'v41: memory_pct past 100' yes "$(least status memory_pct 'node=v41$' 100)"
check 'v313: below its free disk limit: the disk alarm on' 1 "$(val status alarm_disk 'node=v313$')"
check 'a: no alarm, memory or disk' 00 "$(val status alarm_memory 'node=a$')$(val status alarm_disk 'node=a$')"
check 'a: the queue nobody reads, 40 waiting' 40 "$(val queues messages 'node=a vhost=/ queue=idle ')"
check 'a: counted without consumers' yes "$(least queues without_consumers 'node=a$' 1)"
check 'a: the quorum queue the deepest' orders "$(grep -E '^metric messages [^ ]+ node=a ' "$work/queues.out" | head -n 1 | sed 's/.* queue=\([^ ]*\) .*/\1/')"
check 'a: and of type quorum' 1 "$(grep -c '^metric messages [^ ]* node=a vhost=/ queue=orders type=quorum$' "$work/queues.out")"
check 'a: its consumer, slow: thousands ready' yes "$(least queues ready 'node=a vhost=/ queue=orders ' 2000)"
check 'a: the queue of 10 at most holds 10' 10 "$(val queues messages 'node=a vhost=/ queue=capped ')"
check 'a: the others dead-lettered, for its length' yes "$(least traffic dead_lettered_count 'node=a reason=maxlen' 30)"
check 'a: and those that expired' yes "$(least traffic dead_lettered_count 'node=a reason=expired' 40)"
check 'a: into the dead letter queue' yes "$(least queues messages 'node=a vhost=/ queue=dlq ' 70)"
check 'a: messages no queue took, dropped' yes "$(least traffic unroutable_dropped_count 'node=a$' 40)"
check 'a: logins refused' yes "$(least traffic logins_failed_count 'node=a$' 3)"
check 'a: messages delivered and acknowledged' yes "$(least traffic acknowledged_count 'node=a$' 100)"
check 'b and c: the quorum queue counted once, by its leader' 0 "$(grep -c '^metric messages [^ ]* node=[bc] vhost=/ queue=orders ' "$work/queues.out")"
check 'the quorum queue: a copy on each node' 3 "$(grep -c '^metric term [^ ]* node=[abc] vhost=/ queue=orders role=' "$work/quorum.out")"
check 'the quorum queue: one leader' 1 "$(grep -c '^metric term [^ ]* node=[abc] vhost=/ queue=orders role=leader$' "$work/quorum.out")"
check 'the metadata store on each node' 3 "$(grep -c '^metric term [^ ]* node=[abc] system=rabbit_khepri$' "$work/quorum.out")"
check 'a: its memory, quorum queues among it' yes "$(least memory quorum_queues_bytes 'node=a$' 1)"
check 'a: 4.2 does not count its file I/O' 0 "$(val storage counted 'node=a$')"
check 'v313: 3.13 does' 1 "$(val storage counted 'node=v313$')"

say "A node of the cluster stopped."
dc stop rmq-c > /dev/null 2>&1
sleep 20
bash "$pack/status.sh" > "$work/stopped-status.out" 2>&1
bash "$pack/cluster.sh" > "$work/stopped-cluster.out" 2>&1
cat "$work/stopped-status.out" | grep -E 'up |unreachable' ; grep -E 'node=a ' "$work/stopped-cluster.out" | grep -E 'peers|peer_up'
check 'c: reads as up 0' yes "$(grep -q '^metric up 0 node=c$' "$work/stopped-status.out" && echo yes || echo no)"
check 'a: c unreachable, or gone from its links' yes "$(grep -qE '^metric unreachable_peers [1-9] node=a$' "$work/stopped-status.out" || ! grep -q '^metric peer_up 1 node=a peer=rabbit@rmq-c$' "$work/stopped-cluster.out" && echo yes || echo no)"
dc up -d --wait rmq-c > /dev/null 2>&1

say "The pack through Vigil."
export VIGIL_IT_RABBITMQ_TARGETS=$targets
unset RABBITMQ_TARGETS
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
