#!/usr/bin/env bash
#
# tlab.sh - a JVM's thread-local allocation
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
# Reports allocation outside the threads' own buffers, where it is slow: a
# sign of heavy allocation, or of big objects. Read-only: it changes nothing
# in the JVM, and nothing it does pauses one.
#
# From the JVM's own counters, the hsperfdata file HotSpot JVMs keep (unless
# started with -XX:-UsePerfData): on this machine, readable by the account
# that runs the JVM, or by root or an administrator.
# JVM_TARGETS names the JVMs: name: key=value, ...; name: ... with main=<its
# main class or jar, or any text on its command line> or pid=<a pid file> to
# find it on this machine, and jmx= or jmxs= for its JMX address. Empty, it
# watches every JVM on this machine, each named by its main class. Each metric
# is tagged jvm=<name>; jvms is how many JVMs the job looked at.
#
# Metrics:
#   jvms                  the JVMs the job looked at (untagged)
#   allocated_words       allocated in buffers since the last collection, in
#                         words
#   threads               threads that allocated
#   refills               buffers refilled
#   refills_max           the most refills by one thread
#   slow_allocations      allocations outside a buffer
#   slow_allocations_max  the most by one thread
#   waste_gc_words        buffer left unused at a collection, in words
#   waste_refill_words    buffer left unused at a refill, in words
#
# Example output:
#   metric jvms 8
#   metric allocated_words 12032 jvm=plain
#   metric threads 1 jvm=plain
#   metric refills 1 jvm=plain
#   metric refills_max 1 jvm=plain
#   metric slow_allocations 1 jvm=plain
#   metric slow_allocations_max 1 jvm=plain
#   metric waste_gc_words 1782 jvm=plain
#   metric waste_refill_words 0 jvm=plain
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  slow_allocations small against refills.
#   Watch    slow_allocations rising.
#   Act      slow_allocations as many as refills: allocation is going the slow
#            way.
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
    echo "jvm_tlab: java not found: the jvm pack runs its client with a JDK 11 or later, on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jvm.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (it would
# find itself among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" "$here/_client.java" jvm_tlab
exit $?
