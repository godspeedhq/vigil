#!/usr/bin/env bash
#
# status.sh - a Jetty's health
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
# Reports whether each Jetty answers over JMX, its version, whether the server
# and each web application are started, how long since it started (9.4 to 11),
# and whether it is low on resources (the lowresources module), and since
# when. Read-only: it reads attributes over JMX, and changes nothing.
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
#   version                      always 1, tagged version=<Jetty's version,
#                                12.1.15>
#   up                           1 when the server is started, else 0
#   uptime_seconds               since the server started (9.4 to 11: 12 gives
#                                it as a text)
#   app_up                       1 when the web application is started, else 0
#                                (FAILED, STOPPED), tagged context=<its name>.
#                                Jetty keeps an app whose start failed STARTED
#                                and answers 503, unless it throws
#                                (throwUnavailableOnStartupException): its
#                                503s show in jetty_requests
#   low_on_resources             1 when the low resources monitor says so,
#                                else 0
#   low_since_seconds            how long it has been low on resources, when
#                                it is
#   version_not_shown            of version, those past the first 100, left
#                                out
#   up_not_shown                 of up, those past the first 100, left out
#   uptime_seconds_not_shown     of uptime_seconds, those past the first 100,
#                                left out
#   app_up_not_shown             of app_up, those past the first 100, left out
#   low_on_resources_not_shown   of low_on_resources, those past the first
#                                100, left out
#   low_since_seconds_not_shown
#                                of low_since_seconds, those past the first
#                                100, left out
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 jetty=j121 jmx=localhost:19314
#   metric version 1 jetty=j121 jmx=localhost:19314 version=12.1.15
#   metric up 1 jetty=j121 jmx=localhost:19314
#   metric app_up 1 jetty=j121 jmx=localhost:19314 context=_broken
#   metric low_on_resources 0 jetty=j121 jmx=localhost:19314
#
# Reading the results (starting points: tune them to your Jetty):
#   Healthy  jmx_up 1; up 1 and every app_up 1; low_on_resources 0.
#   Watch    uptime_seconds falling back: Jetty restarted; version older than
#            the newest of its line.
#   Act      jmx_up 0: Jetty or its JMX is down; app_up 0: that app answers
#            404 (and responses_5xx_count rising may be an app that failed to
#            start, answering 503); low_on_resources 1: Jetty is closing idle
#            connections early and may stop accepting.
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
    echo "jetty_status: java not found: the jetty pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "jetty_status: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install jetty), or build it (tools/release/client-jar.sh)" >&2
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
    echo "jetty_status: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jetty says what differs" >&2
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
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" jetty_status
exit $?
