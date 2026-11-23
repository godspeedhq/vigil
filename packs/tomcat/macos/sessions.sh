#!/usr/bin/env bash
#
# sessions.sh - a Tomcat's HTTP sessions, by app
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
# Reports each app's HTTP sessions: active now, the most at once, the limit if
# one is set and how many were refused for it, created and expired since the
# app started, the rates of both, and how long sessions live. The apps with
# the most sessions first. Read-only: it reads attributes over JMX, and
# changes nothing.
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
#   active                        sessions active now, tagged host=<its host>
#                                 and context=<its path>; the most first
#   most                          the most active at once since the app
#                                 started, tagged the same
#   limit                         the most it allows (maxActiveSessions), when
#                                 one is set, tagged the same
#   rejected_count                sessions refused for the limit, tagged the
#                                 same
#   created_count                 sessions created, tagged the same
#   expired_count                 sessions expired, tagged the same
#   created_per_minute            sessions created a minute, over the last
#                                 100, tagged the same
#   expired_per_minute            sessions expired a minute, over the last
#                                 100, tagged the same
#   average_alive_seconds         how long the last 100 expired sessions
#                                 lived, on average, tagged the same
#   longest_alive_seconds         the longest any expired session lived,
#                                 tagged the same
#   active_not_shown              of active, those past the first 100, left
#                                 out (the largest are shown)
#   most_not_shown                of most, those past the first 100, left out
#                                 (the largest are shown)
#   limit_not_shown               of limit, those past the first 100, left out
#                                 (the largest are shown)
#   rejected_count_not_shown      of rejected_count, those past the first 100,
#                                 left out (the largest are shown)
#   created_count_not_shown       of created_count, those past the first 100,
#                                 left out (the largest are shown)
#   expired_count_not_shown       of expired_count, those past the first 100,
#                                 left out (the largest are shown)
#   created_per_minute_not_shown
#                                 of created_per_minute, those past the first
#                                 100, left out (the largest are shown)
#   expired_per_minute_not_shown
#                                 of expired_per_minute, those past the first
#                                 100, left out (the largest are shown)
#   average_alive_seconds_not_shown
#                                 of average_alive_seconds, those past the
#                                 first 100, left out (the largest are shown)
#   longest_alive_seconds_not_shown
#                                 of longest_alive_seconds, those past the
#                                 first 100, left out (the largest are shown)
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 tomcat=tc11 jmx=localhost:19303
#   metric active 40 tomcat=tc11 jmx=localhost:19303 host=localhost context=/shop
#   metric most 40 tomcat=tc11 jmx=localhost:19303 host=localhost context=/shop
#   metric limit 40 tomcat=tc11 jmx=localhost:19303 host=localhost context=/shop
#   metric rejected_count 11 tomcat=tc11 jmx=localhost:19303 host=localhost context=/shop
#   metric created_count 40 tomcat=tc11 jmx=localhost:19303 host=localhost context=/shop
#   metric expired_count 0 tomcat=tc11 jmx=localhost:19303 host=localhost context=/shop
#   metric created_per_minute 79 tomcat=tc11 jmx=localhost:19303 host=localhost context=/shop
#   metric expired_per_minute 0 tomcat=tc11 jmx=localhost:19303 host=localhost context=/shop
#   metric average_alive_seconds 0 tomcat=tc11 jmx=localhost:19303 host=localhost context=/shop
#   metric longest_alive_seconds 0 tomcat=tc11 jmx=localhost:19303 host=localhost context=/shop
#
# Reading the results (starting points: tune them to your Tomcat):
#   Healthy  active rising and falling with traffic; rejected_count 0.
#   Watch    active climbing without falling back: sessions created and never
#            used again (bots, a client that keeps no cookie) hold memory
#            until they expire.
#   Act      rejected_count rising: users are refused a session at the limit;
#            active near limit.
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
    echo "tomcat_sessions: java not found: the tomcat pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "tomcat_sessions: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install tomcat), or build it (tools/release/client-jar.sh)" >&2
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
    echo "tomcat_sessions: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify tomcat says what differs" >&2
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
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" tomcat_sessions
exit $?
