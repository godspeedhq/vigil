#!/usr/bin/env bash
#
# status.sh - is VictoriaLogs up, writable and answering queries
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
# Reports whether VictoriaLogs answers, whether its storage has gone read-only
# for lack of disk, the disk space left and what its data takes, the requests
# it answered and those that failed (for each path), and how close its queries
# are to the limit on running at once. It only reads: every request is a GET,
# and it changes nothing.
#
# Reads VICTORIALOGS_URL (default http://localhost:9428): /metrics,
# VictoriaLogs' page about itself, and /health.
# What the scripts share is in _victorialogs.sh, beside this one.
#
# Metrics:
#   up                           1 when VictoriaLogs answered its metrics
#                                page, else 0 (and nothing more is read)
#   healthy                      1 when /health answers 200, else 0
#   version                      always 1, tagged version=<its version>
#   uptime_seconds               seconds since it started
#   read_only                    1 when the storage refuses writes: the disk
#                                has less free than
#                                -storage.minFreeDiskSpaceBytes; else 0
#   free_disk_bytes              free space on the disk its data is on
#   data_bytes                   what its data and index take on disk
#   http_requests_count          requests answered (a running total)
#   http_errors_count            requests that failed (a running total)
#   http_errors                  the same, for each path, tagged path=<it>
#   http_errors_not_shown        how many more there were than the 20 shown
#   selects                      queries running now
#   selects_capacity             the most it runs at once
#                                (-search.maxConcurrentRequests)
#   selects_pct                  queries running, as a percentage of that
#   selects_limit_reached_count  times a query had to wait for a place (a
#                                running total)
#   selects_limit_timeout_count  queries turned away after waiting
#                                -search.maxQueueDuration (a running total)
#   live_tails                   live tails open now
#   errors_logged_count          errors it logged (a running total)
#   panics_logged_count          panics it logged (a running total)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric healthy 1
#   metric version 1 version=v1.54.0
#   metric uptime_seconds 304
#   metric read_only 0
#   metric free_disk_bytes 80061059072
#   metric data_bytes 14571
#   metric http_requests_count 237
#   metric http_errors_count 0
#   metric http_errors 0 path=/insert/journald/upload
#   metric http_errors 0 path=/insert/jsonline
#   metric http_errors_not_shown 0
#   metric selects 0
#   metric selects_capacity 8
#   metric selects_pct 0
#   metric selects_limit_reached_count 0
#   metric selects_limit_timeout_count 0
#   metric live_tails 0
#   metric errors_logged_count 0
#   metric panics_logged_count 0
#
# Reading the results (starting points: tune them to your own):
#   Healthy  up 1; healthy 1; read_only 0; http_errors_count and
#            errors_logged_count not moving.
#   Watch    free_disk_bytes falling towards its limit; selects_pct near 100
#            or selects_limit_reached_count moving; http_errors_count moving
#            on a query path (a query that does not parse).
#   Act      up 0 or healthy 0; read_only 1: it accepts no more logs until
#            space is freed; selects_limit_timeout_count moving;
#            http_errors_count moving on an insert path (http_errors says
#            which): a shipper is being refused.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when VictoriaLogs does not answer (up 0
#   is the reading); 1 when it answers wrong (a login refused, not HTTP), said
#   on stderr, or curl or awk is missing

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_victorialogs.sh"
needs curl awk

page '/metrics'
answers healthy '/health'
readings <<'T'
version|info|vm_app_version||short_version:version
uptime_seconds|max|vm_app_uptime_seconds
read_only|max|vl_storage_is_read_only
free_disk_bytes|min|vl_free_disk_space_bytes
data_bytes|sum|vl_data_size_bytes
http_requests_count|sum|vl_http_requests_total
http_errors_count|sum|vl_http_errors_total
http_errors|by|vl_http_errors_total||path
selects|sum|vl_concurrent_select_current
selects_capacity|sum|vl_concurrent_select_capacity
selects_pct|pct|selects|selects_capacity
selects_limit_reached_count|sum|vl_concurrent_select_limit_reached_total
selects_limit_timeout_count|sum|vl_concurrent_select_limit_timeout_total
live_tails|sum|vl_live_tailing_requests
errors_logged_count|sum|vm_log_messages_total|level=error
panics_logged_count|sum|vm_log_messages_total|level=panic
T
exit 0
