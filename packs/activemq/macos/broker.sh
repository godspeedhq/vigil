#!/usr/bin/env bash
#
# broker.sh - an ActiveMQ broker's limits and totals
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
# Reports the broker's memory, store, temp and scheduler store, each in use
# against its limit (past 100 percent, producer flow control holds senders
# back), its store's size, its connections, producers and consumers now, its
# messages, destinations and totals, and message sizes. Read-only: it reads
# attributes over JMX, and changes nothing.
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
#   memory_pct                    of the memory limit (systemUsage
#                                 memoryUsage), in use
#   memory_limit_bytes            the memory limit
#   store_pct                     of the store limit (storeUsage), in use
#   store_limit_bytes             the store limit
#   temp_pct                      of the temp limit (tempUsage: non-persistent
#                                 messages on disk), in use
#   temp_limit_bytes              the temp limit
#   scheduler_pct                 of the scheduler store limit, in use
#   scheduler_limit_bytes         the scheduler store limit
#   store_bytes                   the persistence adapter's size (KahaDB,
#                                 JDBC...)
#   connections                   client connections now
#   connections_count             client connections since it started
#   producers                     producers now
#   consumers                     consumers now
#   messages                      messages waiting, every destination
#   enqueued_count                messages sent to it
#   dequeued_count                messages consumed
#   queues                        queues
#   topics                        topics, advisory ones too
#   temp_queues                   temporary queues
#   temp_topics                   temporary topics
#   message_mean_bytes            the mean size of a message
#   message_max_bytes             the largest message
#   memory_pct_not_shown          of memory_pct, those past the first 100,
#                                 left out
#   memory_limit_bytes_not_shown
#                                 of memory_limit_bytes, those past the first
#                                 100, left out
#   store_pct_not_shown           of store_pct, those past the first 100, left
#                                 out
#   store_limit_bytes_not_shown   of store_limit_bytes, those past the first
#                                 100, left out
#   temp_pct_not_shown            of temp_pct, those past the first 100, left
#                                 out
#   temp_limit_bytes_not_shown    of temp_limit_bytes, those past the first
#                                 100, left out
#   scheduler_pct_not_shown       of scheduler_pct, those past the first 100,
#                                 left out
#   scheduler_limit_bytes_not_shown
#                                 of scheduler_limit_bytes, those past the
#                                 first 100, left out
#   store_bytes_not_shown         of store_bytes, those past the first 100,
#                                 left out
#   connections_not_shown         of connections, those past the first 100,
#                                 left out
#   connections_count_not_shown   of connections_count, those past the first
#                                 100, left out
#   producers_not_shown           of producers, those past the first 100, left
#                                 out
#   consumers_not_shown           of consumers, those past the first 100, left
#                                 out
#   messages_not_shown            of messages, those past the first 100, left
#                                 out
#   enqueued_count_not_shown      of enqueued_count, those past the first 100,
#                                 left out
#   dequeued_count_not_shown      of dequeued_count, those past the first 100,
#                                 left out
#   queues_not_shown              of queues, those past the first 100, left
#                                 out
#   topics_not_shown              of topics, those past the first 100, left
#                                 out
#   temp_queues_not_shown         of temp_queues, those past the first 100,
#                                 left out
#   temp_topics_not_shown         of temp_topics, those past the first 100,
#                                 left out
#   message_mean_bytes_not_shown
#                                 of message_mean_bytes, those past the first
#                                 100, left out
#   message_max_bytes_not_shown   of message_max_bytes, those past the first
#                                 100, left out
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your brokers):
#   Healthy  memory_pct, store_pct and temp_pct well below 100; messages
#            rising and falling with traffic.
#   Watch    store_pct above 70: messages piling up on disk; messages growing
#            without falling back.
#   Act      memory_pct, store_pct or temp_pct at 100: producer flow control
#            blocks senders (or they fail, with sendFailIfNoSpace). Find the
#            queue that keeps them (activemq_queues).
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
    echo "activemq_broker: java not found: the activemq pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "activemq_broker: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install activemq), or build it (tools/release/client-jar.sh)" >&2
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
    echo "activemq_broker: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify activemq says what differs" >&2
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
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" activemq_broker
exit $?
