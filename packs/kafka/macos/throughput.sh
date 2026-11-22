#!/usr/bin/env bash
#
# throughput.sh - each Kafka broker's traffic
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
# Reports each broker's traffic, all topics together: messages and bytes in
# and out, replication between brokers, produce and fetch requests and those
# that failed, bytes rejected, format conversions, and records rejected as
# invalid. Running totals: graph them as a rate. Read-only: it changes nothing
# in the cluster.
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
#   jmx_up                          1 when a broker's JMX answers, tagged
#                                   broker=<id, or its JMX host:port>
#   messages_in_count               messages written to it, tagged broker=<id>
#   bytes_in_count                  bytes written to it by clients, tagged the
#                                   same
#   bytes_out_count                 bytes read from it by clients, tagged the
#                                   same
#   bytes_rejected_count            bytes rejected, too large, tagged the same
#   replication_bytes_in_count      bytes copied to it from other brokers,
#                                   tagged the same
#   replication_bytes_out_count     bytes copied from it to other brokers,
#                                   tagged the same
#   produce_requests_count          produce requests, tagged the same
#   fetch_requests_count            fetch requests, tagged the same
#   failed_produce_requests_count   produce requests that failed, tagged the
#                                   same
#   failed_fetch_requests_count     fetch requests that failed, tagged the
#                                   same
#   produce_conversions_count       messages converted to another format on
#                                   produce, tagged the same
#   fetch_conversions_count         messages converted on fetch, tagged the
#                                   same
#   invalid_crc_records_count       records rejected for a bad checksum,
#                                   tagged the same
#   invalid_sequence_records_count  records rejected for an offset or sequence
#                                   out of order, tagged the same
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 broker=1
#   metric messages_in_count 10628 broker=1
#   metric bytes_in_count 1857522 broker=1
#   metric bytes_out_count 1657669 broker=1
#   metric failed_produce_requests_count 0 broker=1
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  jmx_up 1; traffic spread evenly between brokers; the failed
#            counts flat.
#   Watch    one broker's bytes far above the others': partitions are
#            unbalanced; the conversion counts rising: old clients make the
#            broker do extra work.
#   Act      failed_produce_requests_count rising: producers' writes fail;
#            bytes_rejected_count rising: messages too large for
#            message.max.bytes.
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
    echo "kafka_throughput: java not found: the kafka pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# Kafka's library, the user's: KAFKA_LIBS, else a Kafka download's libs/.
libs=${KAFKA_LIBS-}
if [ -z "$libs" ] && [ -n "${KAFKA_HOME-}" ]; then
    libs=$KAFKA_HOME/libs
fi
if [ -z "$libs" ]; then
    echo "kafka_throughput: no Kafka library: set KAFKA_HOME to a Kafka download, or KAFKA_LIBS to a folder of its jars" >&2
    exit 1
fi
found=no
for f in "$libs"/kafka-clients-*.jar; do [ -f "$f" ] && found=yes; done
if [ "$found" = no ]; then
    echo "kafka_throughput: no kafka-clients-*.jar in $libs: KAFKA_HOME is a Kafka download (its libs/), KAFKA_LIBS a folder of its jars" >&2
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
        echo "kafka_throughput: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs" >&2
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
    -Djava.io.tmpdir="$work" "$@" kafka_throughput
exit $?
