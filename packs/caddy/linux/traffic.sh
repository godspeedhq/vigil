#!/usr/bin/env bash
#
# traffic.sh - the traffic each Caddy server handles
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
# Reports, for each of Caddy's HTTP servers, the requests it handled, those in
# flight, the errors its handlers returned, its answers by status class, and
# how long they took on average, from Caddy's own metrics. These need Caddy's
# HTTP metrics on: the global option { metrics } in a Caddyfile. It only
# reads: it changes nothing.
#
# Reads Caddy's admin API at CADDY_ADMIN (default http://localhost:2019, where
# Caddy listens unless told otherwise), with GET only: the API could change
# Caddy's configuration, and this job never asks it to. It reads
# /config/apps/http (whether the metrics are on) and /metrics.
# What the scripts share is in _caddy.sh, beside this one.
#
# Metrics:
#   up                    1 when the admin API answers, else 0
#   metrics_enabled       1 when Caddy's HTTP metrics are on, else 0 (and
#                         nothing more is reported)
#   requests_count        requests handled (a running total), tagged
#                         server=<its name>
#   in_flight             requests being handled now, tagged server
#   handler_errors_count  requests a handler failed (a running total), tagged
#                         server
#   status_2xx_count      answers 2xx (a running total), tagged server
#   status_3xx_count      answers 3xx, tagged server
#   status_4xx_count      answers 4xx, tagged server
#   status_5xx_count      answers 5xx, tagged server
#   duration_avg_ms       time to answer, on average since Caddy started,
#                         tagged server
#   servers_reporting     servers with HTTP metrics to report (0 with
#                         metrics_enabled 1 while Caddy serves traffic: in our
#                         tests, Caddy 2.11.9 stopped reporting them after any
#                         configuration reload through its admin API, until it
#                         restarted)
#   servers_not_shown     servers past the first 50, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric metrics_enabled 1
#   metric requests_count 2 server=srv0
#   metric in_flight 0 server=srv0
#   metric handler_errors_count 0 server=srv0
#   metric status_2xx_count 0 server=srv0
#   metric status_3xx_count 0 server=srv0
#   metric status_4xx_count 0 server=srv0
#   metric status_5xx_count 2 server=srv0
#   metric duration_avg_ms 0.02 server=srv0
#   metric requests_count 104 server=srv1
#   metric in_flight 0 server=srv1
#   metric handler_errors_count 4 server=srv1
#   metric status_2xx_count 99 server=srv1
#   metric status_3xx_count 0 server=srv1
#   metric status_4xx_count 1 server=srv1
#
# Reading the results (starting points: tune them to the server):
#   Healthy  status_5xx_count and handler_errors_count flat (graph the _count
#            totals as rates).
#   Watch    status_4xx_count rising faster than requests_count; in_flight
#            climbing; servers_reporting 0 with metrics_enabled 1 on a Caddy
#            that serves traffic: its metrics stopped after a reload (restart
#            Caddy to have them back).
#   Act      status_5xx_count or handler_errors_count rising: requests failing
#            (the upstreams job says whether an upstream is down).
#
# Requires: bash, curl, jq
# Exit code: 0 on success, Caddy up or down; 1 if curl is missing, or the
#   address is not Caddy's admin API

set -u

job=traffic
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
# On or not is in the configuration: after a reload, the counters are
# empty until a request comes.
fetch "$admin/config/apps/http"
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    *) exit 1 ;;
esac
echo "metric up 1"
on=$(jq -r 'if (.metrics != null) or ([(.servers // {})[].metrics] | any(. != null)) then 1 else 0 end' "$work/body" 2> /dev/null)
echo "metric metrics_enabled ${on:-0}"
[ "$on" = 1 ] || exit 0
fetch "$admin/metrics" || exit 1
cp "$work/body" "$work/metrics"
prom caddy_http_requests_total server | sort | head -n 50 > "$work/servers"
while read -r s n; do
    t="server=$(tag "$s")"
    echo "metric requests_count $n $t"
    echo "metric in_flight $(awk -v s="server=\"$s\"" 'index($0, "caddy_http_requests_in_flight{") == 1 && index($0, s) { v += $NF } END { printf "%.0f", v }' "$work/metrics") $t"
    echo "metric handler_errors_count $(awk -v s="server=\"$s\"" 'index($0, "caddy_http_request_errors_total{") == 1 && index($0, s) { v += $NF } END { printf "%.0f", v }' "$work/metrics") $t"
    awk -v s="server=\"$s\"" -v t="$t" '
        index($0, "caddy_http_request_duration_seconds_count{") == 1 && index($0, s) {
            if (match($0, /code="[0-9]/)) c[substr($0, RSTART + 6, 1)] += $NF
            n += $NF
        }
        index($0, "caddy_http_request_duration_seconds_sum{") == 1 && index($0, s) { sum += $NF }
        END {
            for (k = 2; k <= 5; k++) printf "metric status_%dxx_count %.0f %s\n", k, c[k], t
            printf "metric duration_avg_ms %.2f %s\n", (n > 0 ? 1000 * sum / n : 0), t
        }' "$work/metrics"
done < "$work/servers"
echo "metric servers_reporting $(prom caddy_http_requests_total server | wc -l | tr -d ' ')"
echo "metric servers_not_shown $(( $(prom caddy_http_requests_total server | wc -l) - $(wc -l < "$work/servers") ))"
exit 0
