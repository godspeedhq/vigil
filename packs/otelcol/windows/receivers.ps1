#Requires -Version 5.1

<#
.SYNOPSIS
    receivers.ps1 - what the Collector's receivers accept and refuse, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports what the Collector's receivers accepted, refused and failed to
    process, for spans, metric points and log records, and the refusals for each
    receiver. A receiver refuses what the pipeline behind it will not take: the
    memory limiter is over its limit, or an exporter with no queue failed. It
    only reads: every request is a GET, and it changes nothing.

    Reads OTELCOL_URL (default http://localhost:8888): /metrics, the Collector's
    page about itself.
    What the scripts share is in _otelcol.ps1, beside this one.

    Metrics:
      up                               1 when the OpenTelemetry Collector
                                       answered its metrics page, else 0 (and
                                       nothing more is read)
      accepted_spans_count             spans its receivers took (a running
                                       total)
      refused_spans_count              spans its receivers refused: the pipeline
                                       behind them would not take them (a
                                       running total)
      failed_spans_count               spans its receivers could not process: an
                                       error of its own (a running total)
      accepted_metric_points_count     metric points its receivers took (a
                                       running total)
      refused_metric_points_count      metric points its receivers refused: the
                                       pipeline behind them would not take them
                                       (a running total)
      failed_metric_points_count       metric points its receivers could not
                                       process: an error of its own (a running
                                       total)
      accepted_log_records_count       log records its receivers took (a running
                                       total)
      refused_log_records_count        log records its receivers refused: the
                                       pipeline behind them would not take them
                                       (a running total)
      failed_log_records_count         log records its receivers could not
                                       process: an error of its own (a running
                                       total)
      refused_spans                    spans refused, for each receiver, tagged
                                       receiver=<its name>
      refused_spans_not_shown          how many more there were than the 20
                                       shown
      refused_metric_points            metric points refused, for each receiver,
                                       tagged receiver=<its name>
      refused_metric_points_not_shown  how many more there were than the 20
                                       shown
      refused_log_records              log records refused, for each receiver,
                                       tagged receiver=<its name>
      refused_log_records_not_shown    how many more there were than the 20
                                       shown

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  the accepted counts moving; the refused and failed counts not
               moving.
      Watch    an accepted count that stops moving while its senders run (they
               cannot reach the Collector).
      Act      a refused count moving: senders are told to retry, and lose data
               when they give up; refused_spans, refused_metric_points or
               refused_log_records says which receiver, and the exporters job
               why (a queue that is full, sends that fail), or the memory
               limiter is refusing.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when the OpenTelemetry Collector does
      not answer (up 0 is the reading); 1 when it answers wrong (a login
      refused, not HTTP), said on stderr
#>

$Job = 'receivers'
. (Join-Path $PSScriptRoot '_otelcol.ps1')

Read-Page '/metrics'
Get-Readings @'
_a_accepted_spans_count|sum|otelcol_receiver_accepted_spans|
_b_accepted_spans_count|sum|otelcol_receiver_accepted_spans_total|
accepted_spans_count|add|_a_accepted_spans_count|_b_accepted_spans_count
_a_refused_spans_count|sum|otelcol_receiver_refused_spans|
_b_refused_spans_count|sum|otelcol_receiver_refused_spans_total|
refused_spans_count|add|_a_refused_spans_count|_b_refused_spans_count
_a_failed_spans_count|sum|otelcol_receiver_failed_spans|
_b_failed_spans_count|sum|otelcol_receiver_failed_spans_total|
failed_spans_count|add|_a_failed_spans_count|_b_failed_spans_count
_a_accepted_metric_points_count|sum|otelcol_receiver_accepted_metric_points|
_b_accepted_metric_points_count|sum|otelcol_receiver_accepted_metric_points_total|
accepted_metric_points_count|add|_a_accepted_metric_points_count|_b_accepted_metric_points_count
_a_refused_metric_points_count|sum|otelcol_receiver_refused_metric_points|
_b_refused_metric_points_count|sum|otelcol_receiver_refused_metric_points_total|
refused_metric_points_count|add|_a_refused_metric_points_count|_b_refused_metric_points_count
_a_failed_metric_points_count|sum|otelcol_receiver_failed_metric_points|
_b_failed_metric_points_count|sum|otelcol_receiver_failed_metric_points_total|
failed_metric_points_count|add|_a_failed_metric_points_count|_b_failed_metric_points_count
_a_accepted_log_records_count|sum|otelcol_receiver_accepted_log_records|
_b_accepted_log_records_count|sum|otelcol_receiver_accepted_log_records_total|
accepted_log_records_count|add|_a_accepted_log_records_count|_b_accepted_log_records_count
_a_refused_log_records_count|sum|otelcol_receiver_refused_log_records|
_b_refused_log_records_count|sum|otelcol_receiver_refused_log_records_total|
refused_log_records_count|add|_a_refused_log_records_count|_b_refused_log_records_count
_a_failed_log_records_count|sum|otelcol_receiver_failed_log_records|
_b_failed_log_records_count|sum|otelcol_receiver_failed_log_records_total|
failed_log_records_count|add|_a_failed_log_records_count|_b_failed_log_records_count
refused_spans|by?|otelcol_receiver_refused_spans||receiver:receiver
refused_spans|by?|otelcol_receiver_refused_spans_total||receiver:receiver
refused_metric_points|by?|otelcol_receiver_refused_metric_points||receiver:receiver
refused_metric_points|by?|otelcol_receiver_refused_metric_points_total||receiver:receiver
refused_log_records|by?|otelcol_receiver_refused_log_records||receiver:receiver
refused_log_records|by?|otelcol_receiver_refused_log_records_total||receiver:receiver
'@
exit 0
