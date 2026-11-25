#!/usr/bin/env bash
#
# status.sh - is Prometheus ready, loaded and answering
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
# Reports whether Prometheus is ready, whether its last configuration reload
# worked and when, the queries it is running against the most it allows, the
# requests it answered and those that failed, and the alerts it sent to its
# Alertmanagers, with those that failed or were dropped. It only reads: every
# request is a GET, and it changes nothing.
#
# Reads PROMETHEUS_URL (default http://localhost:9090): /metrics, Prometheus'
# page about itself, and /-/ready.
# What the scripts share is in _prometheus.sh, beside this one.
#
# Metrics:
#   up                              1 when Prometheus answered its metrics
#                                   page, else 0 (and nothing more is read)
#   ready                           1 when Prometheus says it is ready to
#                                   serve (/-/ready answers 200), else 0: it
#                                   is starting, replaying its WAL, or
#                                   shutting down
#   version                         always 1, tagged version=<its version>
#   uptime_seconds                  seconds since it started
#   config_reload_ok                1 when the last configuration reload
#                                   worked, else 0: it is still running the
#                                   one before
#   config_age_seconds              seconds since the configuration it runs
#                                   was loaded
#   queries                         queries running or waiting now
#   queries_max                     the most it runs at once
#                                   (--query.max-concurrency)
#   queries_pct                     queries, as a percentage of that
#   http_requests_count             requests answered (a running total)
#   http_4xx_count                  of those, answered 4xx: a query it could
#                                   not parse, or refused (a running total)
#   http_5xx_count                  answered 5xx: it failed, or a query timed
#                                   out (a running total)
#   alertmanagers                   Alertmanagers it found to send alerts to
#   notifications_sent_count        alerts sent to them (a running total)
#   notifications_errors_count      alerts an Alertmanager did not take (a
#                                   running total)
#   notifications_errors            the same, for each Alertmanager, tagged
#                                   alertmanager=<its address>
#   notifications_errors_not_shown  how many more there were than the 20 shown
#   notifications_dropped_count     alerts dropped: the queue was full, or no
#                                   Alertmanager took them (a running total)
#   notification_queue              alerts waiting to be sent
#   notification_queue_capacity     how many may wait
#   fds_pct                         open files, as a percentage of its limit
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric ready 1
#   metric version 1 version=3.15.1
#   metric uptime_seconds 303
#   metric config_reload_ok 1
#   metric config_age_seconds 301
#   metric queries 0
#   metric queries_max 20
#   metric queries_pct 0
#   metric http_requests_count 261
#   metric http_4xx_count 71
#   metric http_5xx_count 0
#   metric alertmanagers 3
#   metric notifications_sent_count 10
#   metric notifications_errors_count 5
#   metric notifications_errors 5 alertmanager=http://alertmanager:9/api/v2/alerts
#   metric notifications_errors 0 alertmanager=http://alertmanager2:9093/api/v2/alerts
#   metric notifications_errors 0 alertmanager=http://alertmanager:9093/api/v2/alerts
#   metric notifications_errors_not_shown 0
#   metric notifications_dropped_count 5
#   metric notification_queue 0
#   metric notification_queue_capacity 10000
#   metric fds_pct 0.01
#
# Reading the results (starting points: tune them to your own):
#   Healthy  up 1; ready 1; config_reload_ok 1; http_5xx_count and
#            notifications_errors_count not moving.
#   Watch    queries_pct near 100 (queries queue behind
#            --query.max-concurrency); notification_queue growing;
#            http_4xx_count climbing (a dashboard or a rule with a query that
#            no longer parses).
#   Act      up 0 or ready 0; config_reload_ok 0 (an edit it refused: it runs
#            the old configuration until the file is fixed);
#            notifications_errors_count or notifications_dropped_count
#            climbing: alerts are not reaching anyone; fds_pct above 80.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Prometheus does not answer (up 0
#   is the reading); 1 when it answers wrong (a login refused, not HTTP), said
#   on stderr, or curl or awk is missing

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_prometheus.sh"
needs curl awk

page '/metrics'
answers ready '/-/ready'
readings <<'T'
version|info|prometheus_build_info||version:version
uptime_seconds|age|process_start_time_seconds
config_reload_ok|min|prometheus_config_last_reload_successful
config_age_seconds|age|prometheus_config_last_reload_success_timestamp_seconds
queries|sum|prometheus_engine_queries
queries_max|sum|prometheus_engine_queries_concurrent_max
queries_pct|pct|queries|queries_max
http_requests_count|sum|prometheus_http_requests_total
http_4xx_count|sum|prometheus_http_requests_total|code~^4
http_5xx_count|sum|prometheus_http_requests_total|code~^5
alertmanagers|sum|prometheus_notifications_alertmanagers_discovered
notifications_sent_count|sum|prometheus_notifications_sent_total
notifications_errors_count|sum|prometheus_notifications_errors_total
notifications_errors|by|prometheus_notifications_errors_total||alertmanager
notifications_dropped_count|sum|prometheus_notifications_dropped_total
notification_queue|sum|prometheus_notifications_queue_length
notification_queue_capacity|sum|prometheus_notifications_queue_capacity
_fds|sum|process_open_fds
_maxfds|sum|process_max_fds
fds_pct|pct|_fds|_maxfds
T
exit 0
