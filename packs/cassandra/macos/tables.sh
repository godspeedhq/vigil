#!/usr/bin/env bash
#
# tables.sh - a Cassandra node's compactions and tables
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
# Reports the node's compactions (pending, done, bytes compacted) and its key
# cache; and for the application's tables (Cassandra's own keyspaces left
# out), the worst first: SSTables, compactions pending, SSTables read by a
# read, tombstones scanned by a read, the space on disk, and the largest
# partition. Read-only: it reads attributes over JMX, and changes nothing.
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
#   compactions_pending           compactions waiting
#   compactions_done_count        compactions done (a running total)
#   compacted_bytes_count         bytes compacted (a running total)
#   key_cache_hit_pct             reads that found their key in the key cache,
#                                 of all
#   sstables                      a table's SSTables, tagged keyspace=<its
#                                 keyspace> and scope=<the table>
#   table_compactions_pending     its compactions waiting, tagged the same
#   sstables_per_read_p99         SSTables a read had to look in, the 99th
#                                 percentile, tagged the same
#   tombstones_per_read_p99       tombstones a read scanned, the 99th
#                                 percentile, tagged the same
#   disk_bytes                    its live data on disk, tagged the same
#   partition_max_bytes           its largest partition, tagged the same
#   sstables_not_shown            of sstables, those past the first 100, left
#                                 out (the largest are shown)
#   table_compactions_pending_not_shown
#                                 of table_compactions_pending, those past the
#                                 first 100, left out (the largest are shown)
#   sstables_per_read_p99_not_shown
#                                 of sstables_per_read_p99, those past the
#                                 first 100, left out (the largest are shown)
#   tombstones_per_read_p99_not_shown
#                                 of tombstones_per_read_p99, those past the
#                                 first 100, left out (the largest are shown)
#   disk_bytes_not_shown          of disk_bytes, those past the first 100,
#                                 left out (the largest are shown)
#   partition_max_bytes_not_shown
#                                 of partition_max_bytes, those past the first
#                                 100, left out (the largest are shown)
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 node=c1 jmx=localhost:17199
#   metric compactions_pending 0 node=c1 jmx=localhost:17199
#   metric key_cache_hit_pct 74.8214 node=c1 jmx=localhost:17199
#   metric sstables 8 node=c1 jmx=localhost:17199 keyspace=app scope=events
#   metric sstables_per_read_p99 8 node=c1 jmx=localhost:17199 keyspace=app scope=events
#   metric tombstones_per_read_p99 3311 node=c1 jmx=localhost:17199 keyspace=app scope=tomb
#   metric disk_bytes 106822 node=c1 jmx=localhost:17199 keyspace=app scope=events
#
# Reading the results (starting points: tune them to your Cassandra):
#   Healthy  compactions_pending near 0; sstables_per_read_p99 a few;
#            tombstones_per_read_p99 low.
#   Watch    compactions_pending rising run after run; sstables in the dozens
#            for a table; tombstones_per_read_p99 past 1,000 (Cassandra
#            warns); partition_max_bytes past 100 MB.
#   Act      compactions_pending in the hundreds and growing;
#            tombstones_per_read_p99 near 100,000 (Cassandra fails the read);
#            partition_max_bytes past 1 GB.
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
    echo "cassandra_tables: java not found: the cassandra pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "cassandra_tables: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install cassandra), or build it (tools/release/client-jar.sh)" >&2
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
    echo "cassandra_tables: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify cassandra says what differs" >&2
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
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" cassandra_tables
exit $?
