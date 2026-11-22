#!/usr/bin/env bash
#
# contention.sh - a JVM's contended locks
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
# Reports threads blocked on locks now, and the locks most waited for, by
# their class, with the thread that holds each. Read-only: it changes nothing
# in the JVM, and nothing it does pauses one.
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
#   jvms                 the JVMs the job looked at (untagged)
#   jmx_up               1 when the JVM answered at its JMX address, 0 when
#                        not (only for a JVM with one)
#   blocked              threads blocked on a lock now
#   waiting              threads waiting (for work, a condition, a timeout)
#   blocked_times_total  times threads have blocked, a running total
#   lock_waiters         threads waiting for a lock, tagged lock=<its class>
#                        and held_by=<a thread> (the top 10)
#
# Example output:
#   metric jvms 8
#   metric blocked 7 jvm=j17
#   metric waiting 6 jvm=j17
#   metric blocked_times_total 21560 jvm=j17
#   metric lock_waiters 7 jvm=j17 lock=java.lang.Object held_by=contender-3
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  blocked near 0.
#   Watch    blocked_times_total's rate rising; one lock always at the top.
#   Act      blocked a large share of live: the threads queue for one lock.
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
    echo "jvm_contention: java not found: the jvm pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
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
    echo "jvm_contention: $java is not a JDK, and this pack has no _client.jar to run instead: install the pack from a packs release (vigil pack install jvm), or use a JDK 11 or later" >&2
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
        echo "jvm_contention: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jvm says what differs" >&2
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
    -Djava.io.tmpdir="$work" "$@" jvm_contention
exit $?
