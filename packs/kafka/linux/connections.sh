#!/usr/bin/env bash
#
# connections.sh - connections and logins on each Kafka broker
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
# Reports each broker's connections per listener: open now, and running totals
# of those made and of logins that succeeded, failed, and failed again on
# re-authentication. Read-only: it changes nothing in the cluster.
#
# Reads each broker's JMX, at KAFKA_JMX: jmx=host:port, or jmxs=host:port over
# TLS, separated by ; or , one per broker, with KAFKA_JMX_USER and the
# password in KAFKA_JMX_PASSWORD when JMX asks for them; a certificate is
# checked against KAFKA_CACERT, or Java's own CAs, and against the broker's
# name. Each broker is named by its id. With no KAFKA_JMX, it prints nothing
# of the brokers' own. The broker's JVM (heap, garbage collection, threads,
# CPU, open files) is the jvm pack's, not this one's.
#
# The probe (_probe.jar, tools/probe) reads it, from this pack's
# _probe.tables, beside this script: no Kafka library is needed.
#
# Metrics:
#   jmx_up                 1 when a broker's JMX answers, tagged broker=<id,
#                          or its JMX host:port>
#   connections            connections open, tagged broker=<id> and
#                          listener=<name>
#   created_count          connections made, a running total, tagged the same
#   logins_count           logins that succeeded, a running total, tagged the
#                          same
#   failed_logins_count    logins that failed, a running total, tagged the
#                          same
#   failed_relogins_count  re-authentications that failed, a running total,
#                          tagged the same
#
# Example output (the rest are in the same form):
#   metric connections 0 broker=1 listener=PLAIN
#   metric created_count 81 broker=1 listener=SECURE
#   metric logins_count 81 broker=1 listener=SECURE
#   metric failed_logins_count 0 broker=1 listener=SECURE
#   metric failed_relogins_count 0 broker=1 listener=SECURE
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  failed_logins_count flat; connections steady.
#   Watch    created_count rising fast while connections stays flat: clients
#            connect and drop.
#   Act      failed_logins_count rising: a client with a wrong password or
#            certificate, or someone guessing.
#
# Requires: bash, Java 11 or later (JAVA_HOME, or java on the PATH), a JDK or
#   a JRE, to run _probe.jar, beside this script, once it matches its digest;
#   the brokers' JMX
# Exit code: 0 on success, or when the cluster does not answer; 1 if Java or
#   Kafka's library is missing, _client.jar does not match its digest, or the
#   cluster refuses the login or its certificate

set -u

# The jars' SHA-256s, written when the pack was released: each built from
# its source, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
probe_sha256=@PROBE_JAR_SHA256@
# The jars, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java=$JAVA_HOME/bin/java
elif command -v java > /dev/null 2>&1; then
    java=$(command -v java)
else
    echo "kafka_connections: java not found: the kafka pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A jar is run only once it matches the digest above: $1 the jar, $2 its digest.
checked() {
    if [ ! -f "$1" ]; then
        echo "kafka_connections: ${1##*/} not found: this copy of the pack has none: install the pack from a packs release (vigil pack install kafka), or build it (tools/release/client-jar.sh)" >&2
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
        echo "kafka_connections: ${1##*/} does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs" >&2
        exit 1
    fi
}
checked "$here/_probe.jar" "$probe_sha256"

# The probe reads this job's table: the brokers' JMX only, no Kafka library.
set -- -cp "$here/_probe.jar" Probe "$here/_probe.tables"

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-kafka.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (the jvm
# pack would find it among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx256m \
    -Djava.io.tmpdir="$work" "$@" kafka_connections
exit $?
