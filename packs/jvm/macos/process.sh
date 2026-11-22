#!/usr/bin/env bash
#
# process.sh - a JVM's process
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
# Reports each JVM's process as the operating system sees it: whether it runs,
# its memory, CPU, threads, open files against its limit, and how long it has
# run. A JVM named by main= or pid= that is not running reports running 0.
# Read-only: it changes nothing in the JVM, and nothing it does pauses one.
#
# From the operating system: the JVM's process, which needs nothing set up.
# JVM_TARGETS names the JVMs: name: key=value, ...; name: ... with main=<its
# main class or jar, or any text on its command line> or pid=<a pid file> to
# find it on this machine, and jmx= or jmxs= for its JMX address. Empty, it
# watches every JVM on this machine, each named by its main class. Each metric
# is tagged jvm=<name>; jvms is how many JVMs the job looked at.
#
# Metrics:
#   jvms            the JVMs the job looked at (untagged)
#   jmx_up          1 when the JVM answered at its JMX address, 0 when not
#                   (only for a JVM with one)
#   running         1 when the process runs, 0 when a JVM looked for is not
#                   found
#   rss_bytes       resident memory: what it holds in RAM
#   virtual_bytes   virtual memory reserved
#   cpu_seconds     CPU used since it started (a running total: graph its
#                   rate)
#   threads         its threads, as the operating system counts them (Linux,
#                   Windows)
#   open_files      open files and sockets (Linux, as root or its own account;
#                   Windows: handles)
#   open_files_max  its limit on open files (Linux)
#   uptime_seconds  since it started
#
# Example output:
#   metric jvms 8
#   metric running 1 jvm=j21
#   metric rss_bytes 371208192 jvm=j21
#   metric virtual_bytes 4020424704 jvm=j21
#   metric cpu_seconds 630.15 jvm=j21
#   metric threads 36 jvm=j21
#   metric open_files 10 jvm=j21
#   metric open_files_max 524288 jvm=j21
#   metric uptime_seconds 1016 jvm=j21
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  running 1; rss_bytes steady; uptime_seconds rising.
#   Watch    rss_bytes rising over days with a steady heap: memory outside the
#            heap (jvm_native_overhead).
#   Act      running 0; uptime_seconds falling back to near 0: it restarted;
#            open_files near open_files_max.
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
    echo "jvm_process: java not found: the jvm pack runs its client with a JDK 11 or later, on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jvm.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (it would
# find itself among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" "$here/_client.java" jvm_process
exit $?
