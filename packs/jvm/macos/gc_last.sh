#!/usr/bin/env bash
#
# gc_last.sh - a JVM's last collection
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
# Reports each collector's last collection: how long it took, how long ago,
# what it freed and what it left. Read-only: it changes nothing in the JVM,
# and nothing it does pauses one.
#
# From JMX, for each JVM given a JMX address in JVM_TARGETS (jmx=host:port, or
# jmxs=host:port for JMX over TLS, its certificate checked against JVM_CACERT
# or Java's own CAs, and against its name), as JVM_JMX_USER with the password
# in JVM_JMX_PASSWORD (a secret line, never a command line). A JVM with an
# address that does not answer reports jmx_up 0.
# JVM_TARGETS names the JVMs: name: key=value, ...; name: ... with main=<its
# main class or jar, or any text on its command line> or pid=<a pid file> to
# find it on this machine, and jmx= or jmxs= for its JMX address. Empty, it
# watches every JVM on this machine, each named by its main class. Each metric
# is tagged jvm=<name>; jvms is how many JVMs the job looked at.
#
# Metrics:
#   jvms         the JVMs the job looked at (untagged)
#   jmx_up       1 when the JVM answered at its JMX address, 0 when not (only
#                for a JVM with one)
#   duration_ms  how long it took, tagged collector=<its name>
#   seconds_ago  since it ended, tagged the same
#   freed_bytes  what it freed, tagged the same
#   after_bytes  memory in use after it, tagged the same
#
# Example output:
#   metric jvms 8
#   metric duration_ms 1 jvm=j21 collector=G1_Concurrent_GC
#   metric seconds_ago 0.803 jvm=j21 collector=G1_Concurrent_GC
#   metric freed_bytes 0 jvm=j21 collector=G1_Concurrent_GC
#   metric after_bytes 148555256 jvm=j21 collector=G1_Concurrent_GC
#   metric duration_ms 86 jvm=j21 collector=G1_Old_Generation
#   metric seconds_ago 315.652 jvm=j21 collector=G1_Old_Generation
#   metric freed_bytes 250167632 jvm=j21 collector=G1_Old_Generation
#   metric after_bytes 29118368 jvm=j21 collector=G1_Old_Generation
#   metric duration_ms 13 jvm=j21 collector=G1_Young_Generation
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  freed_bytes large, after_bytes small.
#   Watch    an old collector's freed_bytes small: little to free, much alive.
#   Act      duration_ms in seconds; an old collector run seconds_ago a few
#            seconds, again and again.
#
# Requires: bash, a JDK 11 or later (JAVA_HOME, or java on the PATH) to run
#   _client.java, beside this script
# Exit code: 0 on success, JVMs up or down; 1 if java is missing, JVM_TARGETS
#   is wrong, or a JVM refuses the JMX login or its certificate

set -u

# The client, beside this script, run by a JDK: JAVA_HOME's, else the PATH's.
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java=$JAVA_HOME/bin/java
elif command -v java > /dev/null 2>&1; then
    java=$(command -v java)
else
    echo "jvm_gc_last: java not found: the jvm pack runs its client with a JDK 11 or later, on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jvm.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (it would
# find itself among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" "$here/_client.java" jvm_gc_last
exit $?
