#!/usr/bin/env bash
#
# gclog.sh - a JVM's GC pauses, from its log
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
# Reports the pauses in the last five minutes of a JVM's GC log: how many, the
# longest, the 99th percentile and in all; full collections; allocation stalls
# (ZGC). By the log's own clock, from its last 4 MB. Read-only: it changes
# nothing in the JVM, and nothing it does pauses one.
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
#   jvms                      the JVMs the job looked at (untagged)
#   window_seconds            the window: 300
#   pauses                    pauses in it
#   pause_max_ms              the longest
#   pause_p99_ms              the 99th percentile
#   pause_total_ms            all of them
#   full_gcs                  full collections in it
#   allocation_stalls_in_log  ZGC allocation stalls in the log read
#
# Example output:
#   metric jvms 8
#   metric window_seconds 300 jvm=j8
#   metric pauses 4026 jvm=j8
#   metric pause_max_ms 262.8516 jvm=j8
#   metric pause_p99_ms 139.2999 jvm=j8
#   metric pause_total_ms 210454.3606 jvm=j8
#   metric full_gcs 2639 jvm=j8
#   metric allocation_stalls_in_log 0 jvm=j8
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  pause_p99_ms small for the collector; full_gcs 0.
#   Watch    pause_max_ms rising.
#   Act      full_gcs above 0 with G1 or ZGC: they fell back to a full
#            collection; allocation_stalls_in_log rising: ZGC could not keep
#            up, and threads waited.
#
# Requires: bash, Java 11 or later, a JDK or a JRE (JAVA_HOME, or java on the
#   PATH), to run _client.jar, beside this script, once it matches its digest;
#   a copy of the pack without the jar runs _client.java, which needs a JDK
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
    echo "jvm_gclog: java not found: the jvm pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar, the client compiled, once it matches the digest above: any Java
# 11 or later runs it. A copy of the pack without one (from the repository,
# not a release) runs the source, which needs a JDK.
if [ ! -f "$here/_client.jar" ]; then
    set -- "$here/_client.java"
else
    if command -v sha256sum > /dev/null 2>&1; then
        sum=$(sha256sum < "$here/_client.jar")
    elif command -v shasum > /dev/null 2>&1; then
        sum=$(shasum -a 256 < "$here/_client.jar")
    else
        sum=$(openssl dgst -sha256 -r < "$here/_client.jar")
    fi
    if [ "${sum%% *}" != "$jar_sha256" ]; then
        echo "jvm_gclog: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jvm says what differs" >&2
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
    -Djava.io.tmpdir="$work" "$@" jvm_gclog
exit $?
