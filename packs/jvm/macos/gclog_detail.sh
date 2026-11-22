#!/usr/bin/env bash
#
# gclog_detail.sh - what a JVM's GC log says went wrong
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
# Reports the last fifteen minutes of a JVM's GC log: pauses by length, and
# what goes wrong: G1's humongous allocations (objects of half a region or
# more), to-space exhaustion, evacuation failure, promotion failure.
# Read-only: it changes nothing in the JVM, and nothing it does pauses one.
#
# From the JVM's GC log, for each JVM given one in JVM_TARGETS (gclog=<path>):
# unified logging (Java 9 and later: -Xlog:gc*:file=<path>; -Xlog:gc alone
# leaves out ZGC's and Shenandoah's pauses) or Java 8's -XX:+PrintGCDetails
# -XX:+PrintGCTimeStamps, readable by this account.
# JVM_TARGETS names the JVMs: name: key=value, ...; name: ... with main=<its
# main class or jar, or any text on its command line> or pid=<a pid file> to
# find it on this machine, and jmx= or jmxs= for its JMX address. Empty, it
# watches every JVM on this machine, each named by its main class. Each metric
# is tagged jvm=<name>; jvms is how many JVMs the job looked at.
#
# Metrics:
#   jvms                          the JVMs the job looked at (untagged)
#   window_seconds                the window: 900
#   pauses                        pauses in it, tagged length=<under_10ms,
#                                 10_to_100ms, 100ms_to_1s, over_1s>
#   humongous_allocations_in_log  collections caused by humongous allocations,
#                                 in the log read
#   to_space_exhausted_in_log     to-space exhaustion, in the log read
#   evacuation_failures_in_log    evacuation failures, in the log read
#   promotion_failed_in_log       promotion failures, in the log read
#
# Example output:
#   metric jvms 8
#   metric pauses 1559 jvm=j21 length=under_10ms
#   metric pauses 2403 jvm=j21 length=10_to_100ms
#   metric pauses 47 jvm=j21 length=100ms_to_1s
#   metric pauses 0 jvm=j21 length=over_1s
#   metric window_seconds 900 jvm=j21
#   metric humongous_allocations_in_log 3302 jvm=j21
#   metric to_space_exhausted_in_log 0 jvm=j21
#   metric evacuation_failures_in_log 22 jvm=j21
#   metric promotion_failed_in_log 0 jvm=j21
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  Nothing over_1s; the failures 0.
#   Watch    humongous_allocations_in_log rising: big arrays; raise
#            -XX:G1HeapRegionSize, or make them smaller.
#   Act      to_space_exhausted_in_log or evacuation_failures_in_log rising:
#            G1 is out of room, and its pauses grow.
#
# Requires: bash, Java 11 or later (JAVA_HOME, or java on the PATH): a JDK
#   runs _client.java, beside this script; any other runs _client.jar, built
#   from it, once it matches its digest
# Exit code: 0 on success, JVMs up or down; 1 if java is missing, _client.jar
#   does not match its digest, JVM_TARGETS is wrong, or a JVM refuses the JMX
#   login or its certificate

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
    echo "jvm_gclog_detail: java not found: the jvm pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A JDK, with javac beside its java (links followed; on macOS, /usr/bin/java
# runs the JDK java_home names), runs the source. Any other Java runs the
# jar, once it matches the digest above.
bin=$java
n=0
while [ -L "$bin" ] && [ "$n" -lt 20 ]; do
    l=$(readlink "$bin")
    case $l in /*) bin=$l ;; *) bin=$(dirname "$bin")/$l ;; esac
    n=$((n + 1))
done
bin=$(dirname "$bin")
if [ "$bin" = /usr/bin ] && [ -x /usr/libexec/java_home ]; then
    bin=$(/usr/libexec/java_home 2> /dev/null)/bin
fi
if [ -x "$bin/javac" ]; then
    set -- "$here/_client.java"
elif [ ! -f "$here/_client.jar" ]; then
    echo "jvm_gclog_detail: $java is not a JDK, and this pack has no _client.jar to run instead: install the pack from a packs release (vigil pack install jvm), or use a JDK 11 or later" >&2
    exit 1
else
    if command -v sha256sum > /dev/null 2>&1; then
        sum=$(sha256sum < "$here/_client.jar")
    elif command -v shasum > /dev/null 2>&1; then
        sum=$(shasum -a 256 < "$here/_client.jar")
    else
        sum=$(openssl dgst -sha256 -r < "$here/_client.jar")
    fi
    if [ "${sum%% *}" != "$jar_sha256" ]; then
        echo "jvm_gclog_detail: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jvm says what differs" >&2
        exit 1
    fi
    set -- -cp "$here/_client.jar" JvmClient
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jvm.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (it would
# find itself among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" "$@" jvm_gclog_detail
exit $?
