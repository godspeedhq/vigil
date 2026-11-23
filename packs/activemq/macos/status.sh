#!/usr/bin/env bash
#
# status.sh - an ActiveMQ broker's health
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
# Reports whether each broker answers over JMX, its name and version, how long
# it has been up, its health check (Good, or what is wrong), whether it is a
# slave (master/slave), and each transport connector: started, and connections
# refused for its maximumConnections. Read-only: it reads attributes over JMX,
# and changes nothing.
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
#   jmx_up                        1 when JMX answers, else 0, tagged
#                                 broker=<its name> and jmx=<its address>
#   version                       always 1, tagged version=<ActiveMQ's
#                                 version, 6.2.0>
#   broker                        always 1, tagged broker_name=<the broker's
#                                 own name>
#   uptime_seconds                since the broker started
#   healthy                       1 when the broker's health check says Good,
#                                 else 0
#   slave                         1 when it is a slave, waiting for the master
#                                 (the store lock), else 0
#   connector_up                  1 when the transport connector is started,
#                                 tagged connectorName=<openwire, amqp...>
#   connections_refused_count     connections refused for its
#                                 maximumConnections, tagged the same
#   version_not_shown             of version, those past the first 100, left
#                                 out
#   broker_not_shown              of broker, those past the first 100, left
#                                 out
#   uptime_seconds_not_shown      of uptime_seconds, those past the first 100,
#                                 left out
#   healthy_not_shown             of healthy, those past the first 100, left
#                                 out
#   slave_not_shown               of slave, those past the first 100, left out
#   connector_up_not_shown        of connector_up, those past the first 100,
#                                 left out
#   connections_refused_count_not_shown
#                                 of connections_refused_count, those past the
#                                 first 100, left out
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 broker=a62 jmx=localhost:19323
#   metric version 1 broker=a62 jmx=localhost:19323 version=6.2.0
#   metric broker 1 broker=a62 jmx=localhost:19323 broker_name=a62
#   metric uptime_seconds 257.286 broker=a62 jmx=localhost:19323
#   metric healthy 1 broker=a62 jmx=localhost:19323
#   metric slave 0 broker=a62 jmx=localhost:19323
#   metric connector_up 1 broker=a62 jmx=localhost:19323 connectorName=openwire
#   metric connections_refused_count 0 broker=a62 jmx=localhost:19323 connectorName=openwire
#
# Reading the results (starting points: tune them to your brokers):
#   Healthy  jmx_up 1; healthy 1; every connector_up 1;
#            connections_refused_count flat.
#   Watch    uptime_seconds falling back: the broker restarted; version older
#            than the newest of its line.
#   Act      jmx_up 0 or healthy 0: the broker is down or unwell (its log, and
#            the health MBean, say why); connections_refused_count rising:
#            clients are turned away; slave 1 on the broker that should be
#            master.
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
    echo "activemq_status: java not found: the activemq pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "activemq_status: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install activemq), or build it (tools/release/client-jar.sh)" >&2
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
    echo "activemq_status: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify activemq says what differs" >&2
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
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" activemq_status
exit $?
