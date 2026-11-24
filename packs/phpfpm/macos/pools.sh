#!/usr/bin/env bash
#
# pools.sh - PHP-FPM's pools: their workers, queue and slow requests
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
# Reads each PHP-FPM pool's status page and reports: its process manager, how
# long it has run, the requests it accepted, its listen queue against its
# length (requests waiting for a worker), its workers (idle, active, all, the
# most active at once), how often it hit pm.max_children, its slow requests,
# and its memory peak. Then its workers one by one, summed up: how many are in
# each state, the longest request running now, and the most memory, CPU,
# requests and age of any. It never prints a request's URI or script: only
# counts. It only reads: it changes nothing.
#
# Reads each URL in PHPFPM_STATUS_URLS, separated by spaces (default
# http://127.0.0.1/fpm-status), with ?full: a pool's pm.status_path, which a
# web server passes to PHP-FPM and allows from this machine only. One URL for
# each pool.
# What the scripts share is in _phpfpm.sh, beside this one.
#
# Metrics:
#   up                             1 when the page answers, else 0, tagged
#                                  url=<it>
#   timed_out                      1 when the page was reached but did not
#                                  answer in 10 seconds, tagged url: the
#                                  status page waits for a free worker like
#                                  any request, so this is every worker busy
#                                  (or the web server stuck); 0 when it
#                                  answered or nothing listened
#   info                           always 1, tagged pool=<its name> and
#                                  pm=<static, dynamic or ondemand>
#   uptime_seconds                 since the pool started, tagged pool
#   accepted_count                 requests accepted (a running total), tagged
#                                  pool
#   listen_queue                   requests waiting for a free worker, tagged
#                                  pool
#   listen_queue_max               the most that waited at once since it
#                                  started, tagged pool
#   listen_queue_len               the most that may wait, tagged pool
#   listen_queue_pct               listen_queue as a percentage of
#                                  listen_queue_len, tagged pool
#   idle_processes                 workers waiting for a request, tagged pool
#   active_processes               workers serving one, tagged pool
#   total_processes                all its workers, tagged pool
#   active_max                     the most active at once since it started,
#                                  tagged pool
#   max_children_reached_count     times it wanted another worker and
#                                  pm.max_children said no (a running total),
#                                  tagged pool
#   slow_requests_count            requests slower than
#                                  request_slowlog_timeout (a running total),
#                                  tagged pool
#   memory_peak_bytes              the most memory the pool used (PHP 8.4 and
#                                  later), tagged pool
#   processes_in_state             workers in one state, tagged pool and
#                                  state=<Idle, Running, Reading_headers,
#                                  Finishing, Ending...>
#   longest_request_ms             the longest request running now, tagged
#                                  pool
#   last_request_memory_max_bytes  the most memory any worker's last request
#                                  used, tagged pool
#   last_request_cpu_max_pct       the most CPU any worker's last request
#                                  used, tagged pool
#   process_requests_max           the most requests one worker has served
#                                  (pm.max_requests restarts it), tagged pool
#   process_age_max_seconds        the oldest worker, tagged pool
#
# Example output (the rest are in the same form):
#   metric up 1 url=http://127.0.0.1:18280/fpm-status
#   metric timed_out 0 url=http://127.0.0.1:18280/fpm-status
#   metric info 1 pool=www pm=dynamic
#   metric uptime_seconds 99 pool=www
#   metric accepted_count 9 pool=www
#   metric listen_queue 0 pool=www
#   metric listen_queue_max 2 pool=www
#   metric listen_queue_len 4096 pool=www
#   metric listen_queue_pct 0.00 pool=www
#   metric idle_processes 0 pool=www
#   metric active_processes 4 pool=www
#   metric total_processes 4 pool=www
#   metric active_max 4 pool=www
#   metric max_children_reached_count 0 pool=www
#   metric slow_requests_count 3 pool=www
#   metric processes_in_state 4 pool=www state=Running
#
# Reading the results (starting points: tune them to the server):
#   Healthy  up 1; listen_queue 0; max_children_reached_count flat;
#            idle_processes above 0.
#   Watch    slow_requests_count rising (the slow log says which scripts);
#            active_max near total_processes; longest_request_ms in seconds.
#   Act      up 0; timed_out 1: no worker free even for the status page;
#            listen_queue above 0, or max_children_reached_count rising: every
#            worker is busy and requests wait, or time out as 502 or 504 at
#            the web server: raise pm.max_children, or find what holds the
#            workers (longest_request_ms).
#
# Requires: bash, curl
# Exit code: 0 on success, the pools up or down; 1 if curl is missing, or a
#   URL answers but is not a PHP-FPM status page

set -u

job=pools
# shellcheck source=/dev/null
. "$(dirname "$0")/_phpfpm.sh"
needs curl

read -r -a urls <<< "${PHPFPM_STATUS_URLS:-http://127.0.0.1/fpm-status}"
for u in "${urls[@]}"; do
    fetch "$u?full"
    case $? in
        0) ;;
        2)
            echo "metric up 0 url=$(tag "$u")"
            # Reached, and no answer: the page waits for a free worker.
            echo "metric timed_out $(grep -qi 'timed out' "$work/err" && echo 1 || echo 0) url=$(tag "$u")"
            continue
            ;;
        *) exit 1 ;;
    esac
    grep -q '^pool:' "$work/body" || { echo "$job: $u is not a PHP-FPM status page" >&2; exit 1; }
    echo "metric up 1 url=$(tag "$u")"
    echo "metric timed_out 0 url=$(tag "$u")"
    awk '
        function tag(s) { gsub(/[^A-Za-z0-9@._:\/+-]/, "_", s); s = substr(s, 1, 120); return s == "" ? "none" : s }
        function num(x) { return (x ~ /^-?[0-9]+([.][0-9]+)?$/) ? x : 0 }
        /^\*+$/ { proc++; next }
        {
            i = index($0, ":"); if (!i) next
            k = substr($0, 1, i - 1); v = substr($0, i + 1); sub(/^ +/, "", v); sub(/ +$/, "", v)
            if (!proc) { p[k] = v; next }
            if (k == "state") { st = v; state[v]++ }
            else if (k == "start since" && v + 0 > age) age = v + 0
            else if (k == "requests" && v + 0 > reqs) reqs = v + 0
            else if (k == "request duration" && st != "Idle" && v / 1000 > longest) longest = v / 1000
            else if (k == "last request memory" && v + 0 > mem) mem = v + 0
            else if (k == "last request cpu" && v + 0 > cpu) cpu = v + 0
        }
        END {
            t = "pool=" tag(p["pool"])
            print "metric info 1 " t " pm=" tag(p["process manager"])
            print "metric uptime_seconds " num(p["start since"]) " " t
            print "metric accepted_count " num(p["accepted conn"]) " " t
            print "metric listen_queue " num(p["listen queue"]) " " t
            print "metric listen_queue_max " num(p["max listen queue"]) " " t
            print "metric listen_queue_len " num(p["listen queue len"]) " " t
            printf "metric listen_queue_pct %.2f %s\n", (p["listen queue len"] > 0 ? 100 * p["listen queue"] / p["listen queue len"] : 0), t
            print "metric idle_processes " num(p["idle processes"]) " " t
            print "metric active_processes " num(p["active processes"]) " " t
            print "metric total_processes " num(p["total processes"]) " " t
            print "metric active_max " num(p["max active processes"]) " " t
            print "metric max_children_reached_count " num(p["max children reached"]) " " t
            print "metric slow_requests_count " num(p["slow requests"]) " " t
            if ("memory peak" in p) print "metric memory_peak_bytes " num(p["memory peak"]) " " t
            for (s in state) print "metric processes_in_state " state[s] " " t " state=" tag(s)
            if (proc) {
                printf "metric longest_request_ms %.1f %s\n", longest, t
                printf "metric last_request_memory_max_bytes %.0f %s\n", mem, t
                printf "metric last_request_cpu_max_pct %.2f %s\n", cpu, t
                print "metric process_requests_max " reqs + 0 " " t
                print "metric process_age_max_seconds " age + 0 " " t
            }
        }' "$work/body"
done
exit 0
