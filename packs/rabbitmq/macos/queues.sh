#!/usr/bin/env bash
#
# queues.sh - each RabbitMQ queue, the deepest first: messages waiting,
# unacknowledged, consumers, how busy they keep them, the oldest message
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
# Reads each node's detailed Prometheus page (rabbitmq_prometheus,
# /metrics/detailed, port 15692) with curl, from RABBITMQ_TARGETS
# (<name>=<address> separated by ;): the queues that node holds. A quorum
# queue is reported by the node that leads it, not its followers, so name
# every node of a cluster and each queue is counted once. Past 100 queues
# on a node, the deepest 100, and the rest counted.
#
# Metrics:
#   nodes                     the nodes named in RABBITMQ_TARGETS
#   up                        1 when the node's page answers, else 0,
#                             tagged node=<its name>
#   queues                    the queues this node leads
#   messages_total            messages in them all
#   without_consumers         queues holding messages with no consumer
#   messages                  messages in one queue, ready and
#                             unacknowledged, tagged node=<its name>,
#                             vhost=<its vhost>, queue=<its name> and
#                             type=<classic, quorum or stream>
#   ready                     of those, waiting for a consumer
#   unacked                   of those, delivered and not yet acknowledged
#   consumers                 its consumers
#   utilisation_pct           how much of the time its consumers can take
#                             a message at once (100: they keep up; low:
#                             they are slow, or their prefetch too small).
#                             Classic queues; a quorum queue says 100
#                             while it has a consumer, slow or not: read
#                             its ready rising instead
#   bytes                     the size of its messages
#   memory_bytes              the memory its process holds
#   oldest_seconds            how old its oldest message is (when
#                             publishers set the timestamp property)
#   published_count           messages published to it (a running total)
#   queues_not_shown          past the deepest 100, how many were left out
#
# Example output:
#   metric nodes 1
#   metric up 1 node=rabbit1
#
# Reading the results (starting points: tune them to the queue):
#   Healthy  ready near 0, or steady, for queues with consumers;
#            utilisation_pct near 100; without_consumers 0.
#   Watch    ready growing run after run: consumers fall behind;
#            utilisation_pct low with ready above 0: consumers are slow,
#            or their prefetch is too small; unacked near consumers times
#            their prefetch: every consumer is busy.
#   Act      without_consumers above 0 for a queue that should have them:
#            its consumers are gone, and messages pile up; oldest_seconds
#            past what your consumers promise; messages_total climbing
#            with the node's memory_pct (rabbitmq_status): the memory
#            alarm is next, and it blocks every publisher.
#
# Requires: bash, curl, and the rabbitmq_prometheus plugin (on by default)
# Exit code: 0 on success, nodes up or down; 1 if curl is missing, a
#   setting is wrong, or a page answers but is not RabbitMQ's

set -u

command -v curl > /dev/null 2>&1 || { echo 'queues: curl not found: the rabbitmq pack reads its pages with curl' >&2; exit 1; }
targets=${RABBITMQ_TARGETS-}
n=$(printf '%s' "$targets" | tr ';' '\n' | grep -c '[^[:space:]]')
echo "metric nodes $n"
rc=0

# get <url>: the page on stdout; 2 when nothing answers (a reading), 1 when
# it answers wrong (a setting to fix).
get() {
    local out code
    if [ -n "${RABBITMQ_CACERT-}" ]; then
        out=$(curl -sS -m 30 -f --cacert "$RABBITMQ_CACERT" "$1" 2>&1)
    else
        out=$(curl -sS -m 30 -f "$1" 2>&1)
    fi
    code=$?
    case $code in
        0) printf '%s\n' "$out" ;;
        6 | 7 | 28 | 52 | 56) return 2 ;;
        *) printf '%s\n' "$out" >&2; return 1 ;;
    esac
}

families='family=queue_coarse_metrics&family=queue_consumer_count&family=queue_metrics&family=queue_exchange_metrics'
while IFS= read -r entry; do
    entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$entry" ] || continue
    name=${entry%%=*} url=${entry#*=}
    if [ "$name" = "$entry" ] || [ -z "$name" ] || [ -z "$url" ]; then
        echo "queues: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692" >&2
        exit 1
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9@._:-' '_')
    url=${url%/}
    page=$(get "$url/metrics/detailed?$families")
    case $? in
        0) ;;
        2) echo "metric up 0 node=$name"; continue ;;
        *) echo "metric up 0 node=$name"; echo "queues: $name: $url/metrics/detailed did not give a page" >&2; rc=1; continue ;;
    esac
    if ! printf '%s\n' "$page" | grep -q '^rabbitmq_build_info'; then
        echo "metric up 0 node=$name"
        echo "queues: $name: $url/metrics/detailed answers, but is not RabbitMQ's Prometheus page" >&2
        rc=1
        continue
    fi
    echo "metric up 1 node=$name"
    printf '%s\n' "$page" | awk -v tag="node=$name" -v now="$(date +%s)" '
        function label(line, key,    s) {
            if (!match(line, key "=\"[^\"]*\"")) return ""
            return substr(line, RSTART + length(key) + 2, RLENGTH - length(key) - 3)
        }
        function safe(s) { gsub(/[^A-Za-z0-9@._:\/+-]/, "_", s); return (s == "" ? "none" : substr(s, 1, 120)) }
        /^rabbitmq_detailed_queue_/ {
            base = $1; sub(/[{].*/, "", base); sub(/^rabbitmq_detailed_queue_/, "", base)
            q = label($1, "vhost") SUBSEP label($1, "queue")
            if (base == "info") {
                t = label($1, "queue_type"); sub(/^rabbit_/, "", t); sub(/_queue$/, "", t)
                type[q] = t; member[q] = label($1, "membership")
                next
            }
            if (base == "exchange_messages_published_total") { v[q, base] += $2 } else { v[q, base] = $2 }
            has[q] = 1
        }
        END {
            k = 0
            for (q in has) {
                if (member[q] == "follower") continue
                k++; qs[k] = q; depth[k] = v[q, "messages"] + 0
            }
            # The deepest first (a simple sort: a node holds hundreds, not millions).
            for (i = 2; i <= k; i++) {
                x = qs[i]; d = depth[i]
                for (j = i - 1; j >= 1 && depth[j] < d; j--) { qs[j + 1] = qs[j]; depth[j + 1] = depth[j] }
                qs[j + 1] = x; depth[j + 1] = d
            }
            total = 0; idle = 0
            for (i = 1; i <= k; i++) {
                q = qs[i]; total += v[q, "messages"]
                if (v[q, "messages"] > 0 && v[q, "consumers"] == 0) idle++
            }
            printf "metric queues %d %s\n", k, tag
            printf "metric messages_total %.0f %s\n", total, tag
            printf "metric without_consumers %d %s\n", idle, tag
            for (i = 1; i <= k && i <= 100; i++) {
                q = qs[i]; split(q, p, SUBSEP)
                t = sprintf("%s vhost=%s queue=%s type=%s", tag, safe(p[1]), safe(p[2]), (type[q] == "" ? "unknown" : type[q]))
                printf "metric messages %.0f %s\n", v[q, "messages"], t
                printf "metric ready %.0f %s\n", v[q, "messages_ready"], t
                printf "metric unacked %.0f %s\n", v[q, "messages_unacked"], t
                printf "metric consumers %.0f %s\n", v[q, "consumers"], t
                if ((q, "consumer_utilisation") in v) printf "metric utilisation_pct %.2f %s\n", 100 * v[q, "consumer_utilisation"], t
                if ((q, "messages_bytes") in v) printf "metric bytes %.0f %s\n", v[q, "messages_bytes"], t
                if ((q, "process_memory_bytes") in v) printf "metric memory_bytes %.0f %s\n", v[q, "process_memory_bytes"], t
                ts = v[q, "head_message_timestamp"] + 0
                # Seconds, as AMQP has it; a client that sets milliseconds is read as such.
                if (ts > 100000000000) ts = ts / 1000
                if (ts > 0 && now >= ts) printf "metric oldest_seconds %.0f %s\n", now - ts, t
                if ((q, "exchange_messages_published_total") in v) printf "metric published_count %.0f %s\n", v[q, "exchange_messages_published_total"], t
            }
            printf "metric queues_not_shown %d %s\n", (k > 100 ? k - 100 : 0), tag
        }' || rc=1
done << EOF
$(printf '%s' "$targets" | tr ';' '\n')
EOF
exit $rc
