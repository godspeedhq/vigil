#!/usr/bin/env bash
#
# apps.sh - each web application in a Tomcat
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
# Reports each web application: whether it is started (an app that failed to
# start is FAILED), how long since it started and how long starting took, and
# its requests, errors (an exception), time and slowest request since then.
# The apps with the most errors first. Read-only: it reads attributes over
# JMX, and changes nothing.
#
# Reads each Tomcat's JMX, at TOMCAT_JMX: jmx=host:port, or jmxs=host:port
# over TLS, separated by ; or , each with a name first if you like (web1:
# jmxs=host:port); with TOMCAT_JMX_USER and the password in
# TOMCAT_JMX_PASSWORD when JMX asks for them; a certificate is checked against
# TOMCAT_CACERT, a PEM file of CAs, or Java's own, and against the server's
# name. With no TOMCAT_JMX, it prints nothing. Tomcat's JVM (heap, garbage
# collection, threads, CPU, open files) is the jvm pack's, not this one's.
#
# The probe (_probe.jar, tools/probe) reads it, from this pack's
# _probe.tables, beside this script: nothing of Tomcat's is needed here.
#
# Metrics:
#   jmx_up                        1 when JMX answers, else 0, tagged
#                                 tomcat=<its name> and jmx=<its address>
#   up                            1 when the app is started, else 0 (FAILED,
#                                 STOPPED), tagged name=<//host/path>
#   uptime_seconds                since the app started, tagged the same
#   startup_seconds               how long it took to start, tagged the same
#   errors_count                  requests that ended in an exception, tagged
#                                 the same; the most first
#   requests_count                requests, tagged the same
#   processing_seconds            time spent on requests, tagged the same
#   slowest_seconds               the slowest request, tagged the same
#   up_not_shown                  of up, those past the first 100, left out
#                                 (the largest are shown)
#   uptime_seconds_not_shown      of uptime_seconds, those past the first 100,
#                                 left out (the largest are shown)
#   startup_seconds_not_shown     of startup_seconds, those past the first
#                                 100, left out (the largest are shown)
#   errors_count_not_shown        of errors_count, those past the first 100,
#                                 left out (the largest are shown)
#   requests_count_not_shown      of requests_count, those past the first 100,
#                                 left out (the largest are shown)
#   processing_seconds_not_shown
#                                 of processing_seconds, those past the first
#                                 100, left out (the largest are shown)
#   slowest_seconds_not_shown     of slowest_seconds, those past the first
#                                 100, left out (the largest are shown)
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your Tomcat):
#   Healthy  up 1 for every app; uptime_seconds only growing; errors_count
#            flat or rising slowly.
#   Watch    uptime_seconds falling back: the app was restarted or redeployed;
#            errors_count rising.
#   Act      up 0: the app failed to start or was stopped, and answers 404
#            (Tomcat's log says why).
#
# Requires: bash, Java 11 or later (JAVA_HOME, or java on the PATH), a JDK or
#   a JRE, to run _probe.jar, beside this script, once it matches its digest;
#   Tomcat's JMX
# Exit code: 0 on success, Tomcat up or down (jmx_up says which); 1 if Java is
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
    echo "tomcat_apps: java not found: the tomcat pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "tomcat_apps: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install tomcat), or build it (tools/release/client-jar.sh)" >&2
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
    echo "tomcat_apps: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify tomcat says what differs" >&2
    exit 1
fi

# A folder of this run's own, readable by this account only, for what Java
# writes while it runs: gone when the run ends.
work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vigil-tomcat.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# A small JVM, quick to start, that keeps no counters of its own (the jvm
# pack would find it among the JVMs it watches). The probe reads this job's
# table.
"$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m \
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" tomcat_apps
exit $?
