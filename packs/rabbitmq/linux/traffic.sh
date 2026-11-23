#!/usr/bin/env bash
#
# traffic.sh - each RabbitMQ node's messages: in, routed, out, acknowledged,
# lost; and its clients coming and going
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
# Reads each node's Prometheus page (rabbitmq_prometheus, port 15692) with
# curl, from RABBITMQ_TARGETS (<name>=<address> separated by ;), and reports
# its running totals since it started: graph them as rates. Every protocol
# (AMQP 0-9-1, AMQP 1.0, MQTT, STOMP, streams) and queue type, added up.
#
# Metrics:
#   nodes                       the nodes named in RABBITMQ_TARGETS
#   up                          1 when the node's page answers, else 0,
#                               tagged node=<its name>
#   received_count              messages published to it
#   received_confirm_count      of those, by publishers asking for confirms
#   confirmed_count             publishes it confirmed
#   routed_count                messages routed to at least one queue
#   unroutable_dropped_count    messages no queue took, dropped
#   unroutable_returned_count   messages no queue took, returned to the
#                               publisher (mandatory)
#   delivered_count             messages delivered to consumers and gets
#   delivered_manual_ack_count  of those, to be acknowledged by the client
#   delivered_auto_ack_count    of those, acknowledged on delivery
#   redelivered_count           deliveries of a message delivered before
#   acknowledged_count          messages acknowledged by clients
#   get_empty_count             basic.get on an empty queue (polling)
#   dead_lettered_count         messages dead-lettered, tagged
#                               reason=<expired, maxlen, rejected or
#                               delivery_limit>
#   unacked                     messages delivered and not yet acknowledged,
#                               on every channel
#   unconfirmed                 publishes not yet confirmed, on every
#                               channel
#   message_avg_bytes           the average size of a message published
#   connections_opened_count    connections opened
#   connections_closed_count    connections closed
#   channels_opened_count       channels opened
#   channels_closed_count       channels closed
#   queues_declared_count       queue declarations
#   queues_created_count        queues created
#   queues_deleted_count        queues deleted
#   logins_count                logins tried
#   logins_failed_count         logins refused
#
# Example output:
#   metric nodes 5
#   metric up 1 node=a
#   metric received_count 15728 node=a
#   metric received_confirm_count 120 node=a
#   metric confirmed_count 120 node=a
#   metric routed_count 15688 node=a
#   metric unroutable_dropped_count 40 node=a
#   metric unroutable_returned_count 0 node=a
#   metric delivered_count 790 node=a
#   metric delivered_manual_ack_count 790 node=a
#   metric delivered_auto_ack_count 0 node=a
#   metric redelivered_count 0 node=a
#   metric acknowledged_count 780 node=a
#   metric get_empty_count 0 node=a
#   metric dead_lettered_count 40 node=a reason=expired
#   metric dead_lettered_count 30 node=a reason=maxlen
#
# Reading the results (starting points: tune them to the node; graph the
# _count totals as rates):
#   Healthy  delivered_count and acknowledged_count rising with
#            received_count; unroutable and dead_lettered flat;
#            connections opened and closed at a low, steady rate.
#   Watch    redelivered_count rising: consumers failing or rejecting;
#            get_empty_count rising fast: clients polling, not consuming;
#            unacked climbing: consumers slow to acknowledge;
#            connections_opened_count rising as fast as closed, by many a
#            second: clients connecting for every message (churn).
#   Act      unroutable_dropped_count rising: messages lost, published
#            where no queue is bound; dead_lettered_count reason=maxlen or
#            expired rising: queues full or messages too old, and
#            dropped if there is no dead letter queue; logins_failed_count
#            rising: a client with a wrong password, or someone trying.
#
# Requires: bash, curl, and the rabbitmq_prometheus plugin (on by default)
# Exit code: 0 on success, nodes up or down; 1 if curl is missing, a
#   setting is wrong, or a page answers but is not RabbitMQ's

set -u

command -v curl > /dev/null 2>&1 || { echo 'traffic: curl not found: the rabbitmq pack reads its pages with curl' >&2; exit 1; }
targets=${RABBITMQ_TARGETS-}
n=$(printf '%s' "$targets" | tr ';' '\n' | grep -c '[^[:space:]]')
echo "metric nodes $n"
rc=0

# get <url>: the page on stdout; 2 when nothing answers (a reading), 1 when
# it answers wrong (a setting to fix).
get() {
    local out code
    if [ -n "${RABBITMQ_CACERT-}" ]; then
        out=$(curl -sS -m 20 -f --cacert "$RABBITMQ_CACERT" "$1" 2>&1)
    else
        out=$(curl -sS -m 20 -f "$1" 2>&1)
    fi
    code=$?
    case $code in
        0) printf '%s\n' "$out" ;;
        6 | 7 | 28 | 52 | 56) return 2 ;;
        *) printf '%s\n' "$out" >&2; return 1 ;;
    esac
}

while IFS= read -r entry; do
    entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$entry" ] || continue
    name=${entry%%=*} url=${entry#*=}
    if [ "$name" = "$entry" ] || [ -z "$name" ] || [ -z "$url" ]; then
        echo "traffic: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692" >&2
        exit 1
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9@._:-' '_')
    url=${url%/}
    page=$(get "$url/metrics")
    case $? in
        0) ;;
        2) echo "metric up 0 node=$name"; continue ;;
        *) echo "metric up 0 node=$name"; echo "traffic: $name: $url/metrics did not give a page" >&2; rc=1; continue ;;
    esac
    if ! printf '%s\n' "$page" | grep -q '^rabbitmq_build_info'; then
        echo "metric up 0 node=$name"
        echo "traffic: $name: $url/metrics answers, but is not RabbitMQ's Prometheus page" >&2
        rc=1
        continue
    fi
    echo "metric up 1 node=$name"
    printf '%s\n' "$page" | awk -v tag="node=$name" '
        /^#/ { next }
        {
            key = $1; base = key; sub(/[{].*/, "", base)
            sum[base] += $2; seen[base] = 1
            if (base ~ /^rabbitmq_global_messages_dead_lettered_[a-z_]+_total$/ && base != "rabbitmq_global_messages_dead_lettered_confirmed_total") {
                r = base; sub(/^rabbitmq_global_messages_dead_lettered_/, "", r); sub(/_total$/, "", r)
                dl[r] += $2
            }
        }
        function out(m, b) { if (b in seen) printf "metric %s %.0f %s\n", m, sum[b], tag }
        function out2(m, a, b) { if ((a in seen) || (b in seen)) printf "metric %s %.0f %s\n", m, sum[a] + sum[b], tag }
        END {
            out("received_count", "rabbitmq_global_messages_received_total")
            out("received_confirm_count", "rabbitmq_global_messages_received_confirm_total")
            out("confirmed_count", "rabbitmq_global_messages_confirmed_total")
            out("routed_count", "rabbitmq_global_messages_routed_total")
            out("unroutable_dropped_count", "rabbitmq_global_messages_unroutable_dropped_total")
            out("unroutable_returned_count", "rabbitmq_global_messages_unroutable_returned_total")
            out("delivered_count", "rabbitmq_global_messages_delivered_total")
            out2("delivered_manual_ack_count", "rabbitmq_global_messages_delivered_consume_manual_ack_total", "rabbitmq_global_messages_delivered_get_manual_ack_total")
            out2("delivered_auto_ack_count", "rabbitmq_global_messages_delivered_consume_auto_ack_total", "rabbitmq_global_messages_delivered_get_auto_ack_total")
            out("redelivered_count", "rabbitmq_global_messages_redelivered_total")
            out("acknowledged_count", "rabbitmq_global_messages_acknowledged_total")
            out("get_empty_count", "rabbitmq_global_messages_get_empty_total")
            split("expired maxlen rejected delivery_limit", rs, " ")
            for (i = 1; i <= 4; i++) if (rs[i] in dl) printf "metric dead_lettered_count %.0f %s reason=%s\n", dl[rs[i]], tag, rs[i]
            out("unacked", "rabbitmq_channel_messages_unacked")
            out("unconfirmed", "rabbitmq_channel_messages_unconfirmed")
            if (("rabbitmq_message_size_bytes_count" in seen) && sum["rabbitmq_message_size_bytes_count"] > 0)
                printf "metric message_avg_bytes %.0f %s\n", sum["rabbitmq_message_size_bytes_sum"] / sum["rabbitmq_message_size_bytes_count"], tag
            out("connections_opened_count", "rabbitmq_connections_opened_total")
            out("connections_closed_count", "rabbitmq_connections_closed_total")
            out("channels_opened_count", "rabbitmq_channels_opened_total")
            out("channels_closed_count", "rabbitmq_channels_closed_total")
            out("queues_declared_count", "rabbitmq_queues_declared_total")
            out("queues_created_count", "rabbitmq_queues_created_total")
            out("queues_deleted_count", "rabbitmq_queues_deleted_total")
            out("logins_count", "rabbitmq_auth_attempts_total")
            out("logins_failed_count", "rabbitmq_auth_attempts_failed_total")
        }' || rc=1
done << EOF
$(printf '%s' "$targets" | tr ';' '\n')
EOF
exit $rc
