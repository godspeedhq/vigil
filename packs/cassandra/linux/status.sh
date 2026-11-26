#!/usr/bin/env bash
#
# status.sh - a Cassandra node's health
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
# Reports whether each node answers over JMX, its version and mode (normal, or
# joining, leaving, draining, drained, decommissioned), whether gossip and the
# native protocol (CQL) are running, the nodes it sees up and down, the data
# it holds, exceptions, hints kept for nodes that were away, clients
# connected, and the commit log. Read-only: it reads attributes over JMX, and
# changes nothing.
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
#   jmx_up             1 when JMX answers, else 0, tagged node=<its name> and
#                      jmx=<its address>
#   version            always 1, tagged version=<Cassandra's version, 5.0.9>
#   mode               always 1, tagged mode=<NORMAL, JOINING, LEAVING,
#                      DRAINING, DRAINED, DECOMMISSIONED>
#   normal             1 when the node is in normal operation, else 0
#   gossip_up          1 when gossip is running, else 0 (the node is cut off
#                      from the ring)
#   native_up          1 when the native protocol (CQL) takes clients, else 0
#   nodes_up           nodes this one sees up, itself included
#   nodes_down         nodes this one sees down
#   load_bytes         the data this node holds on disk
#   exceptions_count   errors Cassandra caught (a running total)
#   hints_count        hints written for nodes that were down (a running
#                      total)
#   hints_in_progress
#                      hints being sent now
#   clients            CQL clients connected
#   commitlog_pending
#                      commit log writes waiting
#   commitlog_bytes    the commit log on disk
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 node=c1 jmx=localhost:17199
#   metric version 1 node=c1 jmx=localhost:17199 version=5.0.9
#   metric mode 1 node=c1 jmx=localhost:17199 mode=NORMAL
#   metric normal 1 node=c1 jmx=localhost:17199
#   metric nodes_up 3 node=c1 jmx=localhost:17199
#   metric nodes_down 0 node=c1 jmx=localhost:17199
#   metric load_bytes 227820 node=c1 jmx=localhost:17199
#   metric hints_count 3 node=c1 jmx=localhost:17199
#
# Reading the results (starting points: tune them to your Cassandra):
#   Healthy  normal 1, gossip_up and native_up 1; nodes_down 0;
#            hints_in_progress 0; exceptions_count flat.
#   Watch    hints_count rising (a node was away: it is catching up);
#            commitlog_pending above 0 for several runs.
#   Act      the node down over JMX; normal 0 (draining, leaving,
#            decommissioned); gossip_up or native_up 0; nodes_down above 0: a
#            node is down, and with it, requests at QUORUM may fail.
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
    echo "cassandra_status: java not found: the cassandra pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "cassandra_status: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install cassandra), or build it (tools/release/client-jar.sh)" >&2
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
    echo "cassandra_status: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify cassandra says what differs" >&2
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
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" cassandra_status
exit $?
