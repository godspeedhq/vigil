#!/usr/bin/env bash
#
# quorum.sh - each quorum queue's Raft log, on every node that holds it:
# leader changes, commit latency, how far behind each copy is
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
# (<name>=<address> separated by ;): the Raft figures of each quorum queue
# it holds a copy of, leader or follower, and of RabbitMQ's own metadata
# store (Khepri, tagged system=rabbit_khepri), whose majority the cluster
# needs to change anything. Past 100 on a node, those furthest behind,
# and the rest counted.
#
# Metrics:
#   nodes              the nodes named in RABBITMQ_TARGETS
#   up                 1 when the node's page answers, else 0, tagged
#                      node=<its name>
#   members            the quorum queues this node holds a copy of, and
#                      its metadata store
#   leaders            of those, the ones it leads
#   term               the queue's Raft term: it rises at each election
#                      of a new leader, tagged node=<its name>,
#                      vhost=<its vhost>, queue=<its name> and
#                      role=<leader or follower> (the metadata store:
#                      system=rabbit_khepri)
#   commit_latency_seconds  how long the last command took to commit
#   commit_lag         log entries written here and not yet committed
#   apply_lag          entries committed and not yet applied here
#   segments           the log's segment files on disk
#   members_not_shown  past 100, how many were left out
#
# Example output:
#   metric nodes 1
#   metric up 1 node=rabbit1
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  term steady; commit_latency_seconds in milliseconds;
#            commit_lag and apply_lag near 0; leaders spread over the
#            nodes.
#   Watch    term rising: leaders being elected again and again (a node
#            restarting, or the network flapping); commit_latency_seconds
#            climbing: the disks or the network are slow; every leader on
#            one node: it takes all the work.
#   Act      commit_lag or apply_lag growing on one copy: it is falling
#            behind and may need a snapshot; members lower than the
#            queues you expect here: a copy is gone (a node was removed).
#
# Requires: bash, curl, and the rabbitmq_prometheus plugin (on by default)
# Exit code: 0 on success, nodes up or down; 1 if curl is missing, a
#   setting is wrong, or a page answers but is not RabbitMQ's

set -u

command -v curl > /dev/null 2>&1 || { echo 'quorum: curl not found: the rabbitmq pack reads its pages with curl' >&2; exit 1; }
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

while IFS= read -r entry; do
    entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$entry" ] || continue
    name=${entry%%=*} url=${entry#*=}
    if [ "$name" = "$entry" ] || [ -z "$name" ] || [ -z "$url" ]; then
        echo "quorum: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692" >&2
        exit 1
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9@._:-' '_')
    url=${url%/}
    page=$(get "$url/metrics/detailed?family=ra_metrics&family=queue_metrics")
    case $? in
        0) ;;
        2) echo "metric up 0 node=$name"; continue ;;
        *) echo "metric up 0 node=$name"; echo "quorum: $name: $url/metrics/detailed did not give a page" >&2; rc=1; continue ;;
    esac
    if ! printf '%s\n' "$page" | grep -q '^rabbitmq_build_info'; then
        echo "metric up 0 node=$name"
        echo "quorum: $name: $url/metrics/detailed answers, but is not RabbitMQ's Prometheus page" >&2
        rc=1
        continue
    fi
    echo "metric up 1 node=$name"
    printf '%s\n' "$page" | awk -v tag="node=$name" '
        function label(line, key,    s) {
            if (!match(line, key "=\"[^\"]*\"")) return ""
            return substr(line, RSTART + length(key) + 2, RLENGTH - length(key) - 3)
        }
        function safe(s) { gsub(/[^A-Za-z0-9@._:\/+-]/, "_", s); return s == "" ? "none" : substr(s, 1, 120) }
        /^rabbitmq_detailed_queue_info[{]/ {
            q = label($1, "vhost") SUBSEP label($1, "queue")
            if (label($1, "queue_type") == "rabbit_quorum_queue") role[q] = label($1, "membership")
            next
        }
        /^rabbitmq_detailed_raft_/ {
            base = $1; sub(/[{].*/, "", base); sub(/^rabbitmq_detailed_raft_/, "", base)
            # A queue, by its vhost and name; else one of RabbitMQ'"'"'s own
            # (its metadata store, Khepri), by its module.
            if (label($1, "queue") != "") q = label($1, "vhost") SUBSEP label($1, "queue")
            else q = "system" SUBSEP label($1, "module")
            v[q, base] = $2; has[q] = 1
        }
        END {
            k = 0; lead = 0
            for (q in has) {
                # Of RabbitMQ own Raft systems, the members (Khepri), not its log writers.
                if (index(q, "system" SUBSEP) == 1 && !((q, "term") in v)) continue
                k++; qs[k] = q
                lag[k] = (v[q, "last_written_index"] - v[q, "commit_index"]) + (v[q, "commit_index"] - v[q, "last_applied"])
                if (role[q] == "leader") lead++
            }
            for (i = 2; i <= k; i++) {
                x = qs[i]; d = lag[i]
                for (j = i - 1; j >= 1 && lag[j] < d; j--) { qs[j + 1] = qs[j]; lag[j + 1] = lag[j] }
                qs[j + 1] = x; lag[j + 1] = d
            }
            printf "metric members %d %s\n", k, tag
            printf "metric leaders %d %s\n", lead, tag
            for (i = 1; i <= k && i <= 100; i++) {
                q = qs[i]; split(q, p, SUBSEP)
                r = role[q] == "" ? "member" : role[q]
                if (p[1] == "system") t = sprintf("%s system=%s", tag, safe(p[2]))
                else t = sprintf("%s vhost=%s queue=%s role=%s", tag, safe(p[1]), safe(p[2]), r)
                printf "metric term %.0f %s\n", v[q, "term"], t
                if ((q, "commit_latency_seconds") in v) printf "metric commit_latency_seconds %.6f %s\n", v[q, "commit_latency_seconds"], t
                cl = v[q, "last_written_index"] - v[q, "commit_index"]; if (cl < 0) cl = 0
                al = v[q, "commit_index"] - v[q, "last_applied"]; if (al < 0) al = 0
                printf "metric commit_lag %.0f %s\n", cl, t
                printf "metric apply_lag %.0f %s\n", al, t
                if ((q, "num_segments") in v) printf "metric segments %.0f %s\n", v[q, "num_segments"], t
            }
            printf "metric members_not_shown %d %s\n", (k > 100 ? k - 100 : 0), tag
        }'
done << EOF
$(printf '%s' "$targets" | tr ';' '\n')
EOF
exit $rc
