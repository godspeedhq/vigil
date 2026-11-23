#!/usr/bin/env bash
#
# status.sh - each RabbitMQ node: up, its limits and alarms, its clients
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
# Reads each node's Prometheus page (the rabbitmq_prometheus plugin, on by
# default, port 15692), with curl. The nodes are in RABBITMQ_TARGETS,
# <name>=<address> separated by ;, the address as http://host:15692 (or
# https://, checked against RABBITMQ_CACERT when it is set), set by the job.
# Read-only: a page any client may read, no login, no cookie.
#
# Metrics:
#   nodes                    the nodes named in RABBITMQ_TARGETS
#   up                       1 when the node's page answers, else 0, tagged
#                            node=<its name>
#   version                  always 1, tagged node=<the same>,
#                            rabbitmq=<its version>, erlang=<Erlang/OTP's>,
#                            rabbitmq_node=<its node name> and
#                            cluster=<its cluster's name>
#   memory_used_bytes        memory the node uses (resident)
#   memory_limit_bytes       its memory high watermark: past it, publishers
#                            are blocked
#   memory_pct               memory_used_bytes, as a percentage of the limit
#   disk_free_bytes          free disk where it keeps its data
#   disk_free_limit_bytes    its free disk limit: below it, publishers are
#                            blocked
#   alarm_memory             1 when the memory alarm is on: publishers
#                            blocked, cluster-wide
#   alarm_disk               1 when the free disk alarm is on: the same
#   alarm_fds                1 when it has run out of file descriptors
#   fds_used                 file descriptors open: connections, files
#   fds_max                  the most it may open
#   fd_pct                   fds_used, as a percentage of fds_max
#   erlang_processes         Erlang processes (a queue, a connection and a
#                            channel each take some)
#   erlang_processes_limit   the most it may have
#   erlang_process_pct       erlang_processes, as a percentage of the limit
#   run_queue                Erlang work waiting for a scheduler
#   uptime_seconds           how long the node has run
#   unreachable_peers        cluster members it cannot reach
#   connections              client connections open now
#   channels                 channels open now
#   consumers                consumers now
#   queues                   queues on this node
#   publishers               publishers now
#
# Example output:
#   metric nodes 1
#   metric up 1 node=rabbit1
#
# Reading the results (starting points: tune them to the node):
#   Healthy  up 1; every alarm 0; memory_pct below 60; disk_free_bytes far
#            above disk_free_limit_bytes; fd_pct below 70;
#            unreachable_peers 0.
#   Watch    memory_pct above 80: near the watermark; disk_free_bytes
#            under twice its limit; fd_pct above 80; connections or
#            channels climbing without falling back: a client leaking them.
#   Act      up 0; alarm_memory or alarm_disk 1: every publisher in the
#            cluster is blocked until it clears; alarm_fds 1: no new
#            connection is accepted; unreachable_peers above 0: a node is
#            down or cut off (a partition).
#
# Requires: bash, curl, and the rabbitmq_prometheus plugin (on by default)
# Exit code: 0 on success, nodes up or down; 1 if curl is missing, a
#   setting is wrong, or a page answers but is not RabbitMQ's

set -u

command -v curl > /dev/null 2>&1 || { echo 'status: curl not found: the rabbitmq pack reads its pages with curl' >&2; exit 1; }
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
        echo "status: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692" >&2
        exit 1
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9@._:-' '_')
    url=${url%/}
    page=$(get "$url/metrics")
    case $? in
        0) ;;
        2) echo "metric up 0 node=$name"; continue ;;
        *) echo "metric up 0 node=$name"; echo "status: $name: $url/metrics did not give a page" >&2; rc=1; continue ;;
    esac
    if ! printf '%s\n' "$page" | grep -q '^rabbitmq_build_info'; then
        echo "metric up 0 node=$name"
        echo "status: $name: $url/metrics answers, but is not RabbitMQ's Prometheus page" >&2
        rc=1
        continue
    fi
    echo "metric up 1 node=$name"
    printf '%s\n' "$page" | awk -v tag="node=$name" '
        # A label of a Prometheus line: its value, quotes and spaces made safe.
        function label(line, key,    s) {
            if (!match(line, key "=\"[^\"]*\"")) return ""
            s = substr(line, RSTART + length(key) + 2, RLENGTH - length(key) - 3)
            gsub(/[^A-Za-z0-9@._:\/+-]/, "_", s)
            return (s == "" ? "none" : s)
        }
        /^#/ { next }
        {
            key = $1; v = $2; base = key; sub(/[{].*/, "", base)
            sum[base] += v; seen[base] = 1
        }
        base == "rabbitmq_build_info" { rv = label(key, "rabbitmq_version"); ev = label(key, "erlang_version") }
        base == "rabbitmq_identity_info" { nn = label(key, "rabbitmq_node"); cl = label(key, "rabbitmq_cluster") }
        function out(m, b) { if (b in seen) printf "metric %s %.0f %s\n", m, sum[b], tag }
        function pct(m, a, b) { if ((a in seen) && (b in seen) && sum[b] > 0) printf "metric %s %.2f %s\n", m, 100 * sum[a] / sum[b], tag }
        END {
            printf "metric version 1 %s rabbitmq=%s erlang=%s rabbitmq_node=%s cluster=%s\n", tag, (rv == "" ? "unknown" : rv), (ev == "" ? "unknown" : ev), (nn == "" ? "unknown" : nn), (cl == "" ? "unknown" : cl)
            out("memory_used_bytes", "rabbitmq_process_resident_memory_bytes")
            out("memory_limit_bytes", "rabbitmq_resident_memory_limit_bytes")
            pct("memory_pct", "rabbitmq_process_resident_memory_bytes", "rabbitmq_resident_memory_limit_bytes")
            out("disk_free_bytes", "rabbitmq_disk_space_available_bytes")
            out("disk_free_limit_bytes", "rabbitmq_disk_space_available_limit_bytes")
            out("alarm_memory", "rabbitmq_alarms_memory_used_watermark")
            out("alarm_disk", "rabbitmq_alarms_free_disk_space_watermark")
            out("alarm_fds", "rabbitmq_alarms_file_descriptor_limit")
            out("fds_used", "rabbitmq_process_open_fds")
            out("fds_max", "rabbitmq_process_max_fds")
            pct("fd_pct", "rabbitmq_process_open_fds", "rabbitmq_process_max_fds")
            out("erlang_processes", "rabbitmq_erlang_processes_used")
            out("erlang_processes_limit", "rabbitmq_erlang_processes_limit")
            pct("erlang_process_pct", "rabbitmq_erlang_processes_used", "rabbitmq_erlang_processes_limit")
            out("run_queue", "rabbitmq_erlang_scheduler_run_queue")
            out("uptime_seconds", "rabbitmq_erlang_uptime_seconds")
            out("unreachable_peers", "rabbitmq_unreachable_cluster_peers_count")
            out("connections", "rabbitmq_connections")
            out("channels", "rabbitmq_channels")
            out("consumers", "rabbitmq_consumers")
            out("queues", "rabbitmq_queues")
            out("publishers", "rabbitmq_global_publishers")
        }' || rc=1
done << EOF
$(printf '%s' "$targets" | tr ';' '\n')
EOF
exit $rc
