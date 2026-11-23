#!/usr/bin/env bash
#
# queues.sh - an ActiveMQ broker's queues
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
# Reports each queue: messages waiting, sent, consumed, dispatched, expired
# and in flight, its consumers and producers, its memory and cursor in use,
# sends held back by flow control, how long messages wait, message sizes and
# whether it is paused. The deepest 100 queues, the rest counted. Read-only:
# it reads attributes over JMX, and changes nothing.
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
#   size                          messages waiting, tagged
#                                 destinationName=<the queue>; the deepest
#                                 first
#   enqueued_count                messages sent to it, tagged the same
#   dequeued_count                messages consumed and acknowledged, tagged
#                                 the same
#   dispatched_count              messages handed to consumers, tagged the
#                                 same
#   expired_count                 messages that expired, tagged the same
#   in_flight                     messages handed to consumers and not yet
#                                 acknowledged, tagged the same
#   consumers                     consumers, tagged the same
#   producers                     producers, tagged the same
#   memory_pct                    of its memory limit, in use, tagged the same
#   memory_bytes                  memory its messages hold, tagged the same
#   cursor_pct                    of its cursor's memory, in use, tagged the
#                                 same
#   blocked_sends_count           sends held back by flow control, tagged the
#                                 same
#   blocked_seconds               time sends were held back, added up, tagged
#                                 the same
#   enqueue_mean_seconds          how long a message waits in it, on average,
#                                 tagged the same
#   enqueue_max_seconds           the longest a message waited, tagged the
#                                 same
#   message_mean_bytes            the mean size of a message, tagged the same
#   paused                        1 when it is paused (no dispatch), tagged
#                                 the same
#   forwarded_count               messages forwarded to another broker, tagged
#                                 the same
#   store_bytes                   the size of its messages in the store (6.x),
#                                 tagged the same
#   temp_pct                      of its temp limit (non-persistent messages
#                                 on disk), in use, tagged the same
#   cursor_full                   1 when its cursor is full: no more messages
#                                 paged in to dispatch, tagged the same
#   blocked_mean_seconds          how long a held-back send waited, on
#                                 average, tagged the same
#   network_enqueued_count        messages that came from another broker,
#                                 tagged the same
#   network_dequeued_count        messages that went on to another broker,
#                                 tagged the same
#   message_max_bytes             the largest message, tagged the same
#   duplicates_count              duplicates found in the store, tagged the
#                                 same
#   uncommitted_exceeded_count    transactions refused for holding too many
#                                 messages, tagged the same
#   size_not_shown                of size, those past the first 100, left out
#                                 (the largest are shown)
#   enqueued_count_not_shown      of enqueued_count, those past the first 100,
#                                 left out (the largest are shown)
#   dequeued_count_not_shown      of dequeued_count, those past the first 100,
#                                 left out (the largest are shown)
#   dispatched_count_not_shown    of dispatched_count, those past the first
#                                 100, left out (the largest are shown)
#   expired_count_not_shown       of expired_count, those past the first 100,
#                                 left out (the largest are shown)
#   in_flight_not_shown           of in_flight, those past the first 100, left
#                                 out (the largest are shown)
#   consumers_not_shown           of consumers, those past the first 100, left
#                                 out (the largest are shown)
#   producers_not_shown           of producers, those past the first 100, left
#                                 out (the largest are shown)
#   memory_pct_not_shown          of memory_pct, those past the first 100,
#                                 left out (the largest are shown)
#   memory_bytes_not_shown        of memory_bytes, those past the first 100,
#                                 left out (the largest are shown)
#   cursor_pct_not_shown          of cursor_pct, those past the first 100,
#                                 left out (the largest are shown)
#   blocked_sends_count_not_shown
#                                 of blocked_sends_count, those past the first
#                                 100, left out (the largest are shown)
#   blocked_seconds_not_shown     of blocked_seconds, those past the first
#                                 100, left out (the largest are shown)
#   enqueue_mean_seconds_not_shown
#                                 of enqueue_mean_seconds, those past the
#                                 first 100, left out (the largest are shown)
#   enqueue_max_seconds_not_shown
#                                 of enqueue_max_seconds, those past the first
#                                 100, left out (the largest are shown)
#   message_mean_bytes_not_shown
#                                 of message_mean_bytes, those past the first
#                                 100, left out (the largest are shown)
#   paused_not_shown              of paused, those past the first 100, left
#                                 out (the largest are shown)
#   forwarded_count_not_shown     of forwarded_count, those past the first
#                                 100, left out (the largest are shown)
#   store_bytes_not_shown         of store_bytes, those past the first 100,
#                                 left out (the largest are shown)
#   temp_pct_not_shown            of temp_pct, those past the first 100, left
#                                 out (the largest are shown)
#   cursor_full_not_shown         of cursor_full, those past the first 100,
#                                 left out (the largest are shown)
#   blocked_mean_seconds_not_shown
#                                 of blocked_mean_seconds, those past the
#                                 first 100, left out (the largest are shown)
#   network_enqueued_count_not_shown
#                                 of network_enqueued_count, those past the
#                                 first 100, left out (the largest are shown)
#   network_dequeued_count_not_shown
#                                 of network_dequeued_count, those past the
#                                 first 100, left out (the largest are shown)
#   message_max_bytes_not_shown   of message_max_bytes, those past the first
#                                 100, left out (the largest are shown)
#   duplicates_count_not_shown    of duplicates_count, those past the first
#                                 100, left out (the largest are shown)
#   uncommitted_exceeded_count_not_shown
#                                 of uncommitted_exceeded_count, those past
#                                 the first 100, left out (the largest are
#                                 shown)
#
# Example output (the rest are in the same form):
#   metric jmx_up 1 broker=a62 jmx=localhost:19323
#   metric size 10171 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric enqueued_count 10171 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric dequeued_count 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric dispatched_count 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric expired_count 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric in_flight 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric consumers 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric producers 1 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric memory_pct 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric memory_bytes 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric cursor_pct 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric blocked_sends_count 2 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric blocked_seconds 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric enqueue_mean_seconds 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric enqueue_max_seconds 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric message_mean_bytes 11024 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric paused 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric forwarded_count 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric store_bytes 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric temp_pct 100 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric cursor_full 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric blocked_mean_seconds 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric network_enqueued_count 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric network_dequeued_count 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric message_max_bytes 11024 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric duplicates_count 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#   metric uncommitted_exceeded_count 0 broker=a62 jmx=localhost:19323 destinationName=bulk
#
# Reading the results (starting points: tune them to your brokers):
#   Healthy  size rising and falling; consumers above 0 on every queue that
#            should be read; blocked_sends_count flat.
#   Watch    size growing on one queue; enqueue_mean_seconds growing:
#            consumers are falling behind.
#   Act      size growing with consumers 0: nothing reads it;
#            blocked_sends_count rising: flow control holds producers back
#            (its memory_pct at 100).
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
    echo "activemq_queues: java not found: the activemq pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME" >&2
    exit 1
fi

# The jar is run only once it matches the digest above.
if [ ! -f "$here/_probe.jar" ]; then
    echo "activemq_queues: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install activemq), or build it (tools/release/client-jar.sh)" >&2
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
    echo "activemq_queues: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify activemq says what differs" >&2
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
    -Djava.io.tmpdir="$work" -cp "$here/_probe.jar" Probe "$here/_probe.tables" activemq_queues
exit $?
