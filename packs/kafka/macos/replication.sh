#!/usr/bin/env bash
#
# replication.sh - a Kafka cluster's replication
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
# Reports every partition's replication: partitions with fewer replicas in
# sync than they have, with no leader (offline), with fewer in sync than
# min.insync.replicas (writes with acks=all fail), exactly at it (one more
# lost and they fail), led by a broker other than the preferred one, with
# eligible leader replicas, and being moved; and by name, the topics that have
# such partitions. Read-only: it changes nothing in the cluster.
#
# Connects to KAFKA_BOOTSTRAP (host:port, comma-separated) through Kafka's
# admin API, as KAFKA_USER with the password in KAFKA_PASSWORD, set by the
# job: never on a command line, never in a file. KAFKA_SECURITY is PLAINTEXT,
# SSL, SASL_PLAINTEXT or SASL_SSL; KAFKA_SASL_MECHANISM SCRAM-SHA-512,
# SCRAM-SHA-256 or PLAIN. With TLS, the brokers' certificates are checked
# against KAFKA_CACERT, a PEM file of CAs, or Java's own, and against their
# names; KAFKA_CERT and KAFKA_KEY give a client certificate.
# KAFKA_CLIENT_CONFIG, a client properties file of your own, comes first, for
# a login this pack does not build (Kerberos, OAuth).
#
# Kafka's library is not in the pack: KAFKA_HOME, a Kafka download (its
# libs/), or KAFKA_LIBS, a folder of its jars, any kafka-clients from 3.x or
# 4.x.
#
# Metrics:
#   topics                  topics
#   partitions              partitions
#   under_replicated        partitions with fewer replicas in sync than they
#                           have
#   offline                 partitions with no leader: no one can read or
#                           write them
#   under_min_isr           partitions with fewer in sync than
#                           min.insync.replicas: writes with acks=all fail
#   at_min_isr              partitions exactly at min.insync.replicas, with
#                           replicas to spare
#   not_preferred_leader    partitions not led by their preferred leader
#   with_eligible_leaders   partitions with eligible leader replicas (Kafka 4)
#   reassigning             partitions being moved between brokers
#   topic_under_replicated  under-replicated partitions of a topic, tagged
#                           topic=<name> (at most 100 topics)
#   topic_offline           offline partitions of a topic, tagged the same
#   topic_under_min_isr     partitions of a topic under min.insync.replicas,
#                           tagged the same
#
# Example output (the rest are in the same form):
#   metric partitions 165
#   metric under_replicated 1
#   metric offline 0
#   metric under_min_isr 3
#   metric topic_under_min_isr 3 topic=audit
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  under_replicated, offline and under_min_isr 0.
#   Watch    at_min_isr above 0: one more replica lost and writes fail;
#            not_preferred_leader growing.
#   Act      offline above 0: data unreachable; under_min_isr above 0:
#            producers with acks=all fail; under_replicated above 0 for
#            minutes when no broker is restarting.
#
# Requires: bash, Java 11 or later (JAVA_HOME, or java on the PATH), a JDK or
#   a JRE, to run _client.jar and _probe.jar, beside this script, once they
#   match their digests; Kafka's library (KAFKA_HOME or KAFKA_LIBS); a user
#   with the ACLs packs/README.md lists
# Exit code: 0 on success, or when the cluster does not answer; 1 if Java or
#   Kafka's library is missing, _client.jar does not match its digest, or the
#   cluster refuses the login or its certificate

set -u

# The jars' SHA-256s, written when the pack was released: each built from
# its source, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
probe_sha256=@PROBE_JAR_SHA256@
client_sha256=@CLIENT_JAR_SHA256@
# The jars, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java=$JAVA_HOME/bin/java
elif command -v java > /dev/null 2>&1; then
    java=$(command -v java)
else
    echo "kafka_replication: java not found: the kafka pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A jar is run only once it matches the digest above: $1 the jar, $2 its digest.
checked() {
    if [ ! -f "$1" ]; then
        echo "kafka_replication: ${1##*/} not found: this copy of the pack has none: install the pack from a packs release (vigil pack install kafka), or build it (tools/release/client-jar.sh)" >&2
        exit 1
    fi
    if command -v sha256sum > /dev/null 2>&1; then
        sum=$(sha256sum < "$1")
    elif command -v shasum > /dev/null 2>&1; then
        sum=$(shasum -a 256 < "$1")
    else
        sum=$(openssl dgst -sha256 -r < "$1")
    fi
    if [ "${sum%% *}" != "$2" ]; then
        echo "kafka_replication: ${1##*/} does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs" >&2
        exit 1
    fi
}
checked "$here/_probe.jar" "$probe_sha256"
checked "$here/_client.jar" "$client_sha256"

# Kafka's library, the user's: KAFKA_LIBS, else a Kafka download's libs/.
libs=${KAFKA_LIBS-}
if [ -z "$libs" ] && [ -n "${KAFKA_HOME-}" ]; then
    libs=$KAFKA_HOME/libs
fi
if [ -z "$libs" ]; then
    echo "kafka_replication: no Kafka library: set KAFKA_HOME to a Kafka download, or KAFKA_LIBS to a folder of its jars" >&2
    exit 1
fi
found=no
for f in "$libs"/kafka-clients-*.jar; do [ -f "$f" ] && found=yes; done
if [ "$found" = no ]; then
    echo "kafka_replication: no kafka-clients-*.jar in $libs: KAFKA_HOME is a Kafka download (its libs/), KAFKA_LIBS a folder of its jars" >&2
    exit 1
fi
set -- -cp "$here/_client.jar:$here/_probe.jar:$libs/*" KafkaClient

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-kafka.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (the jvm
# pack would find it among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx256m \
    -Djava.io.tmpdir="$work" "$@" kafka_replication
exit $?
