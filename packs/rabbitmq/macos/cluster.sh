#!/usr/bin/env bash
#
# cluster.sh - each RabbitMQ node's links to the others, and the cluster's
# virtual hosts, exchanges and bindings
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
# Reads each node's Prometheus pages (rabbitmq_prometheus, port 15692) with
# curl, from RABBITMQ_TARGETS (<name>=<address> separated by ;): its
# Erlang distribution links to the other nodes (/metrics), and the
# cluster's virtual hosts, exchanges and bindings as this node sees them
# (/metrics/detailed). A node alone has no peers.
#
# Metrics:
#   nodes                the nodes named in RABBITMQ_TARGETS
#   up                   1 when the node's page answers, else 0, tagged
#                        node=<its name>
#   peers                the nodes it is linked to
#   unreachable_peers    cluster members it cannot reach
#   peer_up              1 when the link to a peer is up, 0 while it is
#                        still being set up, tagged node=<its name> and
#                        peer=<the peer's node name>
#   peer_sent_bytes      bytes sent to that peer (a running total)
#   peer_received_bytes  bytes received from it (a running total)
#   peer_queue_bytes     bytes waiting to go to it
#   vhosts               the virtual hosts
#   vhosts_down          of those, not running on this node
#   vhost_up             1 when a virtual host runs on this node, else 0,
#                        tagged node=<its name> and vhost=<its name>
#   exchanges            the exchanges, every virtual host
#   bindings             the bindings from them
#   peers_not_shown      past 100 peers, how many were left out
#   vhosts_not_shown     past 100 virtual hosts, how many were left out
#
# Example output:
#   metric nodes 1
#   metric up 1 node=rabbit1
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  peers one fewer than the cluster's nodes, every peer_up 1;
#            unreachable_peers 0; vhosts_down 0; peer_queue_bytes near 0.
#   Watch    peer_queue_bytes above 0 run after run: the link to that
#            peer is slow or saturated; exchanges or bindings climbing
#            without end: an application declaring them per message.
#   Act      unreachable_peers above 0, or a peer missing: a node is down
#            or cut off, and quorum queues there may have lost their
#            majority; vhosts_down above 0: a virtual host failed to
#            start here, and its clients are refused.
#
# Requires: bash, curl, and the rabbitmq_prometheus plugin (on by default)
# Exit code: 0 on success, nodes up or down; 1 if curl is missing, a
#   setting is wrong, or a page answers but is not RabbitMQ's

set -u

command -v curl > /dev/null 2>&1 || { echo 'cluster: curl not found: the rabbitmq pack reads its pages with curl' >&2; exit 1; }
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
        echo "cluster: RABBITMQ_TARGETS: '$entry' is not <name>=<address>, as in rabbit1=http://127.0.0.1:15692" >&2
        exit 1
    fi
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9@._:-' '_')
    url=${url%/}
    page=$(get "$url/metrics")
    case $? in
        0) ;;
        2) echo "metric up 0 node=$name"; continue ;;
        *) echo "metric up 0 node=$name"; echo "cluster: $name: $url/metrics did not give a page" >&2; rc=1; continue ;;
    esac
    if ! printf '%s\n' "$page" | grep -q '^rabbitmq_build_info'; then
        echo "metric up 0 node=$name"
        echo "cluster: $name: $url/metrics answers, but is not RabbitMQ's Prometheus page" >&2
        rc=1
        continue
    fi
    detailed=$(get "$url/metrics/detailed?family=vhost_status&family=exchange_names&family=exchange_bindings") || detailed=''
    echo "metric up 1 node=$name"
    printf '%s\n%s\n' "$page" "$detailed" | awk -v tag="node=$name" '
        function label(line, key,    s) {
            if (!match(line, key "=\"[^\"]*\"")) return ""
            return substr(line, RSTART + length(key) + 2, RLENGTH - length(key) - 3)
        }
        function safe(s) { gsub(/[^A-Za-z0-9@._:\/+-]/, "_", s); return s == "" ? "none" : substr(s, 1, 120) }
        /^#/ { next }
        /^erlang_vm_dist_/ {
            base = $1; sub(/[{].*/, "", base); p = label($1, "peer")
            if (p == "") next
            peer[p] = 1
            if (base == "erlang_vm_dist_node_state") state[p] = $2
            else if (base == "erlang_vm_dist_send_bytes") sent[p] = $2
            else if (base == "erlang_vm_dist_recv_bytes") recv[p] = $2
            else if (base == "erlang_vm_dist_node_queue_size_bytes" || base == "erlang_vm_dist_port_queue_size_bytes") queue[p] += $2
        }
        /^rabbitmq_unreachable_cluster_peers_count/ { unreach = $2; has_unreach = 1 }
        /^rabbitmq_cluster_vhost_status[{]/ { vh[label($1, "vhost")] = $2 }
        /^rabbitmq_cluster_exchange_name[{]/ { ex++ }
        /^rabbitmq_cluster_exchange_bindings[{]/ { bi += $2; has_bi = 1 }
        END {
            k = 0; for (p in peer) k++
            printf "metric peers %d %s\n", k, tag
            if (has_unreach) printf "metric unreachable_peers %.0f %s\n", unreach, tag
            i = 0
            for (p in peer) {
                if (++i > 100) break
                t = sprintf("%s peer=%s", tag, safe(p))
                printf "metric peer_up %d %s\n", (state[p] == 3 ? 1 : 0), t
                if (p in sent) printf "metric peer_sent_bytes %.0f %s\n", sent[p], t
                if (p in recv) printf "metric peer_received_bytes %.0f %s\n", recv[p], t
                printf "metric peer_queue_bytes %.0f %s\n", queue[p], t
            }
            printf "metric peers_not_shown %d %s\n", (k > 100 ? k - 100 : 0), tag
            nv = 0; down = 0
            for (v in vh) { nv++; if (vh[v] != 1) down++ }
            if (nv > 0) {
                printf "metric vhosts %d %s\n", nv, tag
                printf "metric vhosts_down %d %s\n", down, tag
                i = 0
                for (v in vh) { if (++i > 100) break; printf "metric vhost_up %d %s vhost=%s\n", (vh[v] == 1 ? 1 : 0), tag, safe(v) }
                printf "metric vhosts_not_shown %d %s\n", (nv > 100 ? nv - 100 : 0), tag
            }
            if (ex > 0) printf "metric exchanges %d %s\n", ex, tag
            if (has_bi) printf "metric bindings %.0f %s\n", bi, tag
        }'
done << EOF
$(printf '%s' "$targets" | tr ';' '\n')
EOF
exit $rc
