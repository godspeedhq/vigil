#!/usr/bin/env bash
#
# gc_cpu.sh - the CPU a JVM's GC uses
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
# Reports the CPU the garbage collector's own threads have used, against the
# process's, where the JVM keeps it (HotSpot 22 and later): a collector
# quietly eating a core. Read-only: it changes nothing in the JVM, and nothing
# it does pauses one.
#
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
#   jvms                     the JVMs the job looked at (untagged)
#   jmx_up                   1 when the JVM answered at its JMX address, 0
#                            when not (only for a JVM with one)
#   gc_cpu_seconds           the GC threads' CPU, a running total
#   process_cpu_seconds      the process's CPU, a running total
#   gc_cpu_percent_lifetime  the GC threads' share of it
#
# Example output:
#   metric jvms 8
#   metric gc_cpu_seconds 2.6764 jvm=host
#   metric process_cpu_seconds 31.29 jvm=host
#   metric gc_cpu_percent_lifetime 8.5535 jvm=host
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  gc_cpu_percent_lifetime under 10.
#   Watch    gc_cpu_seconds' rate rising.
#   Act      gc_cpu_percent_lifetime above 25: the collector takes a quarter
#            of the JVM's CPU.
#
# Requires: bash, Java 11 or later, a JDK or a JRE (JAVA_HOME, or java on the
#   PATH), to run _client.jar and _probe.jar, beside this script, once they
#   match their digests
# Exit code: 0 on success, JVMs up or down; 1 if java is missing, a jar is
#   missing or does not match its digest, JVM_TARGETS is wrong, or a JVM
#   refuses the JMX login or its certificate

set -u

# The jars' SHA-256s, written when the pack was released: each built from
# its source, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
probe_sha256=@PROBE_JAR_SHA256@
client_sha256=@CLIENT_JAR_SHA256@

# The jars, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java=$JAVA_HOME/bin/java
elif command -v java > /dev/null 2>&1; then
    java=$(command -v java)
else
    echo "jvm_gc_cpu: java not found: the jvm pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A jar is run only once it matches the digest above: $1 the jar, $2 its digest.
checked() {
    if [ ! -f "$1" ]; then
        echo "jvm_gc_cpu: ${1##*/} not found: this copy of the pack has none: install the pack from a packs release (vigil pack install jvm), or build it (tools/release/client-jar.sh)" >&2
        exit 1
    fi
    if command -v sha256sum > /dev/null 2>&1; then
        sum=$(sha256sum < "$1")
    elif command -v shasum > /dev/null 2>&1; then
        sum=$(shasum -a 256 < "$1")
    else
        sum=$(openssl dgst -sha256 -r < "$1")
    fi
    if [ "${sum%% *}" != "$2" ]; then
        echo "jvm_gc_cpu: ${1##*/} does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jvm says what differs" >&2
        exit 1
    fi
}
checked "$here/_probe.jar" "$probe_sha256"
checked "$here/_client.jar" "$client_sha256"
set -- -cp "$here/_client.jar:$here/_probe.jar" JvmClient

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jvm.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (it would
# find itself among the JVMs it watches).
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" "$@" jvm_gc_cpu
exit $?
