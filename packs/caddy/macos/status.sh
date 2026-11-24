#!/usr/bin/env bash
#
# status.sh - a Caddy server, from its admin API
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
# Reports whether Caddy's admin API answers, what its configuration serves
# (HTTP servers, the addresses they listen on, routes, site names, reverse
# proxies, file servers, and certificate policies), whether its HTTP metrics
# are on, whether the last configuration change loaded and how long ago, and
# its process's goroutines and open files against its limit. It only reads: it
# changes nothing.
#
# Reads Caddy's admin API at CADDY_ADMIN (default http://localhost:2019, where
# Caddy listens unless told otherwise), with GET only: the API could change
# Caddy's configuration, and this job never asks it to. It reads /config/ and
# /metrics.
# What the scripts share is in _caddy.sh, beside this one.
#
# Metrics:
#   up                   1 when the admin API answers, else 0
#   servers              HTTP servers in the configuration
#   listeners            addresses they listen on
#   routes               routes, all servers together
#   sites                site names the routes match
#   reverse_proxies      reverse_proxy handlers
#   file_servers         file_server handlers
#   tls_policies         certificate automation policies
#   metrics_enabled      1 when Caddy's HTTP metrics are on (the traffic job
#                        needs them), else 0
#   reload_ok            1 when the last configuration change loaded, 0 when
#                        it failed (Caddy kept the old one)
#   last_reload_seconds  since the configuration last loaded
#   goroutines           Caddy's goroutines
#   open_fds             files and sockets Caddy holds open
#   max_fds              the most it may
#   fds_pct              open_fds as a percentage of max_fds
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric servers 2
#   metric listeners 2
#   metric routes 3
#   metric sites 1
#   metric reverse_proxies 3
#   metric file_servers 0
#   metric tls_policies 1
#   metric metrics_enabled 1
#   metric reload_ok 1
#   metric last_reload_seconds 110
#   metric goroutines 35
#   metric open_fds 15
#   metric max_fds 524287
#   metric fds_pct 0.00
#
# Reading the results (starting points: tune them to the server):
#   Healthy  up 1; reload_ok 1; fds_pct well below 100.
#   Watch    goroutines climbing for hours: a leak, or connections held open;
#            fds_pct above 70.
#   Act      up 0; reload_ok 0: a configuration change was refused and Caddy
#            still runs the old one (its log says why); fds_pct near 100: new
#            connections fail.
#
# Requires: bash, curl, jq
# Exit code: 0 on success, Caddy up or down; 1 if curl or jq is missing, or
#   the address is not Caddy's admin API

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_caddy.sh"
needs curl jq

admin=${CADDY_ADMIN:-http://localhost:2019}
admin=${admin%/}
prom() {
    awk -v m="$1" -v l="${2-}" '
        index($0, m "{") == 1 || index($0, m " ") == 1 {
            k = ""
            if (l != "" && match($0, l "=\"[^\"]*\"")) k = substr($0, RSTART + length(l) + 2, RLENGTH - length(l) - 3)
            s[k] += $NF; seen = 1
        }
        # %.15g: awk would print a timestamp with six digits (1.79551e+09).
        END { if (seen) for (k in s) printf "%s%.15g\n", (l == "" ? "" : k " "), s[k] }' "$work/metrics"
}
fetch "$admin/config/"
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    *) exit 1 ;;
esac
echo "metric up 1"
jq -r '
    (.apps.http.servers // {}) as $s |
    [$s[]] as $all |
    "metric servers \($all | length)",
    "metric listeners \([$all[].listen[]?] | unique | length)",
    "metric routes \([$all[].routes[]?] | length)",
    "metric sites \([$all[].routes[]?.match[]?.host[]?] | unique | length)",
    "metric reverse_proxies \([$all[] | .. | objects | select(.handler? == "reverse_proxy")] | length)",
    "metric file_servers \([$all[] | .. | objects | select(.handler? == "file_server")] | length)",
    "metric tls_policies \([.apps.tls.automation.policies[]?] | length)",
    "metric metrics_enabled \(if (.apps.http.metrics != null) or ([$all[].metrics] | any(. != null)) then 1 else 0 end)"
' "$work/body" 2> /dev/null || { echo "$job: $admin/config/ is not a Caddy configuration" >&2; exit 1; }
fetch "$admin/metrics" || exit 1
cp "$work/body" "$work/metrics"
ok=$(prom caddy_config_last_reload_successful)
ts=$(prom caddy_config_last_reload_success_timestamp_seconds)
[ -n "$ok" ] && echo "metric reload_ok $ok"
[ -n "$ts" ] && echo "metric last_reload_seconds $(awk -v n="$now" -v t="$ts" 'BEGIN { printf "%d", n - t }')"
g=$(prom go_goroutines); o=$(prom process_open_fds); x=$(prom process_max_fds)
[ -n "$g" ] && echo "metric goroutines $g"
if [ -n "$o" ]; then
    echo "metric open_fds $o"
    [ -n "$x" ] && echo "metric max_fds $x" && awk -v o="$o" -v x="$x" 'BEGIN { if (x > 0) printf "metric fds_pct %.2f\n", 100 * o / x }'
fi
exit 0
