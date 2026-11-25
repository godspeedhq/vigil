#!/usr/bin/env bash
#
# exporters.sh - what the Collector's exporters send, and what they lose
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
# Reports what the Collector's exporters delivered and what they could not,
# for spans, metric points and log records and for each exporter, what was
# dropped because a queue was full, and how full the queues are. A queue fills
# when its destination is down or slower than what arrives. It only reads:
# every request is a GET, and it changes nothing.
#
# Reads OTELCOL_URL (default http://localhost:8888): /metrics, the Collector's
# page about itself.
# What the scripts share is in _otelcol.sh, beside this one.
#
# Metrics:
#   up                                   1 when the OpenTelemetry Collector
#                                        answered its metrics page, else 0
#                                        (and nothing more is read)
#   sent_spans_count                     spans its exporters delivered (a
#                                        running total)
#   send_failed_spans_count              spans its exporters could not
#                                        deliver: lost, once the retries are
#                                        spent (a running total)
#   enqueue_failed_spans_count           spans dropped at once: the exporter's
#                                        queue was full (a running total)
#   sent_metric_points_count             metric points its exporters delivered
#                                        (a running total)
#   send_failed_metric_points_count      metric points its exporters could not
#                                        deliver: lost, once the retries are
#                                        spent (a running total)
#   enqueue_failed_metric_points_count   metric points dropped at once: the
#                                        exporter's queue was full (a running
#                                        total)
#   sent_log_records_count               log records its exporters delivered
#                                        (a running total)
#   send_failed_log_records_count        log records its exporters could not
#                                        deliver: lost, once the retries are
#                                        spent (a running total)
#   enqueue_failed_log_records_count     log records dropped at once: the
#                                        exporter's queue was full (a running
#                                        total)
#   send_failed_spans                    spans that could not be delivered,
#                                        for each exporter, tagged
#                                        exporter=<its name>
#   send_failed_spans_not_shown          how many more there were than the 20
#                                        shown
#   send_failed_metric_points            metric points that could not be
#                                        delivered, for each exporter, tagged
#                                        exporter=<its name>
#   send_failed_metric_points_not_shown  how many more there were than the 20
#                                        shown
#   send_failed_log_records              log records that could not be
#                                        delivered, for each exporter, tagged
#                                        exporter=<its name>
#   send_failed_log_records_not_shown    how many more there were than the 20
#                                        shown
#   queue_size                           batches waiting in the exporters'
#                                        queues
#   queue_capacity                       how many may wait
#   queue_fullest_pct                    how full the fullest queue is, as a
#                                        percentage of its own capacity
#   queue                                batches waiting, for each exporter,
#                                        tagged exporter
#   queue_not_shown                      how many more there were than the 20
#                                        shown
#   in_flight                            requests its exporters are waiting on
#                                        now
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  the sent counts moving; the send_failed and enqueue_failed counts
#            not moving; queue_fullest_pct near 0.
#   Watch    queue_fullest_pct climbing: a destination is slower than what
#            arrives, and queue says which exporter; when it reaches 100,
#            everything new for that exporter is dropped.
#   Act      a send_failed count moving: data is being lost, and
#            send_failed_spans, send_failed_metric_points or
#            send_failed_log_records says which exporter (its destination is
#            down, refuses it, or answers too slowly); an enqueue_failed count
#            moving: a queue is full and everything new for it is dropped.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when the OpenTelemetry Collector does
#   not answer (up 0 is the reading); 1 when it answers wrong (a login
#   refused, not HTTP), said on stderr, or curl or awk is missing

set -u

job=exporters
# shellcheck source=/dev/null
. "$(dirname "$0")/_otelcol.sh"
needs curl awk

page '/metrics'
readings <<'T'
_a_sent_spans_count|sum|otelcol_exporter_sent_spans|
_b_sent_spans_count|sum|otelcol_exporter_sent_spans_total|
sent_spans_count|add|_a_sent_spans_count|_b_sent_spans_count
_a_send_failed_spans_count|sum|otelcol_exporter_send_failed_spans|
_b_send_failed_spans_count|sum|otelcol_exporter_send_failed_spans_total|
send_failed_spans_count|add|_a_send_failed_spans_count|_b_send_failed_spans_count
_a_enqueue_failed_spans_count|sum|otelcol_exporter_enqueue_failed_spans|
_b_enqueue_failed_spans_count|sum|otelcol_exporter_enqueue_failed_spans_total|
enqueue_failed_spans_count|add|_a_enqueue_failed_spans_count|_b_enqueue_failed_spans_count
_a_sent_metric_points_count|sum|otelcol_exporter_sent_metric_points|
_b_sent_metric_points_count|sum|otelcol_exporter_sent_metric_points_total|
sent_metric_points_count|add|_a_sent_metric_points_count|_b_sent_metric_points_count
_a_send_failed_metric_points_count|sum|otelcol_exporter_send_failed_metric_points|
_b_send_failed_metric_points_count|sum|otelcol_exporter_send_failed_metric_points_total|
send_failed_metric_points_count|add|_a_send_failed_metric_points_count|_b_send_failed_metric_points_count
_a_enqueue_failed_metric_points_count|sum|otelcol_exporter_enqueue_failed_metric_points|
_b_enqueue_failed_metric_points_count|sum|otelcol_exporter_enqueue_failed_metric_points_total|
enqueue_failed_metric_points_count|add|_a_enqueue_failed_metric_points_count|_b_enqueue_failed_metric_points_count
_a_sent_log_records_count|sum|otelcol_exporter_sent_log_records|
_b_sent_log_records_count|sum|otelcol_exporter_sent_log_records_total|
sent_log_records_count|add|_a_sent_log_records_count|_b_sent_log_records_count
_a_send_failed_log_records_count|sum|otelcol_exporter_send_failed_log_records|
_b_send_failed_log_records_count|sum|otelcol_exporter_send_failed_log_records_total|
send_failed_log_records_count|add|_a_send_failed_log_records_count|_b_send_failed_log_records_count
_a_enqueue_failed_log_records_count|sum|otelcol_exporter_enqueue_failed_log_records|
_b_enqueue_failed_log_records_count|sum|otelcol_exporter_enqueue_failed_log_records_total|
enqueue_failed_log_records_count|add|_a_enqueue_failed_log_records_count|_b_enqueue_failed_log_records_count
send_failed_spans|by?|otelcol_exporter_send_failed_spans||exporter:exporter
send_failed_spans|by?|otelcol_exporter_send_failed_spans_total||exporter:exporter
send_failed_metric_points|by?|otelcol_exporter_send_failed_metric_points||exporter:exporter
send_failed_metric_points|by?|otelcol_exporter_send_failed_metric_points_total||exporter:exporter
send_failed_log_records|by?|otelcol_exporter_send_failed_log_records||exporter:exporter
send_failed_log_records|by?|otelcol_exporter_send_failed_log_records_total||exporter:exporter
queue_size|sum|otelcol_exporter_queue_size
queue_capacity|sum|otelcol_exporter_queue_capacity
queue_fullest_pct|maxpct|otelcol_exporter_queue_size||otelcol_exporter_queue_capacity
queue|by|otelcol_exporter_queue_size||exporter
in_flight|sum|otelcol_exporter_in_flight_requests
T
exit 0
