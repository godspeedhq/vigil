#!/usr/bin/env bash
#
# upstreams.sh - the upstreams Caddy's reverse proxies send to
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
# Reports every upstream of Caddy's reverse proxies: the requests it is
# handling now, its recent failures, and, where Caddy checks its health,
# whether it is healthy. It only reads: it changes nothing.
#
# Reads Caddy's admin API at CADDY_ADMIN (default http://localhost:2019, where
# Caddy listens unless told otherwise), with GET only: the API could change
# Caddy's configuration, and this job never asks it to. It reads
# /reverse_proxy/upstreams and /metrics.
# What the scripts share is in _caddy.sh, beside this one.
#
# Metrics:
#   up                   1 when the admin API answers, else 0
#   upstreams            upstreams, all reverse proxies together
#   upstreams_failing    of those, with recent failures
#   upstreams_unhealthy  of those Caddy checks, unhealthy
#   active_requests      requests it is handling now, tagged upstream=<its
#                        address>
#   fails                its failures counted now (they expire after
#                        fail_duration), tagged upstream
#   healthy              1 when Caddy's health checks find it healthy, else 0,
#                        tagged upstream (only for upstreams Caddy checks)
#   upstreams_not_shown  upstreams past the first 100, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric upstreams 4
#   metric upstreams_failing 0
#   metric upstreams_unhealthy 1
#   metric active_requests 0 upstream=10.255.255.1:81
#   metric fails 0 upstream=10.255.255.1:81
#   metric healthy 1 upstream=10.255.255.1:81
#   metric active_requests 0 upstream=gone:80
#   metric fails 0 upstream=gone:80
#   metric healthy 0 upstream=gone:80
#   metric upstreams_not_shown 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  upstreams_failing 0; upstreams_unhealthy 0.
#   Watch    fails above 0 on one upstream: it fails now and then.
#   Act      upstreams_unhealthy above 0: Caddy has stopped sending to it;
#            every upstream of a proxy failing: that site answers 502.
#
# Requires: bash, curl, jq
# Exit code: 0 on success, Caddy up or down; 1 if curl or jq is missing, or
#   the address is not Caddy's admin API

set -u

job=upstreams
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
fetch "$admin/reverse_proxy/upstreams"
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    *) exit 1 ;;
esac
echo "metric up 1"
cp "$work/body" "$work/up.json"
fetch "$admin/metrics" > /dev/null 2>&1 && cp "$work/body" "$work/metrics" || : > "$work/metrics"
prom caddy_reverse_proxy_upstreams_healthy upstream > "$work/health"
jq -r --rawfile h "$work/health" '
    def tag: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | .[0:120] | if . == "" then "none" else . end;
    ($h | split("\n") | map(select(. != "") | split(" ")) | map({key: .[0], value: (.[1] | tonumber)}) | from_entries) as $hs |
    (. // []) as $u |
    "metric upstreams \($u | length)",
    "metric upstreams_failing \([$u[] | select(.fails > 0)] | length)",
    "metric upstreams_unhealthy \([$hs[] | select(. == 0)] | length)",
    ($u | sort_by(-.fails, .address) | .[0:100][] | "upstream=\(.address | tag)" as $t |
        "metric active_requests \(.num_requests) \($t)",
        "metric fails \(.fails) \($t)",
        (if $hs[.address] != null then "metric healthy \($hs[.address]) \($t)" else empty end)),
    "metric upstreams_not_shown \([($u | length) - 100, 0] | max)"
' "$work/up.json" || { echo "$job: $admin/reverse_proxy/upstreams is not a list of upstreams" >&2; exit 1; }
exit 0
