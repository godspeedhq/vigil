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
# VIGIL_IT_KAFKA_HOME is a Kafka download (default ~/clis/kafka-4.4.0): its
# tools set the cluster up, and its libs/ are the pack's library. Java must
# be here. VIGIL_IT_KAFKA_LIBS2 (default ~/clis/kafka-3.9.2/libs, when it is
# there) is a second library: every job is run again with it, on
# VIGIL_IT_KAFKA_JRE when that is set. The test builds the pack's jars as a
# release does, with VIGIL_IT_KAFKA_JDK's javac (a JDK 17 or later).
#
# VIGIL_IT_KAFKA_DIST=<a Kafka download>, with --zookeeper: the cluster runs
# that Kafka (2.8, which has no image), in eclipse-temurin:11-jre.
#
# The brokers' JMX has a user that may only read (monitor), a password of
# the run's own and TLS, as the pack asks for it.
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
dist=${VIGIL_IT_KAFKA_DIST-}
if [ -n "$dist" ]; then
    [ "$zk" = yes ] || die 'VIGIL_IT_KAFKA_DIST is for --zookeeper'
    [ -x "$dist/bin/kafka-server-start.sh" ] || die "no Kafka in $dist"
    export KAFKA_IMAGE=eclipse-temurin:11-jre KAFKA_DIST=$dist
fi
khome=${VIGIL_IT_KAFKA_HOME:-$HOME/clis/kafka-4.4.0}
[ -x "$khome/bin/kafka-topics.sh" ] || die "no Kafka tools in $khome: set VIGIL_IT_KAFKA_HOME"
file=compose.kafka.yaml nodes=3 bootstrap=localhost:19091,localhost:19092 jmx='jmxs=127.0.0.1:19991; jmxs=127.0.0.1:19992; jmxs=127.0.0.1:19993'
[ "$zk" = yes ] && file=compose.kafka-zk.yaml nodes=1 bootstrap=localhost:19091 jmx='jmxs=127.0.0.1:19991'
libs2=${VIGIL_IT_KAFKA_LIBS2-}
[ -z "$libs2" ] && [ -d "$HOME/clis/kafka-3.9.2/libs" ] && libs2=$HOME/clis/kafka-3.9.2/libs
dc() { docker compose -p vigil-kafka --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-kafka-it.XXXXXX") || exit 1
root=$work/none
# The monitoring user's password, JMX's and the keystore's: this run's own.
pw=$(openssl rand -hex 16) jpw=$(openssl rand -hex 16) kspw=$(openssl rand -hex 16)
export KAFKA_JMX_PASSWORD=$jpw KAFKA_KS_PASSWORD=$kspw
# The Compose file mounts a Kafka download; but for 2.8, an empty folder.
[ -n "${KAFKA_DIST-}" ] || { mkdir -p "$work/nodist" && export KAFKA_DIST=$work/nodist; }
trap 'dc down -v > /dev/null 2>&1; evidence_save "$pw" "$jpw" "$kspw"; rm -rf "$work"' EXIT

# Each release's run is kept apart: pack-kafka-4.4.0.
v=${KAFKA_IMAGE:-$(sed -n 's/^ *image: \${KAFKA_IMAGE:-apache\/kafka:\(.*\)}$/\1/p' "$bk_dir/$file" | head -n 1)}
v=${v##*:}
[ -n "$dist" ] && v=$(basename "$dist" | sed 's/^kafka_[0-9.]*-//; s/^kafka-//')
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
        cat server.key server.crt > server.pem &&
        KSPW=$kspw openssl pkcs12 -export -in server.crt -inkey server.key -name server -out server.p12 -passout env:KSPW
) > "$work/tls.log" 2>&1 || { cat "$work/tls.log"; die 'could not make the TLS certificates'; }
rm -f "$tls/ca.key" "$tls/server.csr"
# Kafka runs as its own account in the container: it reads them.
chmod 755 "$tls"
chmod 644 "$tls"/*
export KAFKA_TLS_DIR=$tls

evidence_start "$name" "$bk_dir/$file" "$0" "$@"
# The pack as a release builds it: its jars compiled against this Kafka's
# library, with a JDK 17 or later (VIGIL_IT_KAFKA_JDK, else JAVA_HOME's or
# the PATH's), and their digests in its scripts.
os=linux
[ "$(uname -s)" = Darwin ] && os=macos
scripts=$work/pack
mkdir -p "$scripts" && cp "$bk_repo/packs/kafka/pack.config" "$bk_repo/packs/kafka/$os"/* "$scripts/" || die 'cannot copy the pack'
JAVA_HOME=${VIGIL_IT_KAFKA_JDK:-${JAVA_HOME-}} bash "$bk_repo/tools/release/client-jar.sh" "$scripts" "$(ls "$khome"/libs/kafka-clients-*.jar | head -n 1)" > "$work/jars.log" 2>&1 ||
    { cat "$work/jars.log"; die 'cannot build the pack'"'"'s jars'; }
sed 's/^client-jar: [^ ]*\/\(_[a-z]*\.jar\)/jars     \1/' "$work/jars.log"
printf 'tools    Kafka %s (the setup, and the library), %s\n' "$("$khome/bin/kafka-topics.sh" --version 2> /dev/null | tail -n 1)" "$(java -version 2>&1 | head -n 1)"
[ -z "$libs2" ] || printf 'library2 %s\n' "$(ls "$libs2"/kafka-clients-*.jar | head -n 1)"
[ -z "${VIGIL_IT_KAFKA_JRE-}" ] || printf 'jre      %s (%s)\n' "$("$VIGIL_IT_KAFKA_JRE/bin/java" -version 2>&1 | head -n 1)" "$VIGIL_IT_KAFKA_JRE"
[ -z "$dist" ] || printf 'cluster  the Kafka download %s, in %s\n' "$dist" "$KAFKA_IMAGE"
say() { printf '\n# %s\n' "$*"; }
# Setup, through the PLAINTEXT listener, which may do anything and only this
# host reaches.
admin() { local t=$1; shift; "$khome/bin/$t.sh" --bootstrap-server 127.0.0.1:29091 "$@"; }
brokers() { admin kafka-broker-api-versions 2> /dev/null | grep -c '(id: '; }

dc up -d > "$work/up.log" 2>&1 || { cat "$work/up.log"; die 'the cluster would not start'; }
for _ in $(seq 1 60); do [ "$(brokers)" = "$nodes" ] && break; sleep 3; done
[ "$(brokers)" = "$nodes" ] || { dc logs --tail 30; die "the cluster never had its $nodes brokers"; }

# The user, as packs/README.md says: SCRAM, its password from a file of this
# run's own, never on a command line.
(umask 077 && printf 'SCRAM-SHA-512=[iterations=8192,password=%s]\n' "$pw" > "$work/user.properties")
admin kafka-configs --alter --entity-type users --entity-name vigil_monitor --add-config-file "$work/user.properties" > "$work/user.log" 2>&1 ||
    die "could not make the user: $(grep -v password "$work/user.log" | tail -n 1)"
rm -f "$work/user.properties"
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
# The tools inside the broker's container: the image's, or 2.8's download.
kb=/opt/kafka/bin
[ -n "$dist" ] && kb=/opt/kafka-dist/bin
inside $kb/kafka-console-consumer.sh --bootstrap-server kafka1:9094 --topic orders --group shipping
[ "$zk" = no ] && [ -x "$khome/bin/kafka-console-share-consumer.sh" ] &&
    inside $kb/kafka-console-share-consumer.sh --bootstrap-server kafka1:9094 --topic payments --group fraud
# Its transaction.timeout.ms is longer than the transaction, or the broker
# aborts it at the default, a minute: 15 minutes, the most a broker allows
# by default.
inside $kb/kafka-producer-perf-test.sh --topic orders --num-records 100000 --record-size 100 --throughput 20 \
    --transactional-id vigil-it-txn --transaction-duration-ms 600000 \
    --producer-props bootstrap.servers=kafka1:9094 transaction.timeout.ms=900000
printf '{"version":1,"partitions":[{"topic":"audit","partition":0,"replicas":[2]}]}' > "$work/move.json"
[ "$zk" = no ] && admin kafka-reassign-partitions --reassignment-json-file "$work/move.json" --execute --throttle 1 > /dev/null 2>&1
sleep 20
printf 'cluster  %s\n' "$(KAFKA_HOME=$khome KAFKA_BOOTSTRAP=127.0.0.1:29091 bash "$scripts/status.sh" 2> /dev/null | grep '^metric info ' | cut -d ' ' -f 4-)"

say "The pack through Vigil."
# VIGIL_IT_KAFKA_TXN: a transaction is held open, for the test to see.
export VIGIL_IT_KAFKA_BOOTSTRAP=$bootstrap VIGIL_IT_KAFKA_PASSWORD=$pw VIGIL_IT_KAFKA_CACERT=$tls/ca.crt \
    VIGIL_IT_KAFKA_HOME=$khome VIGIL_IT_KAFKA_JMX=$jmx VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP=127.0.0.1:29091 \
    VIGIL_IT_KAFKA_TXN=1 VIGIL_IT_KAFKA_JMX_PASSWORD=$jpw VIGIL_IT_KAFKA_LIBS2=$libs2 VIGIL_IT_KAFKA_PACK=$scripts
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?

# Each job as the busy cluster has it, then with a broker gone, as the
# pack's scripts print it. The password reaches them in their environment.
export KAFKA_HOME=$khome KAFKA_BOOTSTRAP=$bootstrap KAFKA_SECURITY=SASL_SSL KAFKA_SASL_MECHANISM=SCRAM-SHA-512 \
    KAFKA_USER=vigil_monitor KAFKA_CACERT=$tls/ca.crt KAFKA_PASSWORD=$pw KAFKA_JMX=$jmx KAFKA_JMX_USER=monitor KAFKA_JMX_PASSWORD=$jpw
job() {
    printf '\n$ bash packs/kafka/%s.sh\n' "$1"
    bash "$scripts/$1.sh" 2>&1 | head -n "${2:-200}"
}
say "Every job, with the cluster busy."
for j in status quorum brokers replication reassignment consumers groups topics logdirs transactions config security features throughput requests controller connections tls; do
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
    rm -rf "$hd" && (umask 077 && mkdir -p "$hd" && printf '%s' "$pw" > "$hd/pw" && printf '%s' "$jpw" > "$hd/jmxpw") && cp "$tls/ca.crt" "$hd/ca.crt"
    : > "$VIGIL_IT_KAFKA_HOLD"
    say "Kept up for other machines' tests until $VIGIL_IT_KAFKA_HOLD is deleted."
    while [ -e "$VIGIL_IT_KAFKA_HOLD" ]; do sleep 5; done
    rm -rf "$hd"
fi
exit $rc
