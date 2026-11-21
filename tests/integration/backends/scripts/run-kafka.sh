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
# run-kafka.sh - the kafka pack against a real three-node Kafka cluster on
# this host, with its evidence kept like the other runs'.
#
#   scripts/run-kafka.sh [image]                    compose.kafka.yaml
#   scripts/run-kafka.sh --zookeeper [image]        compose.kafka-zk.yaml
#
# --zookeeper: one broker on ZooKeeper, as Kafka 3 runs it (default
# apache/kafka:3.9.2), with no partition move, share group or broker
# stopped: one broker has nowhere to move a partition or fail over to.
#
# It makes a TLS certificate from a CA of its own, starts the cluster (any
# apache/kafka image from 3.9; default the one the Compose file pins), makes
# the monitoring user and its ACLs as packs/README.md says, with a password
# of this run's own, and keeps the cluster busy: a group that reads, a share
# group (Kafka 4), a transaction held open, and a partition move held back
# by a throttle. Then it runs tests/integration/service-packs.sh with the
# cluster given, shows what each of the pack's jobs reports while the
# cluster is busy, stops one broker and shows what the pack sees, and
# starts it again. The cluster is taken down, with its data, at the end.
#
# The pack runs Kafka's own command-line tools: VIGIL_IT_KAFKA_HOME is
# where they are (default ~/clis/kafka-4.4.0), and Java must be here.
#
# VIGIL_IT_KAFKA_HOLD=<file>: at the end, the cluster is kept up, with its
# monitoring user's password and its CA in <file>.d/ (this account's
# only), for the tests of other machines (macOS, Windows), until <file> is
# deleted; then it is taken down as ever.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

zk=no
if [ "${1-}" = --zookeeper ]; then zk=yes; shift; fi
[ -n "${1-}" ] && export KAFKA_IMAGE=$1
khome=${VIGIL_IT_KAFKA_HOME:-$HOME/clis/kafka-4.4.0}
[ -x "$khome/bin/kafka-topics.sh" ] || die "no Kafka tools in $khome: set VIGIL_IT_KAFKA_HOME"
file=compose.kafka.yaml nodes=3 bootstrap=localhost:19091,localhost:19092 jmx=127.0.0.1:19991,127.0.0.1:19992,127.0.0.1:19993
[ "$zk" = yes ] && file=compose.kafka-zk.yaml nodes=1 bootstrap=localhost:19091 jmx=127.0.0.1:19991
dc() { docker compose -p vigil-kafka --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-kafka-it.XXXXXX") || exit 1
root=$work/none
# The monitoring user's password: this run's own.
pw=$(openssl rand -hex 16)
trap 'dc down -v > /dev/null 2>&1; evidence_save "$pw"; rm -rf "$work"' EXIT

# Each release's run is kept apart: pack-kafka-4.4.0.
v=${KAFKA_IMAGE:-$(sed -n 's/^ *image: \${KAFKA_IMAGE:-apache\/kafka:\(.*\)}$/\1/p' "$bk_dir/$file" | head -n 1)}
v=${v##*:}
name=pack-kafka-$v
[ "$zk" = yes ] && name=pack-kafka-$v-zookeeper

# The brokers' certificate, from a CA of this run's own: the name the pack
# connects by, localhost, and 127.0.0.1. Kafka reads a key and its
# certificate from one PEM file.
tls=$work/tls
mkdir -p "$tls"
(
    cd "$tls" || exit 1
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 -subj '/CN=Vigil test CA' \
        -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' &&
        openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj '/CN=localhost' &&
        printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > server.ext &&
        openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 2 -extfile server.ext &&
        cat server.key server.crt > server.pem
) > "$work/tls.log" 2>&1 || { cat "$work/tls.log"; die 'could not make the TLS certificates'; }
rm -f "$tls/ca.key" "$tls/server.csr"
# Kafka runs as its own account in the container: it reads them.
chmod 755 "$tls"
chmod 644 "$tls"/*
export KAFKA_TLS_DIR=$tls

evidence_start "$name" "$bk_dir/$file" "$0" "$@"
scripts=$bk_repo/packs/kafka/linux
[ "$(uname -s)" = Darwin ] && scripts=$bk_repo/packs/kafka/macos
printf 'tools    Kafka %s, %s\n' "$("$khome/bin/kafka-topics.sh" --version 2> /dev/null | tail -n 1)" "$(java -version 2>&1 | head -n 1)"
say() { printf '\n# %s\n' "$*"; }
# Setup, through the PLAINTEXT listener, which may do anything and only this
# host reaches.
admin() { local t=$1; shift; "$khome/bin/$t.sh" --bootstrap-server 127.0.0.1:29091 "$@"; }
brokers() { admin kafka-broker-api-versions 2> /dev/null | grep -c '(id: '; }

dc up -d > "$work/up.log" 2>&1 || { cat "$work/up.log"; die 'the cluster would not start'; }
for _ in $(seq 1 60); do [ "$(brokers)" = "$nodes" ] && break; sleep 3; done
[ "$(brokers)" = "$nodes" ] || { dc logs --tail 30; die "the cluster never had its $nodes brokers"; }

# The user, as packs/README.md says: SCRAM, its password from this run's
# environment into the container's, never on the host's command line.
dc exec -T -e PW="$pw" kafka1 sh -c '/opt/kafka/bin/kafka-configs.sh --bootstrap-server kafka1:9094 --alter --entity-type users --entity-name vigil_monitor --add-config "SCRAM-SHA-512=[iterations=8192,password=$PW]"' > "$work/user.log" 2>&1 ||
    die "could not make the user: $(grep -v password "$work/user.log" | tail -n 1)"
admin kafka-acls --add --allow-principal User:vigil_monitor --operation Describe --operation DescribeConfigs --cluster --topic '*' > /dev/null &&
    admin kafka-acls --add --allow-principal User:vigil_monitor --operation Describe --group '*' --transactional-id '*' > /dev/null ||
    die 'could not grant the ACLs'

# Topics, and the cluster kept busy: messages; a group that read part of
# them and stopped (lag) and one that keeps reading; a share group (Kafka
# 4); a transaction held open for ten minutes; and a partition move held
# back by a throttle of 1 byte a second. What keeps running runs inside a
# broker's container, with a time limit, and goes with it.
admin kafka-topics --create --topic orders --partitions 6 > /dev/null
if [ "$zk" = yes ]; then
    admin kafka-topics --create --topic payments --partitions 3 > /dev/null
else
    admin kafka-topics --create --topic payments --partitions 3 --config min.insync.replicas=3 > /dev/null
fi
admin kafka-topics --create --topic audit --partitions 3 --replication-factor 1 > /dev/null
admin kafka-topics --create --topic customers --partitions 3 --config cleanup.policy=compact > /dev/null
"$khome/bin/kafka-producer-perf-test.sh" --topic orders --num-records 20000 --record-size 200 --throughput -1 --producer-props bootstrap.servers=127.0.0.1:29091 acks=all > /dev/null 2>&1
"$khome/bin/kafka-producer-perf-test.sh" --topic payments --num-records 3000 --record-size 100 --throughput -1 --producer-props bootstrap.servers=127.0.0.1:29091 > /dev/null 2>&1
"$khome/bin/kafka-producer-perf-test.sh" --topic audit --num-records 2000 --record-size 100 --throughput -1 --producer-props bootstrap.servers=127.0.0.1:29091 > /dev/null 2>&1
admin kafka-console-consumer --topic orders --group billing --from-beginning --max-messages 5000 > /dev/null 2>&1
inside() { dc exec -T -d kafka1 timeout 900 "$@"; }
inside /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka1:9094 --topic orders --group shipping
[ "$zk" = no ] && [ -x "$khome/bin/kafka-console-share-consumer.sh" ] &&
    inside /opt/kafka/bin/kafka-console-share-consumer.sh --bootstrap-server kafka1:9094 --topic payments --group fraud
inside /opt/kafka/bin/kafka-producer-perf-test.sh --topic orders --num-records 100000 --record-size 100 --throughput 20 \
    --transactional-id vigil-it-txn --transaction-duration-ms 600000 --producer-props bootstrap.servers=kafka1:9094
printf '{"version":1,"partitions":[{"topic":"audit","partition":0,"replicas":[2]}]}' > "$work/move.json"
[ "$zk" = no ] && admin kafka-reassign-partitions --reassignment-json-file "$work/move.json" --execute --throttle 1 > /dev/null 2>&1
sleep 20
printf 'cluster  %s\n' "$(KAFKA_HOME=$khome KAFKA_BOOTSTRAP=127.0.0.1:29091 bash "$scripts/status.sh" 2> /dev/null | grep '^metric info ' | cut -d ' ' -f 4-)"

say "The pack through Vigil."
export VIGIL_IT_KAFKA_BOOTSTRAP=$bootstrap VIGIL_IT_KAFKA_PASSWORD=$pw VIGIL_IT_KAFKA_CACERT=$tls/ca.crt \
    VIGIL_IT_KAFKA_HOME=$khome VIGIL_IT_KAFKA_JMX=$jmx VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP=127.0.0.1:29091
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?

# Each job as the busy cluster has it, then with a broker gone, as the
# pack's scripts print it. The password reaches them in their environment.
export KAFKA_HOME=$khome KAFKA_BOOTSTRAP=$bootstrap KAFKA_SECURITY=SASL_SSL KAFKA_SASL_MECHANISM=SCRAM-SHA-512 \
    KAFKA_USER=vigil_monitor KAFKA_CACERT=$tls/ca.crt KAFKA_PASSWORD=$pw KAFKA_JMX=$jmx
job() {
    printf '\n$ bash packs/kafka/%s.sh\n' "$1"
    bash "$scripts/$1.sh" 2>&1 | head -n "${2:-200}"
}
say "Every job, with the cluster busy."
for j in status quorum brokers replication reassignment consumers groups topics logdirs transactions config security features throughput requests jvm controller connections tls; do
    job "$j"
done
[ "$zk" = yes ] && exit $rc
say "Broker 3 stopped."
dc stop kafka3 > /dev/null 2>&1
sleep 20
for j in status brokers replication quorum controller; do job "$j"; done
say "Broker 3 started again."
dc start kafka3 > /dev/null 2>&1
for _ in $(seq 1 30); do [ "$(brokers)" = 3 ] && break; sleep 3; done
sleep 15
for j in status replication; do job "$j"; done

if [ -n "${VIGIL_IT_KAFKA_HOLD-}" ]; then
    hd=$VIGIL_IT_KAFKA_HOLD.d
    rm -rf "$hd" && (umask 077 && mkdir -p "$hd" && printf '%s' "$pw" > "$hd/pw") && cp "$tls/ca.crt" "$hd/ca.crt"
    : > "$VIGIL_IT_KAFKA_HOLD"
    say "Kept up for other machines' tests until $VIGIL_IT_KAFKA_HOLD is deleted."
    while [ -e "$VIGIL_IT_KAFKA_HOLD" ]; do sleep 5; done
    rm -rf "$hd"
fi
exit $rc
