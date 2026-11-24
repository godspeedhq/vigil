#!/usr/bin/env bash
#
# status.sh - a CockroachDB node: up, ready, and how it is doing
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
# Reports one node, the one at COCKROACH_URL, from its own metrics: whether
# it answers and is ready for SQL, its version and uptime, the nodes it sees
# live, its clock's offset from the others' (a node too far out stops
# itself), the days left on its certificates, and its CPU, memory,
# goroutines and file descriptors. Run it on every node: each reports its
# own. It needs no login.
#
# Reads CockroachDB at COCKROACH_URL (default https://localhost:8080), the
# node's HTTP port, with curl and jq: /health?ready=1 and /_status/vars.
# Over https, the certificate is checked against COCKROACH_CACERT, the
# cluster's CA file (ca.crt), when it is set, else the system's CAs. What
# the scripts share is in _cockroachdb.sh, beside this one.
#
# Metrics:
#   up                        1 when the node answers, else 0
#   ready                     1 when it accepts SQL (/health?ready=1), else 0:
#                             0 while it starts, drains or cannot reach the
#                             cluster
#   node_id                   its node ID
#   info                      always 1, tagged version=<v26.4.1>
#   uptime_seconds            since it started
#   live_nodes                nodes this one sees live
#   heartbeat_failures_count  its liveness heartbeats that failed (a running
#                             total)
#   clock_offset_ms           its clock's mean offset from the other nodes'
#   clock_offset_stddev_ms    how much that offset varies
#   cpu_pct                   CPU it uses, of every core
#   rss_bytes                 its resident memory
#   goroutines                its goroutines
#   runnable_per_cpu          goroutines waiting to run, a core: past 32 it
#                             is CPU bound
#   cpu_queue                 requests waiting for admission control's CPU
#                             slots
#   cpu_slots_exhausted_seconds  time they had to wait, every slot taken (a
#                             running total)
#   fds_open                  file descriptors it holds
#   fds_pct                   of those it may hold (the soft limit)
#   cert_days                 days left on a certificate, tagged
#                             cert=<ca, node, client, ui...>: those it has
#   cert_days_min             the fewest of those
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric ready 1
#   metric node_id 1
#   metric info 1 version=v26.4.1
#   metric live_nodes 3
#   metric clock_offset_ms 0.01
#   metric cert_days 1826 cert=node
#   metric cert_days_min 1826
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  up 1 and ready 1 on every node; live_nodes the cluster's size;
#            clock_offset_ms far below the maximum (500 by default);
#            cert_days_min above 30.
#   Watch    live_nodes below the cluster's size; clock_offset_ms past 100;
#            cert_days_min below 30; runnable_per_cpu past 32; fds_pct past
#            80.
#   Act      up 0 or ready 0 for more than a few minutes; clock_offset_ms
#            near 400 (at 80% of the maximum the node stops itself);
#            cert_days_min below 7: a node with an expired certificate cannot
#            join; heartbeat_failures_count rising.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, node up or down; 1 if curl or jq is missing, or
#   the node answers wrong
#
# Example (vigil.config):
#   [job.cockroachdb_status]
#   file        = packs/cockroachdb/status.sh
#   metric_name = cockroachdb
#   run_every   = 1m
#   env         = COCKROACH_URL=https://localhost:8080
#   env         = COCKROACH_CACERT=/var/lib/cockroach/certs/ca.crt

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_cockroachdb.sh"

vars
# Ready: 200, or 503 while the node starts, drains or cannot reach a quorum.
get '/health?ready=1'
case $? in
    0) echo "metric ready 1" ;;
    3) echo "metric ready 0" ;;
    2) echo "metric ready 0" ;;
    *) exit 1 ;;
esac
say node_id node_id
awk '/^build_timestamp\{/ && match($0, /tag="[^"]*"/) { t = substr($0, RSTART + 5, RLENGTH - 6); gsub(/[^A-Za-z0-9@._:\/+-]/, "_", t); print "metric info 1 version=" t; exit }' "$work/vars"
say uptime_seconds sys_uptime
say live_nodes liveness_livenodes
say heartbeat_failures_count liveness_heartbeatfailures
# Nanoseconds to milliseconds; the mean may be negative: its size matters.
v=$(prom clock_offset_meannanos)
[ -n "$v" ] && awk -v v="$v" 'BEGIN { if (v < 0) v = -v; printf "metric clock_offset_ms %.2f\n", v / 1000000 }'
say clock_offset_stddev_ms clock_offset_stddevnanos sum 1000000
say cpu_pct sys_cpu_combined_percent_normalized sum 1 100
say rss_bytes sys_rss
say goroutines sys_goroutines
say runnable_per_cpu sys_runnable_goroutines_per_cpu
say cpu_queue admission_wait_queue_length_kv
say cpu_slots_exhausted_seconds admission_granter_slots_exhausted_duration_kv sum 1000000
o=$(prom sys_fd_open)
l=$(prom sys_fd_softlimit)
if [ -n "$o" ]; then
    echo "metric fds_open $o"
    [ -n "$l" ] && awk -v o="$o" -v l="$l" 'BEGIN { if (l > 0) printf "metric fds_pct %.2f\n", 100 * o / l }'
fi
# Each certificate's expiry, as a time (0: no such certificate).
awk -v now="$now" '
    /^security_certificate_expiration_[a-z_]+[{ ]/ {
        name = $0
        sub(/^security_certificate_expiration_/, "", name)
        sub(/[{ ].*$/, "", name)
        t = $NF + 0
        if (t <= 0) next
        d = int((t - now) / 86400)
        printf "metric cert_days %d cert=%s\n", d, name
        if (!seen || d < min) min = d
        seen = 1
    }
    END { if (seen) printf "metric cert_days_min %d\n", min }' "$work/vars"
exit 0
