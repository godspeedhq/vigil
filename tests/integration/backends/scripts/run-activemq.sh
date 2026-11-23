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
# run-activemq.sh - the activemq pack against real ActiveMQ Classic brokers
# with trouble on purpose, with its evidence kept like the other runs'.
#
#   scripts/run-activemq.sh
#
# It makes a TLS certificate from a CA of its own and a JMX password of the
# run's own, and starts compose.activemq.yaml's brokers: 5.18, 5.19 and 6.2,
# the first bridged to the last. Then trouble, on each, with ActiveMQ's own
# producer and consumer: a queue backed up with nobody reading it, two
# smaller ones, messages that expire into ActiveMQ.DLQ, a durable
# subscriber that went away with messages kept for it, a slow consumer
# holding messages in flight, and producers held back by flow control. Every
# job of the pack is run and what it reads is checked; then
# tests/integration/service-packs.sh runs the pack through Vigil; then every
# job again on a JRE. The brokers are taken down at the end.
#
# VIGIL_IT_ACTIVEMQ_JRE, VIGIL_IT_ACTIVEMQ_JDK and VIGIL_IT_ACTIVEMQ_HOLD as
# run-tomcat.sh's.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v java > /dev/null 2>&1 || die 'java not found: the pack runs the probe with Java 11 or later'
file=compose.activemq.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-activemq-it.XXXXXX") || exit 1
root=$work/none
export ACTIVEMQ_TLS_DIR=$work/tls
dc() { docker compose -p vigil-activemq --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
pw=$(openssl rand -hex 16)
kspw=$(openssl rand -hex 16)
export ACTIVEMQ_JMX_PASSWORD=$pw ACTIVEMQ_KS_PASSWORD=$kspw
trap 'dc down -v > /dev/null 2>&1; evidence_save "$pw" "$kspw"; rm -rf "$work"' EXIT

tls=$work/tls
mkdir -p "$tls"
(
    cd "$tls" || exit 1
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 -subj '/CN=Vigil test CA' > /dev/null 2>&1 &&
        openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj '/CN=localhost' > /dev/null 2>&1 &&
        printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > server.ext &&
        openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 2 -extfile server.ext > /dev/null 2>&1 &&
        KS=$kspw openssl pkcs12 -export -in server.crt -inkey server.key -name jmx -out server.p12 -passout env:KS > /dev/null 2>&1 &&
        chmod 644 server.p12 ca.crt
) || die 'cannot make the test certificate'

evidence_start pack-activemq "$bk_dir/$file" "$0" "$@"
pack=$work/pack
mkdir -p "$pack" && cp "$bk_repo/packs/activemq/pack.config" "$bk_repo/packs/activemq/linux"/* "$pack/" || die 'cannot copy the pack'
JAVA_HOME=${VIGIL_IT_ACTIVEMQ_JDK:-${JAVA_HOME-}} bash "$bk_repo/tools/release/client-jar.sh" "$pack" > "$work/jars.log" 2>&1 ||
    { cat "$work/jars.log"; die 'cannot build the pack'"'"'s jar'; }
sed 's/^client-jar: [^ ]*\/\(_[a-z]*\.jar\)/jar      \1/' "$work/jars.log"
printf 'java     %s\n' "$(java -version 2>&1 | head -n 1)"
[ -z "${VIGIL_IT_ACTIVEMQ_JRE-}" ] || printf 'jre      %s (%s)\n' "$("$VIGIL_IT_ACTIVEMQ_JRE/bin/java" -version 2>&1 | head -n 1)" "$VIGIL_IT_ACTIVEMQ_JRE"

dc up -d > "$work/up.log" 2>&1 || { cat "$work/up.log"; die 'the brokers would not start'; }
for _ in $(seq 1 60); do
    up=0
    for s in a518 a519 a62; do dc logs "$s" 2> /dev/null | grep -q 'Apache ActiveMQ .* started' && up=$((up + 1)); done
    [ "$up" -eq 3 ] && break
    sleep 3
done
[ "$up" -eq 3 ] || { dc logs --tail 30; die "only $up of 3 brokers started"; }
printf 'brokers  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+ .*$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
# ActiveMQ's own tools, in the broker's container, never waiting for ever.
amq() { local s=$1; shift; dc exec -T "$s" timeout "$@" > /dev/null 2>&1; }

say "Trouble, on each broker."
for s in a518 a519 a62; do
    u=tcp://localhost:61616
    amq "$s" 120 activemq producer --brokerUrl $u --destination queue://orders --messageCount 3000
    amq "$s" 60 activemq producer --brokerUrl $u --destination queue://invoices --messageCount 300
    amq "$s" 60 activemq producer --brokerUrl $u --destination queue://refunds --messageCount 30
    amq "$s" 60 activemq producer --brokerUrl $u --destination queue://late --messageCount 50 --msgTTL 2000
    amq "$s" 15 activemq consumer --brokerUrl $u --destination topic://prices --durable true --clientId sub-billing --messageCount 1
    amq "$s" 60 activemq producer --brokerUrl $u --destination topic://prices --messageCount 500
    # Flow control: non-persistent messages into a queue of 1 MB, nobody reading.
    amq "$s" 25 activemq producer --brokerUrl $u --destination queue://bulk --persistent false --messageSize 10000 --messageCount 100000
    # And another, kept connected while the jobs run: held back now.
    dc exec -T -d "$s" timeout 600 activemq producer --brokerUrl $u --destination queue://bulk --persistent false --messageSize 10000 --messageCount 100000 > /dev/null 2>&1
    # A slow consumer, kept connected: messages in flight, waiting on it.
    dc exec -T -d "$s" timeout 600 activemq consumer --brokerUrl $u --destination queue://orders --messageCount 3 --sleep 120000 > /dev/null 2>&1
done
printf 'sent     on each: 3000, 300 and 30 messages nobody reads, 50 that expire, 500 for a durable subscriber gone, a queue held back by flow control, a slow consumer\n'
sleep 25

targets='a518: jmxs=localhost:19321; a519: jmxs=localhost:19322; a62: jmxs=localhost:19323'
export ACTIVEMQ_JMX=$targets ACTIVEMQ_JMX_USER=monitor ACTIVEMQ_JMX_PASSWORD=$pw ACTIVEMQ_CACERT=$tls/ca.crt
say "Every job, as the pack's scripts print it."
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$pack/pack.config")
for j in $jobs; do
    printf '\n$ bash packs/activemq/%s.sh\n' "$j"
    bash "$pack/$j.sh" > "$work/$j.out" 2> "$work/$j.err"
    printf 'exit %s\n' "$?" >> "$work/$j.err"
    cat "$work/$j.out"
    grep -v '^exit 0$' "$work/$j.err"
done

say "What they read."
for j in $jobs; do check "activemq: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
for t in a518:5.18 a519:5.19 a62:6.2; do
    n=${t%%:*} v=${t#*:}
    check "$n: answers over TLS with a password" 1 "$(val status jmx_up "broker=$n ")"
    check "$n: its version, $v" yes "$(grep -qE "^metric version 1 broker=$n .* version=${v//./\\.}\.[0-9]+" "$work/status.out" && echo yes || echo no)"
    check "$n: its own name" yes "$(grep -qE "^metric broker 1 broker=$n .* broker_name=$n\$" "$work/status.out" && echo yes || echo no)"
    check "$n: its connector" 1 "$(val status connector_up "broker=$n .*connectorName=openwire")"
    check "$n: the memory limit" 16777216 "$(val broker memory_limit_bytes "broker=$n ")"
    check "$n: messages waiting" yes "$(least broker messages "broker=$n " 3300)"
    check "$n: the deepest queue first" orders "$(grep -E "^metric size [^ ]+ broker=$n " "$work/queues.out" | head -n 1 | sed 's/.*destinationName=//')"
    check "$n: then the next" invoices "$(grep -E "^metric size [^ ]+ broker=$n " "$work/queues.out" | sed -n 2p | sed 's/.*destinationName=//')"
    check "$n: messages expired" yes "$(least queues expired_count "broker=$n .*destinationName=late\$" 50)"
    check "$n: into the dead letter queue" yes "$(least dlq size "broker=$n .*destinationName=ActiveMQ.DLQ\$" 50)"
    check "$n: sends held back by flow control" yes "$(least queues blocked_sends_count "broker=$n .*destinationName=bulk\$" 1)"
    check "$n: that queue's memory, full" yes "$(least queues memory_pct "broker=$n .*destinationName=bulk\$" 90)"
    check "$n: a producer held back now" 1 "$(grep -E "^metric blocked [^ ]+ broker=$n .*destinationName=bulk " "$work/producers.out" | awk '{ print $3 }' | sort -r | head -n 1)"
    check "$n: and how long" yes "$(least producers blocked_seconds "broker=$n .*destinationName=bulk " 1)"
    check "$n: the orders queue's size in the store" yes "$(least queues store_bytes "broker=$n .*destinationName=orders\$" 1000)"
    check "$n: messages in flight to the slow consumer" yes "$(least queues in_flight "broker=$n .*destinationName=orders\$" 1)"
    check "$n: its consumer" 1 "$(val queues consumers "broker=$n .*destinationName=orders\$")"
    check "$n: the durable subscriber gone" 0 "$(val subscribers active "broker=$n .*clientId=sub-billing")"
    check "$n: with messages kept for it" yes "$(least subscribers pending "broker=$n .*clientId=sub-billing" 500)"
    check "$n: the topic's" yes "$(least topics enqueued_count "broker=$n .*destinationName=prices\$" 500)"
    check "$n: client connections" yes "$(grep -cE "^metric dispatch_queue [^ ]+ broker=$n " "$work/connections.out" | awk '{ print ($1 >= 1) ? "yes" : "no [" $1 "]" }')"
done
check 'a518: its bridge to a62' yes "$(grep -qE '^metric bridge 1 broker=a518 .* remote=a62$' "$work/connections.out" && echo yes || echo no)"

say "The pack through Vigil."
export VIGIL_IT_PROBE_PACK=activemq VIGIL_IT_PROBE_PACK_DIR=$pack VIGIL_IT_PROBE_TARGETS=$targets VIGIL_IT_PROBE_USER=monitor \
    VIGIL_IT_PROBE_PASSWORD=$pw VIGIL_IT_PROBE_CACERT=$tls/ca.crt VIGIL_IT_PROBE_EXPECT=activemq_queue_size
unset ACTIVEMQ_JMX ACTIVEMQ_JMX_USER ACTIVEMQ_CACERT
ACTIVEMQ_JMX_PASSWORD='' bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
export ACTIVEMQ_JMX=$targets ACTIVEMQ_JMX_USER=monitor ACTIVEMQ_CACERT=$tls/ca.crt

say "The jar: refused when changed, and on a JRE."
cp -R "$pack" "$work/bad" && printf 'x' | dd of="$work/bad/_probe.jar" bs=1 seek=100 conv=notrunc 2> /dev/null
out=$(bash "$work/bad/status.sh" 2>&1)
check 'activemq: a probe changed by one byte is not run' 1 "$?"
printf '        %s\n' "$out"
if [ -n "${VIGIL_IT_ACTIVEMQ_JRE-}" ]; then
    check 'activemq: the JRE has no compiler' no "$([ -x "$VIGIL_IT_ACTIVEMQ_JRE/bin/javac" ] && echo yes || echo no)"
    bad=''
    for j in $jobs; do JAVA_HOME=$VIGIL_IT_ACTIVEMQ_JRE bash "$pack/$j.sh" > "$work/jre-$j.out" 2>&1 || bad="$bad $j"; done
    check 'activemq: every job runs on the JRE' '' "$bad"
    check 'activemq: and reads the same brokers' "$(grep -c '^metric jmx_up 1 ' "$work/status.out")" "$(grep -c '^metric jmx_up 1 ' "$work/jre-status.out")"
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || rc=1

if [ -n "${VIGIL_IT_ACTIVEMQ_HOLD-}" ]; then
    hd=$VIGIL_IT_ACTIVEMQ_HOLD.d
    rm -rf "$hd" && (umask 077 && mkdir -p "$hd" && printf '%s' "$pw" > "$hd/pw") && cp "$tls/ca.crt" "$hd/ca.crt"
    : > "$VIGIL_IT_ACTIVEMQ_HOLD"
    say "Kept up for other machines' tests until $VIGIL_IT_ACTIVEMQ_HOLD is deleted."
    while [ -e "$VIGIL_IT_ACTIVEMQ_HOLD" ]; do sleep 5; done
    rm -rf "$hd"
fi
exit $rc
