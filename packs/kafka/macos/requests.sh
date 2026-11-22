#!/usr/bin/env bash
#
# requests.sh - how each Kafka broker serves requests
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
# Reports how each broker serves requests: the time produce, consumer fetch
# and follower fetch requests take (99th percentile, as the broker measures it
# over its recent requests), the time they queue and wait on others, how many
# it has served, the request and response queues, requests waiting in
# purgatory, and how idle its request handler and network threads are.
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
#   jmx_up            1 when a broker's JMX answers, tagged broker=<id, or its
#                     JMX host:port>
#   total_ms_p99      the time a request takes, in ms, tagged broker=<id> and
#                     request=<Produce, FetchConsumer or FetchFollower>
#   queue_ms_p99      of that, the time it waits in the queue, tagged the same
#   remote_ms_p99     of that, the time it waits on other brokers (acks=all)
#                     or for data (fetch), tagged the same
#   requests_count    requests served, a running total, tagged the same
#   request_queue     requests waiting for a handler thread, tagged
#                     broker=<id>
#   response_queue    responses waiting to be sent, tagged the same
#   purgatory         requests waiting in purgatory, tagged broker=<id> and
#                     operation=<produce or fetch>
#   handler_idle_pct  how idle the request handler threads are, as a percent,
#                     tagged broker=<id>
#   network_idle_pct  how idle the network threads are, as a percent, tagged
#                     the same
#
# Example output (the rest are in the same form):
#   metric total_ms_p99 502 broker=1 request=FetchConsumer
#   metric queue_ms_p99 3 broker=1 request=Produce
#   metric remote_ms_p99 43.23 broker=1 request=Produce
#   metric request_queue 0 broker=1
#   metric response_queue 0 broker=1
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  handler_idle_pct and network_idle_pct above 30; request_queue
#            near 0; Produce total_ms_p99 steady.
#   Watch    handler_idle_pct below 30: the broker is busy; queue_ms_p99
#            rising: requests wait for threads.
#   Act      handler_idle_pct or network_idle_pct below 10: the broker is
#            saturated; Produce total_ms_p99 climbing with remote_ms_p99:
#            followers are slow to replicate.
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
    echo "kafka_requests: java not found: the kafka pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# Kafka's library, the user's: KAFKA_LIBS, else a Kafka download's libs/.
libs=${KAFKA_LIBS-}
if [ -z "$libs" ] && [ -n "${KAFKA_HOME-}" ]; then
    libs=$KAFKA_HOME/libs
fi
if [ -z "$libs" ]; then
    echo "kafka_requests: no Kafka library: set KAFKA_HOME to a Kafka download, or KAFKA_LIBS to a folder of its jars" >&2
    exit 1
fi
found=no
for f in "$libs"/kafka-clients-*.jar; do [ -f "$f" ] && found=yes; done
if [ "$found" = no ]; then
    echo "kafka_requests: no kafka-clients-*.jar in $libs: KAFKA_HOME is a Kafka download (its libs/), KAFKA_LIBS a folder of its jars" >&2
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
        echo "kafka_requests: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs" >&2
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
    -Djava.io.tmpdir="$work" "$@" kafka_requests
exit $?
