#!/usr/bin/env bash
#
# buffers.sh - a Jetty's byte buffers
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
# Reports the memory Jetty's own byte buffer pools hold, direct and on the
# heap, and how much of it is free to reuse. The heap and direct memory of the
# whole JVM are the jvm pack's. Read-only: it reads attributes over JMX, and
# changes nothing.
#
# Reads each Jetty's JMX, at JETTY_JMX: jmx=host:port, or jmxs=host:port over
# TLS, separated by ; or , each with a name first if you like (web1:
# jmxs=host:port); with JETTY_JMX_USER and the password in JETTY_JMX_PASSWORD
# when JMX asks for them; a certificate is checked against JETTY_CACERT, a PEM
# file of CAs, or Java's own, and against the server's name. Jetty's MBeans
# are there with its jmx module. With no JETTY_JMX, it prints nothing. Jetty's
# JVM (heap, garbage collection, threads, CPU, open files) is the jvm pack's,
# not this one's.
#
# The probe (_probe.jar, tools/probe) reads it, from this pack's
# _probe.tables, beside this script: nothing of Jetty's is needed here.
#
# Metrics:
#   jmx_up                       1 when JMX answers, else 0, tagged jetty=<its
#                                name> and jmx=<its address>
#   direct_bytes                 direct memory its pools hold
#   heap_bytes                   heap memory its pools hold
#   direct_free_bytes            of the direct, free to reuse (12)
#   heap_free_bytes              of the heap, free to reuse (12)
#   direct_bytes_not_shown       of direct_bytes, those past the first 100,
#                                left out
#   heap_bytes_not_shown         of heap_bytes, those past the first 100, left
#                                out
#   direct_free_bytes_not_shown
#                                of direct_free_bytes, those past the first
#                                100, left out
#   heap_free_bytes_not_shown    of heap_free_bytes, those past the first 100,
#                                left out
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your Jetty):
#   Healthy  direct_bytes and heap_bytes steady.
#   Watch    direct_bytes growing without falling back.
#   Act      direct_bytes near the JVM's -XX:MaxDirectMemorySize: Jetty will
#            fail to allocate (the jvm pack's buffers job shows the limit).
#
# Requires: bash, Java 11 or later (JAVA_HOME, or java on the PATH), a JDK or
#   a JRE, to run _probe.jar, beside this script, once it matches its digest;
#   Jetty's JMX
# Exit code: 0 on success, Jetty up or down (jmx_up says which); 1 if Java is
#   missing, _probe.jar does not match its digest, or JMX refuses the login or
#   its certificate

set -u

# The probe's SHA-256, written when the pack was released: built from
# _probe.java, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
probe_sha256=@PROBE_JAR_SHA256@

# The probe, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${JAVA_HOME-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    java=$JAVA_HOME/bin/java
elif command -v java > /dev/null 2>&1; then
    java=$(command -v java)
else
    echo "jetty_buffers: java not found: the jetty pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "jetty_buffers: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install jetty), or build it (tools/release/client-jar.sh)" >&2
    exit 1
fi
if command -v sha256sum > /dev/null 2>&1; then
    sum=$(sha256sum < "$here/_probe.jar")
elif command -v shasum > /dev/null 2>&1; then
    sum=$(shasum -a 256 < "$here/_probe.jar")
else
    sum=$(openssl dgst -sha256 -r < "$here/_probe.jar")
fi
if [ "${sum%% *}" != "$probe_sha256" ]; then
    echo "jetty_buffers: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jetty says what differs" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-jetty.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (the jvm
# pack would find it among the JVMs it watches). The probe reads this job's
# table.
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" jetty_buffers
exit $?
