#Requires -Version 5.1

<#
.SYNOPSIS
    ingestion.ps1 - what VictoriaMetrics ingests, and what it turns away, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the rows VictoriaMetrics ingests for each protocol (remote write,
    scraping, InfluxDB, OTLP and the rest), the rows it refused or ignored and
    why, the new series created, the slow inserts that say memory is short for
    the series it holds, its insert concurrency against its limit, the rows
    dropped by a cardinality limit, and what it holds. It only reads: every
    request is a GET, and it changes nothing.

    Reads VICTORIAMETRICS_URL (default http://localhost:8428): /metrics,
    VictoriaMetrics' page about itself.
    What the scripts share is in _victoriametrics.ps1, beside this one.

    Metrics:
      up                           1 when VictoriaMetrics answered its metrics
                                   page, else 0 (and nothing more is read)
      rows_inserted_count          rows (samples) ingested (a running total)
      rows_inserted                the same, for each protocol, tagged
                                   type=<promremotewrite, promscrape, influx,
                                   ...>
      rows_inserted_not_shown      how many more there were than the 20 shown
      rows_invalid_count           rows that could not be parsed (a running
                                   total)
      rows_ignored_count           rows ignored: a timestamp outside the
                                   retention, a value that is not a number, a
                                   label too long (a running total)
      rows_ignored                 the same, for each reason, tagged reason
      rows_ignored_not_shown       how many more there were than the 20 shown
      new_series_count             series created (a running total): its rate is
                                   churn
      slow_row_inserts_count       rows inserted the slow way, their series not
                                   in the cache (a running total): a rising
                                   share means too little memory for the active
                                   series
      slow_inserts_pct             slow inserts, as a percentage of all rows
                                   since it started
      inserts                      inserts running now
      inserts_capacity             the most it runs at once
                                   (-maxConcurrentInserts)
      inserts_limit_reached_count  times an insert had to wait (a running total)
      inserts_limit_timeout_count  inserts turned away after waiting
                                   -insert.maxQueueDuration (a running total)
      series_limit_dropped_count   rows dropped by -storage.maxHourlySeries (a
                                   running total)
      daily_limit_dropped_count    rows dropped by -storage.maxDailySeries (a
                                   running total)
      rows                         rows it holds
      pending_rows                 rows received and not yet written to a part
      active_merges                merges of parts running now

    Example output (the rest are in the same form):
      metric up 1
      metric rows_inserted_count 987055
      metric rows_inserted 904000 type=promremotewrite
      metric rows_inserted 82455 type=promscrape
      metric rows_inserted 600 type=opentelemetry
      metric rows_inserted 0 type=csvimport
      metric rows_inserted 0 type=datadogsketches
      metric rows_inserted_not_shown 0
      metric rows_invalid_count 0
      metric rows_ignored_count 0
      metric rows_ignored 0 reason=too_long_label_name
      metric rows_ignored 0 reason=too_long_label_value
      metric rows_ignored_not_shown 0
      metric new_series_count 17237
      metric slow_row_inserts_count 17237
      metric slow_inserts_pct 1.75
      metric inserts 0
      metric inserts_capacity 8
      metric inserts_limit_reached_count 0
      metric inserts_limit_timeout_count 0
      metric series_limit_dropped_count 0
      metric daily_limit_dropped_count 0
      metric rows 975261
      metric pending_rows 6003
      metric active_merges 0

    Reading the results (starting points: tune them to your own):
      Healthy  rows_inserted_count moving; rows_invalid_count,
               rows_ignored_count and the limit counts not moving.
      Watch    slow_inserts_pct above a few percent (more active series than the
               memory holds: raise memory or cut churn); new_series_count
               climbing fast; inserts_limit_reached_count moving.
      Act      rows_inserted_count not moving: nothing is arriving;
               rows_ignored_count or rows_invalid_count moving (rows_ignored
               says why); series_limit_dropped_count or
               daily_limit_dropped_count moving: a cardinality limit is
               discarding data; inserts_limit_timeout_count moving: senders are
               being turned away.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when VictoriaMetrics does not answer
      (up 0 is the reading); 1 when it answers wrong (a login refused, not
      HTTP), said on stderr
#>

$Job = 'ingestion'
. (Join-Path $PSScriptRoot '_victoriametrics.ps1')

Read-Page '/metrics'
Get-Readings @'
rows_inserted_count|sum|vm_rows_inserted_total
rows_inserted|by|vm_rows_inserted_total||type
rows_invalid_count|sum|vm_rows_invalid_total
rows_ignored_count|sum|vm_rows_ignored_total
rows_ignored|by|vm_rows_ignored_total||reason
new_series_count|sum|vm_new_timeseries_created_total
slow_row_inserts_count|sum|vm_slow_row_inserts_total
slow_inserts_pct|pct|slow_row_inserts_count|rows_inserted_count
inserts|sum|vm_concurrent_insert_current
inserts_capacity|sum|vm_concurrent_insert_capacity
inserts_limit_reached_count|sum|vm_concurrent_insert_limit_reached_total
inserts_limit_timeout_count|sum|vm_concurrent_insert_limit_timeout_total
series_limit_dropped_count|sum|vm_hourly_series_limit_rows_dropped_total
daily_limit_dropped_count|sum|vm_daily_series_limit_rows_dropped_total
rows|sum|vm_rows|type~^storage
pending_rows|sum|vm_pending_rows
active_merges|sum|vm_active_merges
'@
exit 0
