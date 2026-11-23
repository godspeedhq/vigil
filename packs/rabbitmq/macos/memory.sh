#!/usr/bin/env bash
#
# memory.sh - what each RabbitMQ node's memory is used for: connections,
# channels, queues of each type, the metadata store, binaries, the rest
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
# Reads each node's memory breakdown (rabbitmq_prometheus,
# /metrics/memory-breakdown, port 15692) with curl, from RABBITMQ_TARGETS
# (<name>=<address> separated by ;): RabbitMQ's own account of its memory,
# by what holds it. rabbitmq_status memory_pct says how near the watermark
# it is; this says why.
#
# Metrics:
#   nodes                     the nodes named in RABBITMQ_TARGETS
#   up                        1 when the node's page answers, else 0,
#                             tagged node=<its name>
#   connection_readers_bytes  connections' readers (one per connection)
#   connection_writers_bytes  connections' writers
#   channels_bytes            channels
#   connection_other_bytes    other connection processes
#   classic_queues_bytes      classic queues' processes
#   quorum_queues_bytes       quorum queues' processes
#   quorum_queues_dlx_bytes   quorum queues' dead lettering
#   quorum_ets_bytes          quorum queues' tables
#   streams_bytes             streams' processes, readers and coordinator
#   binaries_bytes            binaries: message bodies, mostly
#   message_index_bytes       the message store's index
#   metadata_store_bytes      the metadata store (Khepri, or Mnesia)
#   metrics_bytes             RabbitMQ's own metrics
#   management_bytes          the management plugin's statistics
#   plugins_bytes             plugins
#   code_bytes                loaded code
#   atoms_bytes               the atom table
#   other_processes_bytes     other Erlang processes
#   other_tables_bytes        other ETS tables
#   other_system_bytes        other system memory
#   allocated_unused_bytes    allocated by the runtime, not in use
#   reserved_unallocated_bytes  reserved by the runtime, not allocated
#
# Example output:
#   metric nodes 1
#   metric up 1 node=rabbit1
#
# Reading the results (starting points: tune them to the node):
#   Healthy  binaries_bytes and the queues' bytes rising and falling with
#            the messages held; the rest steady.
#   Watch    binaries_bytes climbing while queues are short: a consumer
#            holding messages unacknowledged; connection_readers_bytes
#            and channels_bytes climbing: clients leaking connections or
#            channels; management_bytes large: the management plugin's
#            statistics, on a busy node.
#   Act      one part climbing toward rabbitmq_status memory_limit_bytes:
#            that is what will set off the memory alarm, which blocks
#            every publisher.
#
# Requires: bash, curl, and the rabbitmq_prometheus plugin (on by default)
# Exit code: 0 on success, nodes up or down; 1 if curl is missing, a
#   setting is wrong, or a page answers but is not RabbitMQ's

set -u

command -v curl > /dev/null 2>&1 || { echo 'memory: curl not found: the rabbitmq pack reads its pages with curl' >&2; exit 1; }
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
        echo "memory: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692" >&2
        exit 1
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9@._:-' '_')
    url=${url%/}
    page=$(get "$url/metrics/memory-breakdown")
    case $? in
        0) ;;
        2) echo "metric up 0 node=$name"; continue ;;
        *) echo "metric up 0 node=$name"; echo "memory: $name: $url/metrics/memory-breakdown did not give a page" >&2; rc=1; continue ;;
    esac
    if ! printf '%s\n' "$page" | grep -q '^rabbitmq_build_info'; then
        echo "metric up 0 node=$name"
        echo "memory: $name: $url/metrics/memory-breakdown answers, but is not RabbitMQ's Prometheus page" >&2
        rc=1
        continue
    fi
    echo "metric up 1 node=$name"
    printf '%s\n' "$page" | awk -v tag="node=$name" '
        /^#/ { next }
        { base = $1; sub(/[{].*/, "", base); sum[base] += $2; seen[base] = 1 }
        function out(m, b) { if (b in seen) printf "metric %s %.0f %s\n", m, sum[b], tag }
        function sec(m, b) { if (b in seen) printf "metric %s %.3f %s\n", m, sum[b], tag }
        END {
            out("connection_readers_bytes", "rabbitmq_memory_client_connection_reader_bytes")
            out("connection_writers_bytes", "rabbitmq_memory_client_connection_writer_bytes")
            out("channels_bytes", "rabbitmq_memory_client_connection_channel_bytes")
            out("connection_other_bytes", "rabbitmq_memory_client_connection_other_bytes")
            out("classic_queues_bytes", "rabbitmq_memory_classic_queue_erlang_process_bytes")
            out("quorum_queues_bytes", "rabbitmq_memory_quorum_queue_erlang_process_bytes")
            out("quorum_queues_dlx_bytes", "rabbitmq_memory_quorum_queue_dlx_erlang_process_bytes")
            out("quorum_ets_bytes", "rabbitmq_memory_quorum_queue_ets_table_bytes")
            s = 0; f = 0; split("rabbitmq_memory_stream_erlang_process_bytes rabbitmq_memory_stream_replica_reader_erlang_process_bytes rabbitmq_memory_stream_coordinator_erlang_process_bytes", ss, " ")
            for (i = 1; i <= 3; i++) if (ss[i] in seen) { s += sum[ss[i]]; f = 1 }
            if (f) printf "metric streams_bytes %.0f %s\n", s, tag
            out("binaries_bytes", "rabbitmq_memory_binary_heap_bytes")
            out("message_index_bytes", "rabbitmq_memory_message_index_bytes")
            s = 0; f = 0; split("rabbitmq_memory_modern_metadata_store_bytes rabbitmq_memory_modern_metadata_store_ets_table_bytes rabbitmq_memory_classic_metadata_store_bytes", ms, " ")
            for (i = 1; i <= 3; i++) if (ms[i] in seen) { s += sum[ms[i]]; f = 1 }
            if (f) printf "metric metadata_store_bytes %.0f %s\n", s, tag
            out("metrics_bytes", "rabbitmq_memory_metrics_bytes")
            out("management_bytes", "rabbitmq_memory_management_stats_db_bytes")
            out("plugins_bytes", "rabbitmq_memory_plugin_bytes")
            out("code_bytes", "rabbitmq_memory_code_module_bytes")
            out("atoms_bytes", "rabbitmq_memory_atom_table_bytes")
            out("other_processes_bytes", "rabbitmq_memory_other_erlang_process_bytes")
            out("other_tables_bytes", "rabbitmq_memory_other_ets_table_bytes")
            out("other_system_bytes", "rabbitmq_memory_other_system_bytes")
            out("allocated_unused_bytes", "rabbitmq_memory_runtime_allocated_unused_bytes")
            out("reserved_unallocated_bytes", "rabbitmq_memory_runtime_reserved_unallocated_bytes")
        }'
done << EOF
$(printf '%s' "$targets" | tr ';' '\n')
EOF
exit $rc
