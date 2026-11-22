#!/usr/bin/env bash
#
# hot_threads.sh - a JVM's busiest threads
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
# Reports the threads using the most CPU, over two seconds: what is busy, by
# name. Read-only: it changes nothing in the JVM, and nothing it does pauses
# one.
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
#   jvms                the JVMs the job looked at (untagged)
#   jmx_up              1 when the JVM answered at its JMX address, 0 when not
#                       (only for a JVM with one)
#   cpu_time_enabled    0 when the JVM does not measure threads' CPU (and
#                       nothing else is shown)
#   cpu_percent_total   all threads, in percent of one CPU
#   cpu_percent         a thread, tagged thread=<its name> (the top 10, from
#                       0.5%)
#   busy_threads_shown  threads shown
#
# Example output:
#   metric jvms 8
#   metric cpu_percent_total 74.0995 jvm=j25
#   metric cpu_percent 70.3834 jvm=j25 thread=busy-loop
#   metric cpu_percent 3.3585 jvm=j25 thread=busy
#   metric busy_threads_shown 2 jvm=j25
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  The threads you expect at the top.
#   Watch    GC threads at the top: see jvm_gc.
#   Act      one thread near 100 for a long time: a loop that does not end.
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
    echo "jvm_hot_threads: java not found: the jvm pack runs its client with a JDK 11 or later, on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jvm.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (it would
# find itself among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" "$here/_client.java" jvm_hot_threads
exit $?
