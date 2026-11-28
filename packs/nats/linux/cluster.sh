#!/usr/bin/env bash
#
# cluster.sh - a NATS server's routes to the rest of its cluster
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
# Reports whether the server is in a cluster, the routes configured, the other
# servers it has routes to, each named, the route connections (2.10 and later
# pool several to each server), the bytes waiting on them, the slowest round
# trip, and its leaf nodes. It only reads: every request is a GET, and it
# changes nothing.
#
# Reads NATS_URL (default http://localhost:8222), its monitoring port: /varz
# and /routez.
# What the scripts share is in _nats.sh, beside this one.
#
# Metrics:
#   up                    1 when the server answered, else 0 (and nothing more
#                         is read)
#   clustered             1 when it has a cluster port; 0 alone (and nothing
#                         more is read)
#   routes_configured     routes in its configuration (cluster.routes): the
#                         servers it is told to reach
#   route_peers           other servers of its cluster it has a route to
#   route_peer            always 1, one line for each of them, tagged
#                         peer=<its name>
#   route_peer_not_shown  how many more there were than the 20 shown
#   route_connections     route connections: with route pooling (2.10 and
#                         later), several to each server
#   route_pending_bytes   bytes waiting to be sent on its routes
#   route_rtt_max_ms      the slowest route's round trip, in milliseconds
#   leafnodes             leaf node connections
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  route_peers the cluster's size less one, steady;
#            route_pending_bytes near 0.
#   Watch    route_rtt_max_ms well above its usual; route_pending_bytes
#            growing.
#   Act      route_peers below the cluster's size less one: a server is down
#            or cut off (route_peer says which are there); with JetStream, a
#            cluster that loses more than half its servers stops accepting
#            writes.
#
# Requires: bash, curl, jq
# Exit code: 0, whatever it reads, and when NATS does not answer (up 0 is the
#   reading); 1 when it answers wrong (not HTTP, a page missing), said on
#   stderr, or curl or jq is missing

set -u

job=cluster
# shellcheck source=/dev/null
. "$(dirname "$0")/_nats.sh"
needs curl jq

get '/varz' varz
case $? in
    0) echo "metric up 1" ;;
    2 | 5) echo "metric up 0"; exit 0 ;;
    3) echo "metric up 0"; echo "$job: $url/varz: no such page (HTTP 404): is NATS_URL its monitoring port (-m 8222)?" >&2; exit 0 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
if [ "$(jq -r '.cluster.cluster_port // 0' "$work/varz")" = 0 ]; then
    echo "metric clustered 0"
    exit 0
fi
echo "metric clustered 1"
get '/routez' routez || { echo "$job: $url/routez did not answer" >&2; exit 1; }
jq -r --slurpfile v "$work/varz" 'def t: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | .[0:120] | if . == "" then "none" else . end;
def ts: .[0:19] + "Z" | fromdateiso8601;
def pct(a; b): if b > 0 then (a * 10000 / b | round) / 100 else 0 end;
def ms: [scan("([0-9.]+)(h|ms|m|s|µs|us|ns)")]
    | map((.[0] | tonumber) * ({"h": 3600000, "m": 60000, "s": 1000, "ms": 1, "µs": 0.001, "us": 0.001, "ns": 0.000001}[.[1]]))
    | (add // 0) * 1000 | round / 1000;

    ([(.routes // [])[] | .remote_name] | unique) as $peers |
    "metric routes_configured \($v[0].cluster.urls // [] | length)",
    "metric route_peers \($peers | length)",
    ($peers[0:20][] | "metric route_peer 1 peer=\(t)"),
    "metric route_peer_not_shown \([($peers | length) - 20, 0] | max)",
    "metric route_connections \(.num_routes)",
    "metric route_pending_bytes \([(.routes // [])[] | .pending_size] | add // 0)",
    "metric route_rtt_max_ms \([(.routes // [])[] | .rtt | ms] | max // 0)",
    "metric leafnodes \($v[0].leafnodes // 0)"' "$work/routez"
exit 0
