#!/usr/bin/env bash
#
# config.sh - risky Kafka settings
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
# Reports the brokers' settings that matter most for safety, from the first
# broker, how many of them differ between brokers, and the topics whose own
# settings put their data at risk. Read-only: it changes nothing in the
# cluster.
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
#   unclean_leader_election          1 when an out-of-sync replica may become
#                                    leader, losing data
#   auto_create_topics               1 when a client creates a topic just by
#                                    naming it
#   auto_leader_rebalance            1 when leadership moves back to preferred
#                                    leaders by itself
#   authorizer                       1 when ACLs are checked
#   min_insync_replicas              the default min.insync.replicas
#   default_replication_factor       the replication factor of a topic created
#                                    without one
#   offsets_replication_factor       the consumer offsets topic's
#   transactions_replication_factor  the transaction state topic's
#   message_max_bytes                the largest batch a broker takes
#   retention_hours                  how long messages are kept by default; -1
#                                    forever
#   plaintext_listeners              listeners without TLS or a login, the
#                                    controllers' left out
#   settings_differ                  settings with different values on
#                                    different brokers
#   topics_unclean_election          topics that allow unclean leader election
#   topics_min_isr_ge_rf             topics with more replicas than one whose
#                                    min.insync.replicas is at least their
#                                    replication factor: one replica down and
#                                    writes with acks=all fail
#   topics_min_isr_1                 topics with 3 or more replicas but
#                                    min.insync.replicas 1: acks=all keeps
#                                    only one copy
#
# Example output (the rest are in the same form):
#   metric unclean_leader_election 0
#   metric auto_create_topics 1
#   metric min_insync_replicas 2
#   metric retention_hours 168
#   metric plaintext_listeners 2
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  unclean_leader_election 0; min_insync_replicas 2 with a
#            replication factor of 3; settings_differ 0.
#   Watch    auto_create_topics 1 in production: a typo makes a topic;
#            plaintext_listeners above 0.
#   Act      unclean_leader_election 1, or topics_unclean_election above 0,
#            where data must not be lost; topics_min_isr_ge_rf above 0.
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
    echo "kafka_config: java not found: the kafka pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# Kafka's library, the user's: KAFKA_LIBS, else a Kafka download's libs/.
libs=${KAFKA_LIBS-}
if [ -z "$libs" ] && [ -n "${KAFKA_HOME-}" ]; then
    libs=$KAFKA_HOME/libs
fi
if [ -z "$libs" ]; then
    echo "kafka_config: no Kafka library: set KAFKA_HOME to a Kafka download, or KAFKA_LIBS to a folder of its jars" >&2
    exit 1
fi
found=no
for f in "$libs"/kafka-clients-*.jar; do [ -f "$f" ] && found=yes; done
if [ "$found" = no ]; then
    echo "kafka_config: no kafka-clients-*.jar in $libs: KAFKA_HOME is a Kafka download (its libs/), KAFKA_LIBS a folder of its jars" >&2
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
        echo "kafka_config: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs" >&2
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
    -Djava.io.tmpdir="$work" "$@" kafka_config
exit $?
