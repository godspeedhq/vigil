#!/usr/bin/env bash
#
# status.sh - is this NATS server healthy, and are its clients keeping up
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
# Reports whether the server answers and is healthy (ready, and with JetStream
# on, current with its cluster), what it is, how long since it started and
# since its configuration last loaded, its connections against its limit, its
# subscriptions, the slow consumers it has cut off (clients, routes, gateways
# and leaf nodes that could not keep up), stale connections, the messages and
# bytes in and out, and the client with the most bytes waiting to be sent to
# it, named. It only reads: every request is a GET, and it changes nothing.
#
# Reads NATS_URL (default http://localhost:8222), its monitoring port: /varz,
# /healthz and /connz?sort=pending&limit=1.
# What the scripts share is in _nats.sh, beside this one.
#
# Metrics:
#   up                            1 when the server answered, else 0 (and
#                                 nothing more is read)
#   healthy                       1 when /healthz answers ok; 0 when it
#                                 answers 503: not ready, or JetStream not
#                                 current with its cluster
#   info                          always 1, tagged server=<its name>,
#                                 version=, cluster=<its name, or none> and
#                                 jetstream=<on or off>
#   uptime_seconds                since the server started
#   last_reload_seconds           since its configuration last loaded
#                                 (started, or reloaded)
#   connections                   clients connected
#   max_connections               the most it allows (max_connections)
#   connections_pct               connections, of max_connections
#   total_connections_count       clients that have connected (a running
#                                 total)
#   subscriptions                 subscriptions, routes' and the system's
#                                 included
#   slow_consumers_count          connections it cut off for not reading fast
#                                 enough (a running total)
#   slow_consumer_clients_count   of them, clients (a running total; 2.10 and
#                                 later, as the next three)
#   slow_consumer_routes_count    routes to other servers of its cluster
#   slow_consumer_gateways_count  gateways to other clusters
#   slow_consumer_leafs_count     leaf nodes
#   stale_connections_count       connections closed for not answering its
#                                 pings (a running total)
#   in_msgs_count                 messages received, from clients and other
#                                 servers (a running total)
#   out_msgs_count                messages sent (a running total)
#   in_bytes_count                bytes received (a running total)
#   out_bytes_count               bytes sent (a running total)
#   pending_bytes_max             bytes waiting to be sent to the client
#                                 furthest behind, tagged client=<its name, or
#                                 address:port>
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric healthy 1
#   metric info 1 server=n1 version=2.15.3 cluster=c1 jetstream=on
#   metric uptime_seconds 30
#   metric last_reload_seconds 30
#   metric connections 0
#   metric max_connections 65536
#   metric connections_pct 0
#   metric total_connections_count 9
#   metric subscriptions 272
#   metric slow_consumers_count 2
#   metric slow_consumer_clients_count 2
#   metric slow_consumer_routes_count 0
#   metric slow_consumer_gateways_count 0
#   metric slow_consumer_leafs_count 0
#   metric stale_connections_count 0
#   metric in_msgs_count 6742
#   metric out_msgs_count 3491
#   metric in_bytes_count 8603626
#   metric out_bytes_count 1852581
#   metric pending_bytes_max 0 client=none
#
# Reading the results (starting points: tune them to your own):
#   Healthy  up 1; healthy 1; connections_pct well below 80;
#            slow_consumers_count flat; pending_bytes_max small.
#   Watch    connections_pct above 80; pending_bytes_max growing: that client
#            is falling behind (client says which).
#   Act      up 0 or healthy 0; slow_consumers_count moving: the server is
#            cutting off clients (or routes) that cannot keep up, and they
#            lose messages; connections_pct near 100: new clients are refused.
#
# Requires: bash, curl, jq
# Exit code: 0, whatever it reads, and when NATS does not answer (up 0 is the
#   reading); 1 when it answers wrong (not HTTP, a page missing), said on
#   stderr, or curl or jq is missing

set -u

job=status
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
# /healthz answers 503 when the server is not ready: JetStream not current
# with its cluster, or not started.
get '/healthz' healthz
case $? in
    0) echo "metric healthy 1" ;;
    5) echo "metric healthy 0" ;;
esac
jq -r 'def t: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | .[0:120] | if . == "" then "none" else . end;
def ts: .[0:19] + "Z" | fromdateiso8601;
def pct(a; b): if b > 0 then (a * 10000 / b | round) / 100 else 0 end;
def ms: [scan("([0-9.]+)(h|ms|m|s|µs|us|ns)")]
    | map((.[0] | tonumber) * ({"h": 3600000, "m": 60000, "s": 1000, "ms": 1, "µs": 0.001, "us": 0.001, "ns": 0.000001}[.[1]]))
    | (add // 0) * 1000 | round / 1000;

    "metric info 1 server=\(.server_name | t) version=\(.version | t) cluster=\(.cluster.name // "" | t) jetstream=\(if .jetstream.config then "on" else "off" end)",
    "metric uptime_seconds \((.now | ts) - (.start | ts))",
    "metric last_reload_seconds \((.now | ts) - (.config_load_time | ts))",
    "metric connections \(.connections)",
    "metric max_connections \(.max_connections)",
    "metric connections_pct \(pct(.connections; .max_connections))",
    "metric total_connections_count \(.total_connections)",
    "metric subscriptions \(.subscriptions)",
    "metric slow_consumers_count \(.slow_consumers)",
    (.slow_consumer_stats // empty |
        "metric slow_consumer_clients_count \(.clients)",
        "metric slow_consumer_routes_count \(.routes)",
        "metric slow_consumer_gateways_count \(.gateways)",
        "metric slow_consumer_leafs_count \(.leafs)"),
    "metric stale_connections_count \(.stale_connections // 0)",
    "metric in_msgs_count \(.in_msgs)",
    "metric out_msgs_count \(.out_msgs)",
    "metric in_bytes_count \(.in_bytes)",
    "metric out_bytes_count \(.out_bytes)"' "$work/varz"
# The client with the most bytes waiting to be sent to it: the next slow
# consumer, before the server cuts it off.
if get '/connz?sort=pending&limit=1' connz; then
    jq -r 'def t: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | .[0:120] | if . == "" then "none" else . end;
def ts: .[0:19] + "Z" | fromdateiso8601;
def pct(a; b): if b > 0 then (a * 10000 / b | round) / 100 else 0 end;
def ms: [scan("([0-9.]+)(h|ms|m|s|µs|us|ns)")]
    | map((.[0] | tonumber) * ({"h": 3600000, "m": 60000, "s": 1000, "ms": 1, "µs": 0.001, "us": 0.001, "ns": 0.000001}[.[1]]))
    | (add // 0) * 1000 | round / 1000;

        (.connections // [])[0] |
        if . == null then "metric pending_bytes_max 0 client=none"
        else "metric pending_bytes_max \(.pending_bytes // 0) client=\(if (.name // "") != "" then .name else "\(.ip):\(.port)" end | t)" end' "$work/connz"
fi
exit 0
