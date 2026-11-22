#!/usr/bin/env bash
#
# status.sh - a JVM's identity
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
# Reports whether each JVM is up, which tiers reach it (its process, its
# counters, JMX), and what it is: Java version, vendor, VM and garbage
# collectors; its uptime and its heap's maximum. Read-only: it changes nothing
# in the JVM, and nothing it does pauses one.
#
# From the operating system: the JVM's process, which needs nothing set up.
# From the JVM's own counters, the hsperfdata file HotSpot JVMs keep (unless
# started with -XX:-UsePerfData): on this machine, readable by the account
# that runs the JVM, or by root or an administrator.
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
#   jvms            the JVMs the job looked at (untagged)
#   jmx_up          1 when the JVM answered at its JMX address, 0 when not
#                   (only for a JVM with one)
#   up              1 when any tier finds the JVM, else 0
#   tier_os         1 when its process is found on this machine
#   tier_counters   1 when its counters can be read here
#   tier_jmx        1 when it answers over JMX
#   info            always 1, tagged version=, vendor=, vm= and gc=<its
#                   collectors, joined by +>
#   uptime_seconds  since it started
#   heap_max_bytes  the most heap it may use
#
# Example output:
#   metric jvms 8
#   metric up 1 jvm=j8
#   metric tier_os 1 jvm=j8
#   metric tier_counters 1 jvm=j8
#   metric tier_jmx 1 jvm=j8
#   metric info 1 jvm=j8 version=1.8.0_512 vendor=Temurin vm=OpenJDK_64-Bit_Server_VM gc=PS_MarkSweep+PS_Scavenge
#   metric uptime_seconds 961 jvm=j8
#   metric heap_max_bytes 266862592 jvm=j8
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  up 1, and the tiers you expect at 1.
#   Watch    info's version changing: the JVM was upgraded; a tier at 0 that
#            was 1.
#   Act      up 0: the JVM is gone; tier_jmx 0 with an address: JMX stopped
#            answering (jmx_up says the same).
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
    echo "jvm_status: java not found: the jvm pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
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
        echo "jvm_status: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jvm says what differs" >&2
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
    -Djava.io.tmpdir="$work" "$@" jvm_status
exit $?
