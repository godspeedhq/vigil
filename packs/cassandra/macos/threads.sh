#!/usr/bin/env bash
#
# threads.sh - a Cassandra node's thread pools and dropped messages
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
# Reports each of the node's thread pools (reads, writes, compaction, gossip
# and the rest): tasks waiting, at work, and blocked; and the messages it
# dropped, by kind, because they waited past their timeout. Read-only: it
# reads attributes over JMX, and changes nothing.
#
# Reads each Cassandra node's JMX, at CASSANDRA_JMX: jmx=host:port, or
# jmxs=host:port over TLS, separated by ; or , each with a name first if you
# like (db1: jmx=host:7199); with CASSANDRA_JMX_USER and the password in
# CASSANDRA_JMX_PASSWORD when JMX asks for them; a certificate is checked
# against CASSANDRA_CACERT, a PEM file of CAs, or Java's own. With no
# CASSANDRA_JMX, it prints nothing. Cassandra's JVM (heap, garbage collection,
# threads) is the jvm pack's, not this one's.
#
# The probe (_probe.jar, tools/probe) reads it, from this pack's
# _probe.tables, beside this script: nothing of Cassandra's is needed here.
#
# Metrics:
#   jmx_up                        1 when JMX answers, else 0, tagged node=<its
#                                 name> and jmx=<its address>
#   pending                       tasks waiting in a pool, tagged
#                                 scope=<ReadStage, MutationStage,
#                                 CompactionExecutor, ...>
#   active                        tasks at work, tagged the same
#   blocked                       tasks blocked now (the pool is full), tagged
#                                 the same
#   blocked_count                 tasks that were blocked (a running total),
#                                 tagged the same
#   dropped_total_count           messages dropped, past their timeout, of
#                                 every kind (a running total)
#   dropped_count                 of those, each kind that dropped any, tagged
#                                 scope=<MUTATION, READ, ...> (some 90 kinds:
#                                 those at 0 are left out)
#   pending_not_shown             of pending, those past the first 100, left
#                                 out
#   active_not_shown              of active, those past the first 100, left
#                                 out
#   blocked_not_shown             of blocked, those past the first 100, left
#                                 out
#   blocked_count_not_shown       of blocked_count, those past the first 100,
#                                 left out
#   dropped_total_count_not_shown
#                                 of dropped_total_count, those past the first
#                                 100, left out
#   dropped_count_not_shown       of dropped_count, those past the first 100,
#                                 left out
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 node=c1 jmx=localhost:17199
#   metric pending 0 node=c1 jmx=localhost:17199 scope=MutationStage
#   metric pending 0 node=c1 jmx=localhost:17199 scope=ReadStage
#   metric blocked 0 node=c1 jmx=localhost:17199 scope=MutationStage
#   metric dropped_total_count 0 node=c1 jmx=localhost:17199
#
# Reading the results (starting points: tune them to your Cassandra):
#   Healthy  pending near 0; blocked 0; dropped_total_count flat.
#   Watch    pending rising in ReadStage or MutationStage; CompactionExecutor
#            pending growing.
#   Act      blocked above 0; dropped_total_count rising, dropped_count for
#            MUTATION or READ above all: the node is overloaded, and writes
#            are being lost to hints or reads to timeouts.
#
# Requires: bash, Java 11 or later (JAVA_HOME, or java on the PATH), a JDK or
#   a JRE, to run _probe.jar, beside this script, once it matches its digest;
#   Cassandra's JMX
# Exit code: 0 on success, Cassandra up or down (jmx_up says which); 1 if Java
#   is missing, _probe.jar does not match its digest, or JMX refuses the login
#   or its certificate

set -u

# The probe's SHA-256, written when the pack was released: built from
# _probe.java, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
probe_sha256=@PROBE_JAR_SHA256@

# The probe, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java=$JAVA_HOME/bin/java
elif command -v java > /dev/null 2>&1; then
    java=$(command -v java)
else
    echo "cassandra_threads: java not found: the cassandra pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "cassandra_threads: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install cassandra), or build it (tools/release/client-jar.sh)" >&2
    exit 1
fi
if command -v sha256sum > /dev/null 2>&1; then
    sum=$(sha256sum < "$here/_probe.jar")
elif command -v shasum > /dev/null 2>&1; then
    sum=$(shasum -a 256 < "$here/_probe.jar")
else
    sum=$(openssl dgst -sha256 -r < "$here/_probe.jar")
fi
if [ "${sum%% *}" != "$probe_sha256" ]; then
    echo "cassandra_threads: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify cassandra says what differs" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-cassandra.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (the jvm
# pack would find it among the JVMs it watches). The probe reads this job's
# table.
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" cassandra_threads
exit $?
