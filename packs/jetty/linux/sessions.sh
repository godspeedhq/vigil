#!/usr/bin/env bash
#
# sessions.sh - a Jetty's HTTP sessions, by app
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
# Reports each app's session cache (sessions now, the most at once, every one
# created) and its session handler (sessions created, how long they live,
# their timeout). Read-only: it reads attributes over JMX, and changes
# nothing.
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
#   jmx_up                        1 when JMX answers, else 0, tagged
#                                 jetty=<its name> and jmx=<its address>
#   current                       sessions in the cache now, tagged
#                                 context=<its app>; the most first
#   most                          the most at once, tagged the same
#   cached_count                  sessions it has held, tagged the same
#   created_count                 sessions created, tagged the same
#   alive_mean_seconds            how long a session lives, on average, tagged
#                                 the same
#   alive_max_seconds             the longest a session lived, tagged the same
#   timeout_seconds               how long an idle session lives, tagged the
#                                 same
#   current_not_shown             of current, those past the first 100, left
#                                 out (the largest are shown)
#   most_not_shown                of most, those past the first 100, left out
#                                 (the largest are shown)
#   cached_count_not_shown        of cached_count, those past the first 100,
#                                 left out (the largest are shown)
#   created_count_not_shown       of created_count, those past the first 100,
#                                 left out
#   alive_mean_seconds_not_shown
#                                 of alive_mean_seconds, those past the first
#                                 100, left out
#   alive_max_seconds_not_shown   of alive_max_seconds, those past the first
#                                 100, left out
#   timeout_seconds_not_shown     of timeout_seconds, those past the first
#                                 100, left out
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 jetty=j121 jmx=localhost:19314
#   metric current 51 jetty=j121 jmx=localhost:19314 context=_shop
#   metric most 51 jetty=j121 jmx=localhost:19314 context=_shop
#   metric cached_count 51 jetty=j121 jmx=localhost:19314 context=_shop
#   metric created_count 0 jetty=j121 jmx=localhost:19314 context=_broken
#   metric alive_mean_seconds 0 jetty=j121 jmx=localhost:19314 context=_broken
#   metric timeout_seconds 1800 jetty=j121 jmx=localhost:19314 context=_broken
#
# Reading the results (starting points: tune them to your Jetty):
#   Healthy  current rising and falling with traffic.
#   Watch    current climbing without falling back: sessions created and never
#            used again hold memory until they time out.
#   Act      current far above what your users explain: a client or a bot
#            making a session each request.
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
    echo "jetty_sessions: java not found: the jetty pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "jetty_sessions: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install jetty), or build it (tools/release/client-jar.sh)" >&2
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
    echo "jetty_sessions: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jetty says what differs" >&2
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
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" jetty_sessions
exit $?
