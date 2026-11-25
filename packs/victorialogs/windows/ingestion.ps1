#Requires -Version 5.1

<#
.SYNOPSIS
    ingestion.ps1 - what VictoriaLogs ingests, and what it drops, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the log entries and bytes VictoriaLogs ingests for each protocol
    (JSON lines, OTLP, Loki, Elasticsearch bulk, syslog and the rest), the
    entries it dropped and why (a timestamp older than the retention or too far
    ahead, too many fields), the lines too long to take, the streams created,
    and what it holds. It only reads: every request is a GET, and it changes
    nothing.

    Reads VICTORIALOGS_URL (default http://localhost:9428): /metrics,
    VictoriaLogs' page about itself.
    What the scripts share is in _victorialogs.ps1, beside this one.

    Metrics:
      up                       1 when VictoriaLogs answered its metrics page,
                               else 0 (and nothing more is read)
      rows_ingested_count      log entries ingested (a running total)
      rows_ingested            the same, for each protocol, tagged
                               type=<jsonline, opentelemetry_protobuf, loki,
                               ...>
      rows_ingested_not_shown  how many more there were than the 20 shown
      bytes_ingested_count     bytes ingested (a running total)
      rows_dropped_count       entries dropped (a running total)
      rows_dropped             the same, for each reason, tagged
                               reason=<too_small_timestamp: older than the
                               retention; too_big_timestamp: too far ahead;
                               too_many_fields; debug>
      rows_dropped_not_shown   how many more there were than the 20 shown
      too_long_lines_count     lines skipped: longer than
                               -insert.maxLineSizeBytes (a running total)
      ingest_errors_count      errors reading what a listener was sent, syslog
                               among them (a running total)
      streams_created_count    log streams created (a running total): its rate
                               is churn
      rows                     entries it holds
      pending_rows             entries received and not yet written to a part
      partitions               daily partitions on disk
      active_merges            merges of parts running now
      compression_ratio        what its data would take uncompressed, over what
                               it takes

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  rows_ingested_count moving; rows_dropped_count and
               too_long_lines_count not moving.
      Watch    streams_created_count climbing fast (a stream field with too many
               values: memory and disk follow); pending_rows growing.
      Act      rows_ingested_count not moving: nothing is arriving;
               rows_dropped_count moving: rows_dropped says why
               (too_small_timestamp: a shipper replaying old logs, or a clock
               far behind; too_big_timestamp: a clock ahead);
               too_long_lines_count moving: lines are being thrown away whole.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when VictoriaLogs does not answer (up 0
      is the reading); 1 when it answers wrong (a login refused, not HTTP), said
      on stderr
#>

$Job = 'ingestion'
. (Join-Path $PSScriptRoot '_victorialogs.ps1')

Read-Page '/metrics'
Get-Readings @'
rows_ingested_count|sum|vl_rows_ingested_total
rows_ingested|by|vl_rows_ingested_total||type
bytes_ingested_count|sum|vl_bytes_ingested_total
rows_dropped_count|sum|vl_rows_dropped_total
rows_dropped|by|vl_rows_dropped_total||reason
too_long_lines_count|sum|vl_too_long_lines_skipped_total
ingest_errors_count|sum|vl_errors_total
streams_created_count|sum|vl_streams_created_total
rows|sum|vl_storage_rows
pending_rows|sum|vl_pending_rows
partitions|sum|vl_partitions
active_merges|sum|vl_active_merges
_comp|sum|vl_compressed_data_size_bytes
_raw|sum|vl_uncompressed_data_size_bytes
compression_ratio|div|_raw|_comp
'@
exit 0
