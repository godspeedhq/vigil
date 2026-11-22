#!/usr/bin/env bash
#
# native.sh - a JVM's native memory
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
# Reports the JVM's own memory by what it is for (heap, classes, threads,
# code, GC, symbols...), when the JVM tracks it: started with
# -XX:NativeMemoryTracking=summary. Otherwise tracking 0, and nothing more.
# Read-only: it changes nothing in the JVM, and nothing it does pauses one.
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
#   jvms                      the JVMs the job looked at (untagged)
#   jmx_up                    1 when the JVM answered at its JMX address, 0
#                             when not (only for a JVM with one)
#   tracking                  1 when the JVM tracks its native memory
#   reserved_bytes            reserved, in all
#   committed_bytes           committed, in all
#   category_committed_bytes  committed, tagged category=<java_heap, class,
#                             thread, code, gc, ...>
#
# Example output:
#   metric jvms 8
#   metric tracking 1 jvm=j11
#   metric reserved_bytes 1923589120 jvm=j11
#   metric committed_bytes 356185088 jvm=j11
#   metric category_committed_bytes 36065280 jvm=j11 category=java_heap
#   metric category_committed_bytes 16615424 jvm=j11 category=class
#   metric category_committed_bytes 1812480 jvm=j11 category=thread
#   metric category_committed_bytes 12024832 jvm=j11 category=code
#   metric category_committed_bytes 275456 jvm=j11 category=gc
#   metric category_committed_bytes 5210112 jvm=j11 category=compiler
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  Every category steady once started.
#   Watch    thread rising: threads are made and not ended; class rising: a
#            classloader leak.
#   Act      committed_bytes near the machine's or container's memory: it will
#            be killed.
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
    echo "jvm_native: java not found: the jvm pack runs its client with a JDK 11 or later, on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jvm.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (it would
# find itself among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" "$here/_client.java" jvm_native
exit $?
