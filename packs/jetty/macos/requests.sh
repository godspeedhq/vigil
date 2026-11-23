#!/usr/bin/env bash
#
# requests.sh - a Jetty's requests and responses
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
# Reports the statistics module's figures for the whole server: requests and
# those active now, responses by class (1xx to 5xx), failures, the bytes in
# and out, and request times (the longest, the mean, the total), since Jetty
# started or its statistics were reset. Totals only grow: graph them as rates.
# Needs Jetty's statistics module (stats on 9.4 to 11). Read-only: it reads
# attributes over JMX, and changes nothing.
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
#   requests_count                requests
#   active                        requests being handled now
#   active_max                    the most at once
#   responses_1xx_count           responses with a 1xx status
#   responses_2xx_count           with a 2xx status
#   responses_3xx_count           with a 3xx status
#   responses_4xx_count           with a 4xx status
#   responses_5xx_count           with a 5xx status (on 9.4 to 11, not those
#                                 that threw: thrown_count)
#   failures_count                requests that failed (12)
#   handling_failures_count       failures while handling (12)
#   thrown_count                  requests that ended in an exception (9.4 to
#                                 11)
#   dispatched_count              dispatches to the application (9.4 to 11)
#   dispatched_active             dispatches running now (9.4 to 11)
#   handling_active               requests being handled by the application
#                                 now (12)
#   async_count                   asynchronous requests (9.4 to 11)
#   async_waiting                 asynchronous requests waiting now (9.4 to
#                                 11)
#   expired_count                 asynchronous requests that timed out (9.4 to
#                                 11)
#   received_bytes                bytes of requests read (12)
#   sent_bytes                    bytes of responses written
#   slowest_seconds               the slowest request
#   mean_seconds                  the mean time of a request
#   total_seconds                 the time of every request, added up
#   requests_count_not_shown      of requests_count, those past the first 100,
#                                 left out
#   active_not_shown              of active, those past the first 100, left
#                                 out
#   active_max_not_shown          of active_max, those past the first 100,
#                                 left out
#   responses_1xx_count_not_shown
#                                 of responses_1xx_count, those past the first
#                                 100, left out
#   responses_2xx_count_not_shown
#                                 of responses_2xx_count, those past the first
#                                 100, left out
#   responses_3xx_count_not_shown
#                                 of responses_3xx_count, those past the first
#                                 100, left out
#   responses_4xx_count_not_shown
#                                 of responses_4xx_count, those past the first
#                                 100, left out
#   responses_5xx_count_not_shown
#                                 of responses_5xx_count, those past the first
#                                 100, left out
#   failures_count_not_shown      of failures_count, those past the first 100,
#                                 left out
#   handling_failures_count_not_shown
#                                 of handling_failures_count, those past the
#                                 first 100, left out
#   thrown_count_not_shown        of thrown_count, those past the first 100,
#                                 left out
#   dispatched_count_not_shown    of dispatched_count, those past the first
#                                 100, left out
#   dispatched_active_not_shown   of dispatched_active, those past the first
#                                 100, left out
#   handling_active_not_shown     of handling_active, those past the first
#                                 100, left out
#   async_count_not_shown         of async_count, those past the first 100,
#                                 left out
#   async_waiting_not_shown       of async_waiting, those past the first 100,
#                                 left out
#   expired_count_not_shown       of expired_count, those past the first 100,
#                                 left out
#   received_bytes_not_shown      of received_bytes, those past the first 100,
#                                 left out
#   sent_bytes_not_shown          of sent_bytes, those past the first 100,
#                                 left out
#   slowest_seconds_not_shown     of slowest_seconds, those past the first
#                                 100, left out
#   mean_seconds_not_shown        of mean_seconds, those past the first 100,
#                                 left out
#   total_seconds_not_shown       of total_seconds, those past the first 100,
#                                 left out
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 jetty=j121 jmx=localhost:19314
#   metric requests_count 97 jetty=j121 jmx=localhost:19314
#   metric active 40 jetty=j121 jmx=localhost:19314
#   metric active_max 40 jetty=j121 jmx=localhost:19314
#   metric responses_1xx_count 0 jetty=j121 jmx=localhost:19314
#   metric responses_2xx_count 51 jetty=j121 jmx=localhost:19314
#   metric responses_3xx_count 0 jetty=j121 jmx=localhost:19314
#   metric responses_4xx_count 3 jetty=j121 jmx=localhost:19314
#   metric responses_5xx_count 3 jetty=j121 jmx=localhost:19314
#   metric failures_count 0 jetty=j121 jmx=localhost:19314
#   metric handling_failures_count 0 jetty=j121 jmx=localhost:19314
#   metric handling_active 16 jetty=j121 jmx=localhost:19314
#   metric received_bytes 0 jetty=j121 jmx=localhost:19314
#   metric sent_bytes 21981 jetty=j121 jmx=localhost:19314
#   metric slowest_seconds 1.2819 jetty=j121 jmx=localhost:19314
#   metric mean_seconds 0.027 jetty=j121 jmx=localhost:19314
#   metric total_seconds 1.5392 jetty=j121 jmx=localhost:19314
#
# Reading the results (starting points: tune them to your Jetty):
#   Healthy  responses_5xx_count flat; active well below the thread pool's
#            max; mean_seconds steady.
#   Watch    responses_4xx_count rising faster than requests: clients asking
#            for what is not there, or refused.
#   Act      responses_5xx_count rising: the server or the apps are failing;
#            active near the pool's max: requests are waiting for a thread.
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
    echo "jetty_requests: java not found: the jetty pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "jetty_requests: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install jetty), or build it (tools/release/client-jar.sh)" >&2
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
    echo "jetty_requests: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify jetty says what differs" >&2
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
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" jetty_requests
exit $?
