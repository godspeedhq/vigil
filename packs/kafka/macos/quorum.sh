#!/usr/bin/env bash
#
# quorum.sh - a KRaft cluster's controller quorum
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
# Reports the KRaft quorum that keeps the cluster's metadata: its leader and
# epoch, its high watermark, how far the followers lag, the voters and
# observers, and for each node how far behind it is and how long since it last
# fetched and last caught up. A cluster on ZooKeeper reports kraft 0 and
# nothing else. Read-only: it changes nothing in the cluster.
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
#   kraft                       1 when the cluster runs on KRaft, else 0
#   leader_id                   the quorum's leader, the active controller
#   leader_epoch                its epoch: it rises with each new leader
#   high_watermark              the metadata log's committed end
#   max_follower_lag            the most any follower is behind, in records
#   max_follower_lag_ms         the same, in milliseconds
#   voters                      controllers that vote
#   observers                   nodes that only follow (brokers)
#   node_lag                    how many records a node is behind, tagged
#                               node=<id> and role=<leader, follower or
#                               observer>
#   node_fetch_age_seconds      since the node last fetched, tagged the same
#   node_caught_up_age_seconds  since the node was last caught up, tagged the
#                               same
#
# Example output (the rest are in the same form):
#   metric kraft 1
#   metric leader_id 2
#   metric max_follower_lag 0
#   metric voters 3
#   metric node_lag 0 node=1 role=follower
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  kraft 1; max_follower_lag near 0; every node's
#            node_caught_up_age_seconds a few seconds.
#   Watch    leader_epoch rising often: the controllers keep losing their
#            leader; node_lag growing for one node.
#   Act      voters fewer than you run, or a voter's
#            node_caught_up_age_seconds in minutes: a controller is gone or
#            stuck. Lose a majority of voters and the cluster can change
#            nothing.
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
    echo "kafka_quorum: java not found: the kafka pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# Kafka's library, the user's: KAFKA_LIBS, else a Kafka download's libs/.
libs=${KAFKA_LIBS-}
if [ -z "$libs" ] && [ -n "${KAFKA_HOME-}" ]; then
    libs=$KAFKA_HOME/libs
fi
if [ -z "$libs" ]; then
    echo "kafka_quorum: no Kafka library: set KAFKA_HOME to a Kafka download, or KAFKA_LIBS to a folder of its jars" >&2
    exit 1
fi
found=no
for f in "$libs"/kafka-clients-*.jar; do [ -f "$f" ] && found=yes; done
if [ "$found" = no ]; then
    echo "kafka_quorum: no kafka-clients-*.jar in $libs: KAFKA_HOME is a Kafka download (its libs/), KAFKA_LIBS a folder of its jars" >&2
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
        echo "kafka_quorum: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs" >&2
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
    -Djava.io.tmpdir="$work" "$@" kafka_quorum
exit $?
