#!/usr/bin/env bash
#
# producers.sh - an ActiveMQ broker's producers, and those held back
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
# Reports each producer: whether flow control holds it back now, how long it
# has been held back and its share of the time, and the messages it sent. The
# 100 held back longest first. Read-only: it reads attributes over JMX, and
# changes nothing.
#
# Reads each ActiveMQ Classic broker's JMX, at ACTIVEMQ_JMX: jmx=host:port, or
# jmxs=host:port over TLS, separated by ; or , each with a name first if you
# like (amq1: jmxs=host:port); with ACTIVEMQ_JMX_USER and the password in
# ACTIVEMQ_JMX_PASSWORD when JMX asks for them; a certificate is checked
# against ACTIVEMQ_CACERT, a PEM file of CAs, or Java's own, and against the
# server's name. With no ACTIVEMQ_JMX, it prints nothing. ActiveMQ Artemis is
# the artemis pack's; the broker's JVM (heap, garbage collection, threads,
# CPU, open files) is the jvm pack's, not this one's.
#
# The probe (_probe.jar, tools/probe) reads it, from this pack's
# _probe.tables, beside this script: nothing of ActiveMQ's is needed here.
#
# Metrics:
#   jmx_up                     1 when JMX answers, else 0, tagged broker=<its
#                              name> and jmx=<its address>
#   blocked_seconds            how long it has been held back by flow control,
#                              added up, tagged destinationName=<its
#                              destination> and clientId=<its client>; the
#                              longest first
#   blocked                    1 when flow control holds it back now, tagged
#                              the same
#   blocked_pct                of its time, held back, tagged the same
#   sent_count                 messages it sent, tagged the same
#   blocked_seconds_not_shown
#                              of blocked_seconds, those past the first 100,
#                              left out (the largest are shown)
#   blocked_not_shown          of blocked, those past the first 100, left out
#                              (the largest are shown)
#   blocked_pct_not_shown      of blocked_pct, those past the first 100, left
#                              out (the largest are shown)
#   sent_count_not_shown       of sent_count, those past the first 100, left
#                              out (the largest are shown)
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your brokers):
#   Healthy  blocked 0 for every producer.
#   Watch    blocked_pct climbing on one producer.
#   Act      blocked 1 for minutes: its destination is at its memory limit
#            (activemq_queues memory_pct), and the producer waits; nothing
#            reads what it sends.
#
# Requires: bash, Java 11 or later (JAVA_HOME, or java on the PATH), a JDK or
#   a JRE, to run _probe.jar, beside this script, once it matches its digest;
#   ActiveMQ's JMX
# Exit code: 0 on success, ActiveMQ up or down (jmx_up says which); 1 if Java
#   is missing, _probe.jar does not match its digest, or JMX refuses the login
#   or its certificate

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
    echo "activemq_producers: java not found: the activemq pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "activemq_producers: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install activemq), or build it (tools/release/client-jar.sh)" >&2
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
    echo "activemq_producers: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify activemq says what differs" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-activemq.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (the jvm
# pack would find it among the JVMs it watches). The probe reads this job's
# table.
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" activemq_producers
exit $?
