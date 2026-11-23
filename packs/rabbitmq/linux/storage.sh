#!/usr/bin/env bash
#
# storage.sh - each RabbitMQ node's disk work: reads, writes, syncs and
# the time they took; its message store, queue index and metadata store
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
# curl, from RABBITMQ_TARGETS (<name>=<address> separated by ;): its file
# I/O since it started, as running totals: graph them as rates, and the
# time per operation as the time's rate over the operations' rate.
# RabbitMQ 3.x counts them; 4.0 and later no longer do (their file handle
# cache is gone) and give 0 for each: there, this job says counted 0 and
# reports none of them, rather than zeros that look like an idle disk.
#
# Metrics:
#   nodes                     the nodes named in RABBITMQ_TARGETS
#   up                        1 when the node's page answers, else 0,
#                             tagged node=<its name>
#   counted                   1 when the node counts its file I/O
#                             (RabbitMQ 3.x), 0 when it does not (4.0 on)
#   read_ops_count            file reads
#   read_bytes                bytes read
#   read_seconds              time spent reading
#   write_ops_count           file writes
#   write_bytes               bytes written
#   write_seconds             time spent writing
#   sync_ops_count            fsyncs: each makes a write durable
#   sync_seconds              time spent in them
#   seek_ops_count            seeks
#   seek_seconds              time spent seeking
#   reopen_ops_count          files reopened (too few file handles kept)
#   msg_store_reads_count     reads from the message store (classic
#                             queues' message bodies)
#   msg_store_writes_count    writes to it
#   queue_index_reads_count   reads of classic queues' indexes
#   queue_index_writes_count  writes to them
#   metadata_disk_tx_count    metadata store transactions on disk
#   metadata_ram_tx_count     metadata store transactions in memory
#
# Example output:
#   metric nodes 1
#   metric up 1 node=rabbit1
#
# Reading the results (starting points: tune them to the node):
#   Healthy  sync_seconds and write_seconds rising slowly against their
#            operations: milliseconds each.
#   Watch    time per sync (sync_seconds over sync_ops_count, as rates)
#            above 10 ms: the disk is slow for quorum queues and
#            confirms; reopen_ops_count rising: too few file handles.
#   Act      time per sync above 100 ms, or writes stalling while
#            messages arrive: publishers wait for confirms, and memory
#            grows (rabbitmq_status memory_pct).
#
# Requires: bash, curl, and the rabbitmq_prometheus plugin (on by default)
# Exit code: 0 on success, nodes up or down; 1 if curl is missing, a
#   setting is wrong, or a page answers but is not RabbitMQ's

set -u

command -v curl > /dev/null 2>&1 || { echo 'storage: curl not found: the rabbitmq pack reads its pages with curl' >&2; exit 1; }
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
        echo "storage: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692" >&2
        exit 1
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9@._:-' '_')
    url=${url%/}
    page=$(get "$url/metrics")
    case $? in
        0) ;;
        2) echo "metric up 0 node=$name"; continue ;;
        *) echo "metric up 0 node=$name"; echo "storage: $name: $url/metrics did not give a page" >&2; rc=1; continue ;;
    esac
    if ! printf '%s\n' "$page" | grep -q '^rabbitmq_build_info'; then
        echo "metric up 0 node=$name"
        echo "storage: $name: $url/metrics answers, but is not RabbitMQ's Prometheus page" >&2
        rc=1
        continue
    fi
    echo "metric up 1 node=$name"
    printf '%s\n' "$page" | awk -v tag="node=$name" '
        /^rabbitmq_build_info[{]/ { if (match($1, /rabbitmq_version="[0-9]+/)) major = substr($1, RSTART + 18, RLENGTH - 18) + 0 }
        /^#/ { next }
        { base = $1; sub(/[{].*/, "", base); sum[base] += $2; seen[base] = 1 }
        function out(m, b) { if (b in seen) printf "metric %s %.0f %s\n", m, sum[b], tag }
        function sec(m, b) { if (b in seen) printf "metric %s %.3f %s\n", m, sum[b], tag }
        END {
            # 4.0 on: none of these is counted (each is 0).
            if (major >= 4) { printf "metric counted 0 %s\n", tag; exit }
            printf "metric counted 1 %s\n", tag
            out("read_ops_count", "rabbitmq_io_read_ops_total")
            out("read_bytes", "rabbitmq_io_read_bytes_total")
            sec("read_seconds", "rabbitmq_io_read_time_seconds_total")
            out("write_ops_count", "rabbitmq_io_write_ops_total")
            out("write_bytes", "rabbitmq_io_write_bytes_total")
            sec("write_seconds", "rabbitmq_io_write_time_seconds_total")
            out("sync_ops_count", "rabbitmq_io_sync_ops_total")
            sec("sync_seconds", "rabbitmq_io_sync_time_seconds_total")
            out("seek_ops_count", "rabbitmq_io_seek_ops_total")
            sec("seek_seconds", "rabbitmq_io_seek_time_seconds_total")
            out("reopen_ops_count", "rabbitmq_io_reopen_ops_total")
            out("msg_store_reads_count", "rabbitmq_msg_store_read_total")
            out("msg_store_writes_count", "rabbitmq_msg_store_write_total")
            out("queue_index_reads_count", "rabbitmq_queue_index_read_ops_total")
            out("queue_index_writes_count", "rabbitmq_queue_index_write_ops_total")
            out("metadata_disk_tx_count", "rabbitmq_schema_db_disk_tx_total")
            out("metadata_ram_tx_count", "rabbitmq_schema_db_ram_tx_total")
        }'
done << EOF
$(printf '%s' "$targets" | tr ';' '\n')
EOF
exit $rc
