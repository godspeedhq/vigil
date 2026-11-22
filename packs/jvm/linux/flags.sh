#!/usr/bin/env bash
#
# flags.sh - a JVM's risky settings
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
# Reports settings that hurt when something goes wrong: no maximum heap, no
# heap dump on out-of-memory, no exit on out-of-memory, a removed or
# deprecated collector, a heap larger than the machine's memory. From its
# startup options; with JMX, the values it really runs with. Read-only: it
# changes nothing in the JVM, and nothing it does pauses one.
#
# From the operating system: the JVM's process, which needs nothing set up.
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
#   jvms                  the JVMs the job looked at (untagged)
#   jmx_up                1 when the JVM answered at its JMX address, 0 when
#                         not (only for a JVM with one)
#   heap_max_set          1 when the heap has a maximum set (-Xmx,
#                         MaxRAMPercentage or the like)
#   heap_dump_on_oom      1 when it writes a heap dump on out-of-memory
#   exit_on_oom           1 when it exits (or crashes, or runs a command) on
#                         out-of-memory
#   deprecated_gc         1 when it asks for CMS or ParNew, removed in Java 14
#   heap_over_memory      1 when its heap's maximum is more than the machine's
#                         memory (JMX)
#   explicit_gc_disabled  1 when System.gc() does nothing
#                         (-XX:+DisableExplicitGC)
#   risks                 how many of: no maximum heap, no heap dump, a
#                         deprecated collector, a heap over memory
#
# Example output:
#   metric jvms 8
#   metric heap_max_set 1 jvm=j21
#   metric heap_dump_on_oom 1 jvm=j21
#   metric exit_on_oom 0 jvm=j21
#   metric deprecated_gc 0 jvm=j21
#   metric heap_over_memory 0 jvm=j21
#   metric explicit_gc_disabled 0 jvm=j21
#   metric risks 0 jvm=j21
#
# Reading the results (starting points: tune them to the JVM):
#   Healthy  risks 0.
#   Watch    exit_on_oom 0: a JVM out of memory may limp on, half-working,
#            rather than restart.
#   Act      heap_over_memory 1: the machine will swap or kill it before the
#            heap fills; heap_dump_on_oom 0 on a JVM that has run out of
#            memory before: the next one will leave nothing to look at.
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
    echo "jvm_flags: java not found: the jvm pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# A jar is run only once it matches the digest above: $1 the jar, $2 its digest.
checked() {
    if [ ! -f "$1" ]; then
        echo "jvm_flags: ${1##*/} not found: this copy of the pack has none: install the pack from a packs release (vigil pack install jvm), or build it (tools/release/client-jar.sh)" >&2
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
        echo "jvm_flags: ${1##*/} does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jvm says what differs" >&2
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
    -Djava.io.tmpdir="$work" "$@" jvm_flags
exit $?
