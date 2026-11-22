#!/usr/bin/env bash
#
# controller.sh - the Kafka controller's view
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
# Reports which node is the active controller, and from it the cluster as it
# sees it: brokers active and fenced, topics and partitions, offline
# partitions, leaders not where they prefer, metadata errors and lag,
# heartbeats that timed out, leader elections (unclean ones too), and its
# event queue. The other nodes report active_controller 0 and nothing else.
# Read-only: it changes nothing in the cluster.
#
# Reads each broker's JMX, at KAFKA_JMX: jmx=host:port, or jmxs=host:port over
# TLS, separated by ; or , one per broker, with KAFKA_JMX_USER and the
# password in KAFKA_JMX_PASSWORD when JMX asks for them; a certificate is
# checked against KAFKA_CACERT, or Java's own CAs, and against the broker's
# name. Each broker is named by its id. With no KAFKA_JMX, it prints nothing
# of the brokers' own. The broker's JVM (heap, garbage collection, threads,
# CPU, open files) is the jvm pack's, not this one's.
#
# Kafka's library is not in the pack: KAFKA_HOME, a Kafka download (its
# libs/), or KAFKA_LIBS, a folder of its jars, any kafka-clients from 3.x or
# 4.x.
#
# Metrics:
#   jmx_up                           1 when a node's JMX answers, tagged
#                                    broker=<id, or its JMX host:port>
#   active_controller                1 on the active controller, else 0,
#                                    tagged broker=<id>
#   brokers                          brokers active, tagged the same
#   fenced_brokers                   brokers fenced, tagged the same
#   topics                           topics, tagged the same
#   partitions                       partitions, tagged the same
#   offline_partitions               partitions with no leader, tagged the
#                                    same
#   preferred_imbalance              partitions not led by their preferred
#                                    leader, tagged the same
#   metadata_errors                  errors applying metadata, tagged the same
#   metadata_lag_ms                  how far behind its metadata is, in ms,
#                                    tagged the same
#   timed_out_heartbeats             broker heartbeats that timed out, tagged
#                                    the same
#   controller_changes               times a new controller became active,
#                                    tagged the same
#   elections_count                  leader elections, a running total, tagged
#                                    the same
#   unclean_elections_count          unclean leader elections (data lost), a
#                                    running total, tagged the same
#   eligible_leader_elections_count  leaders elected from eligible leader
#                                    replicas (Kafka 4), a running total,
#                                    tagged the same
#   event_queue                      events waiting in the controller's queue,
#                                    tagged the same
#   event_queue_ms_p99               the time an event waits there, in ms,
#                                    tagged the same
#
# Example output (the rest are in the same form):
#   metric active_controller 0 broker=1
#   metric active_controller 1 broker=2
#   metric offline_partitions 0 broker=2
#   metric partitions 165 broker=2
#   metric metadata_errors 0 broker=2
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  one node with active_controller 1; offline_partitions 0;
#            metadata_errors 0.
#   Watch    elections_count rising fast: leaders keep changing;
#            timed_out_heartbeats rising.
#   Act      no node with active_controller 1; offline_partitions above 0;
#            unclean_elections_count rising: data was lost.
#
# Requires: bash, Java 11 or later (JAVA_HOME, or java on the PATH), a JDK or
#   a JRE, to run _client.jar, beside this script, once it matches its digest
#   (a copy of the pack without the jar runs _client.java, which needs a JDK);
#   Kafka's library (KAFKA_HOME or KAFKA_LIBS)
# Exit code: 0 on success, or when the cluster does not answer; 1 if Java or
#   Kafka's library is missing, _client.jar does not match its digest, or the
#   cluster refuses the login or its certificate

set -u

# _client.jar's SHA-256, written when the pack was released: built from
# _client.java, beside it, by javac @CLIENT_JAR_JAVAC@ (tools/release/client-jar.sh).
jar_sha256=@CLIENT_JAR_SHA256@

# The client, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java=$JAVA_HOME/bin/java
elif command -v java > /dev/null 2>&1; then
    java=$(command -v java)
else
    echo "kafka_controller: java not found: the kafka pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# Kafka's library, the user's: KAFKA_LIBS, else a Kafka download's libs/.
libs=${KAFKA_LIBS-}
if [ -z "$libs" ] && [ -n "${KAFKA_HOME-}" ]; then
    libs=$KAFKA_HOME/libs
fi
if [ -z "$libs" ]; then
    echo "kafka_controller: no Kafka library: set KAFKA_HOME to a Kafka download, or KAFKA_LIBS to a folder of its jars" >&2
    exit 1
fi
found=no
for f in "$libs"/kafka-clients-*.jar; do [ -f "$f" ] && found=yes; done
if [ "$found" = no ]; then
    echo "kafka_controller: no kafka-clients-*.jar in $libs: KAFKA_HOME is a Kafka download (its libs/), KAFKA_LIBS a folder of its jars" >&2
    exit 1
fi

# The jar, the client compiled, once it matches the digest above: any Java
# 11 or later runs it. A copy of the pack without one (from the repository,
# not a release) runs the source, which needs a JDK.
if [ ! -f "$here/_client.jar" ]; then
    set -- -cp "$libs/*" "$here/_client.java"
else
    if command -v sha256sum > /dev/null 2>&1; then
        sum=$(sha256sum < "$here/_client.jar")
    elif command -v shasum > /dev/null 2>&1; then
        sum=$(shasum -a 256 < "$here/_client.jar")
    else
        sum=$(openssl dgst -sha256 -r < "$here/_client.jar")
    fi
    if [ "${sum%% *}" != "$jar_sha256" ]; then
        echo "kafka_controller: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs" >&2
        exit 1
    fi
    set -- -cp "$here/_client.jar:$libs/*" KafkaClient
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-kafka.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (the jvm
# pack would find it among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx256m \
    -Djava.io.tmpdir="$work" "$@" kafka_controller
exit $?
