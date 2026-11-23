#!/usr/bin/env bash
#
# cache.sh - a Tomcat's resource cache and JSPs
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
# Reports each app's static resource cache (lookups and hits, its size against
# its most), and its JSPs: how many are loaded, reloaded and unloaded, and the
# JSPs waiting to be unloaded. Read-only: it reads attributes over JMX, and
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
#   jmx_up                       1 when JMX answers, else 0, tagged
#                                tomcat=<its name> and jmx=<its address>
#   lookups_count                lookups in the app's resource cache, tagged
#                                host=<its host> and context=<its path>
#   hits_count                   of those, found in the cache, tagged the same
#   size_bytes                   what the cache holds, tagged the same
#   max_bytes                    the most it may hold, tagged the same
#   jsps                         JSPs loaded, tagged WebModule=<//host/path>
#   jsp_reloads_count            JSPs reloaded after a change, tagged the same
#   jsp_unloads_count            JSPs unloaded (maxLoadedJsps), tagged the
#                                same
#   jsp_queue                    JSPs waiting to be unloaded, when there is a
#                                limit, tagged the same
#   string_cache_lookups_count   lookups in Tomcat's string cache (when it is
#                                on)
#   string_cache_hits_count      of those, found
#   lookups_count_not_shown      of lookups_count, those past the first 100,
#                                left out
#   hits_count_not_shown         of hits_count, those past the first 100, left
#                                out
#   size_bytes_not_shown         of size_bytes, those past the first 100, left
#                                out
#   max_bytes_not_shown          of max_bytes, those past the first 100, left
#                                out
#   jsps_not_shown               of jsps, those past the first 100, left out
#   jsp_reloads_count_not_shown
#                                of jsp_reloads_count, those past the first
#                                100, left out
#   jsp_unloads_count_not_shown
#                                of jsp_unloads_count, those past the first
#                                100, left out
#   jsp_queue_not_shown          of jsp_queue, those past the first 100, left
#                                out
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 tomcat=tc11 jmx=localhost:19303
#   metric lookups_count 10 tomcat=tc11 jmx=localhost:19303 host=localhost context=/broken
#   metric hits_count 4 tomcat=tc11 jmx=localhost:19303 host=localhost context=/broken
#   metric size_bytes 0 tomcat=tc11 jmx=localhost:19303 host=localhost context=/broken
#   metric max_bytes 10485760 tomcat=tc11 jmx=localhost:19303 host=localhost context=/broken
#   metric jsps 4 tomcat=tc11 jmx=localhost:19303 WebModule=//localhost/shop
#   metric jsp_reloads_count 0 tomcat=tc11 jmx=localhost:19303 WebModule=//localhost/shop
#   metric jsp_unloads_count 0 tomcat=tc11 jmx=localhost:19303 WebModule=//localhost/shop
#
# Reading the results (starting points: tune them to your Tomcat):
#   Healthy  hits_count close to lookups_count; size_bytes below max_bytes;
#            jsp_reloads_count flat in production.
#   Watch    size_bytes at max_bytes with hits falling behind lookups: the
#            cache is too small (Tomcat warns).
#   Act      jsp_reloads_count rising in production: JSPs are being changed
#            under a running Tomcat.
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
    echo "tomcat_cache: java not found: the tomcat pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "tomcat_cache: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install tomcat), or build it (tools/release/client-jar.sh)" >&2
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
    echo "tomcat_cache: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify tomcat says what differs" >&2
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
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" tomcat_cache
exit $?
