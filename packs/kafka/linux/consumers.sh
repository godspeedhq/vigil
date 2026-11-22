#!/usr/bin/env bash
#
# consumers.sh - consumer group lag
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
# Reports each consumer group's lag: how far its committed offsets are behind
# the end of each partition, summed and the worst partition, per group and
# topic; partitions with no committed offset; and each group's total.
# Read-only: it changes nothing in the cluster.
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
#   groups                groups with committed offsets
#   total_lag             all groups' lag, in messages
#   lag                   a group's lag on a topic, in messages, tagged
#                         group=<name> and topic=<name> (at most 150 pairs)
#   lag_max               its worst partition, tagged the same
#   no_offset_partitions  partitions the group has no committed offset for,
#                         tagged the same; left out when none
#   pairs_not_shown       group and topic pairs past the first 150, left out
#   group_lag             a group's lag on all its topics, tagged group=<name>
#                         (at most 150)
#
# Example output (the rest are in the same form):
#   metric groups 3
#   metric total_lag 16393
#   metric lag 16393 group=billing topic=orders
#   metric lag_max 3880 group=billing topic=orders
#   metric lag 0 group=ledger topic=payments
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  lag steady or falling: consumers keep up.
#   Watch    lag rising for minutes: consumers fall behind; lag_max far above
#            lag divided by partitions: one partition is stuck, or one
#            consumer is slow.
#   Act      lag rising with the group empty (kafka_groups): nothing consumes;
#            lag near what retention keeps: consumers are about to lose
#            messages they never read.
#
# Requires: bash, Java 11 or later (JAVA_HOME, or java on the PATH), a JDK or
#   a JRE, to run _client.jar, beside this script, once it matches its digest
#   (a copy of the pack without the jar runs _client.java, which needs a JDK);
#   Kafka's library (KAFKA_HOME or KAFKA_LIBS); a user with the ACLs
#   packs/README.md lists
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
    echo "kafka_consumers: java not found: the kafka pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# Kafka's library, the user's: KAFKA_LIBS, else a Kafka download's libs/.
libs=${KAFKA_LIBS-}
if [ -z "$libs" ] && [ -n "${KAFKA_HOME-}" ]; then
    libs=$KAFKA_HOME/libs
fi
if [ -z "$libs" ]; then
    echo "kafka_consumers: no Kafka library: set KAFKA_HOME to a Kafka download, or KAFKA_LIBS to a folder of its jars" >&2
    exit 1
fi
found=no
for f in "$libs"/kafka-clients-*.jar; do [ -f "$f" ] && found=yes; done
if [ "$found" = no ]; then
    echo "kafka_consumers: no kafka-clients-*.jar in $libs: KAFKA_HOME is a Kafka download (its libs/), KAFKA_LIBS a folder of its jars" >&2
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
        echo "kafka_consumers: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs" >&2
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
    -Djava.io.tmpdir="$work" "$@" kafka_consumers
exit $?
