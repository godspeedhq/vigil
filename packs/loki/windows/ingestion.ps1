#Requires -Version 5.1

<#
.SYNOPSIS
    ingestion.ps1 - what Loki receives, and what it discards, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the log lines and bytes Loki's distributor received, the entries it
    discarded and why (too old, a line too long, a rate limit, too many
    streams), the streams and chunks its ingester holds in memory, the chunks
    flushed to storage and the flushes that failed, and the WAL's failures. It
    only reads: every request is a GET, and it changes nothing.

    Reads LOKI_URL (default http://localhost:3100): /metrics, Loki's page about
    itself.
    What the scripts share is in _loki.ps1, beside this one.

    Metrics:
      up                        1 when Loki answered its metrics page, else 0
                                (and nothing more is read)
      lines_received_count      log lines received (a running total)
      bytes_received_count      bytes received (a running total)
      discarded_count           entries discarded (a running total)
      discarded                 the same, for each reason, tagged
                                reason=<greater_than_max_sample_age,
                                line_too_long, rate_limited,
                                per_stream_rate_limit, stream_limit,
                                too_far_behind ...>
      discarded_not_shown       how many more there were than the 20 shown
      discarded_bytes_count     bytes discarded (a running total)
      streams                   streams the ingester holds in memory
      chunks                    chunks it holds in memory
      streams_created_count     streams created (a running total): its rate is
                                churn
      chunks_flushed_count      chunks flushed to storage (a running total)
      flush_failures_count      flushes that failed (a running total)
      flush_queue               chunks waiting to be flushed
      wal_disk_full_count       WAL writes refused: the WAL's disk is full (a
                                running total)
      wal_corruptions_count     corruptions found replaying the WAL (a running
                                total)
      checkpoints_failed_count  WAL checkpoints that failed (a running total)
      append_failures_count     writes an ingester refused or did not answer (a
                                running total)

    Example output (the rest are in the same form):
      metric up 1
      metric lines_received_count 1416
      metric bytes_received_count 123678
      metric discarded_count 144
      metric discarded 72 reason=greater_than_max_sample_age
      metric discarded 72 reason=line_too_long
      metric discarded_not_shown 0
      metric discarded_bytes_count 29511
      metric streams 2
      metric chunks 3
      metric streams_created_count 2
      metric chunks_flushed_count 6
      metric flush_failures_count 0
      metric flush_queue 0
      metric wal_disk_full_count 0
      metric wal_corruptions_count 0
      metric checkpoints_failed_count 0
      metric append_failures_count 0

    Reading the results (starting points: tune them to your own):
      Healthy  lines_received_count moving; discarded_count not moving;
               flush_failures_count and the WAL counts at 0.
      Watch    streams or streams_created_count climbing fast (a label with too
               many values); flush_queue growing (storage slower than
               ingestion).
      Act      discarded_count moving: discarded says why (rate_limited and
               stream_limit: raise the tenant's limits or cut what is sent;
               greater_than_max_sample_age: a shipper replaying, or a clock
               behind; line_too_long); flush_failures_count moving: chunks are
               not reaching storage, and an ingester restart would lose them;
               wal_disk_full_count or append_failures_count moving;
               lines_received_count not moving: nothing arrives.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when Loki does not answer (up 0 is the
      reading); 1 when it answers wrong (a login refused, not HTTP), said on
      stderr
#>

$Job = 'ingestion'
. (Join-Path $PSScriptRoot '_loki.ps1')

Read-Page '/metrics'
Get-Readings @'
lines_received_count|sum|loki_distributor_lines_received_total
bytes_received_count|sum|loki_distributor_bytes_received_total
discarded_count|sum|loki_discarded_samples_total
discarded|by|loki_discarded_samples_total||reason
discarded_bytes_count|sum|loki_discarded_bytes_total
streams|sum|loki_ingester_memory_streams
chunks|sum|loki_ingester_memory_chunks
streams_created_count|sum|loki_ingester_streams_created_total
chunks_flushed_count|sum|loki_ingester_chunks_flushed_total
flush_failures_count|sum|loki_ingester_chunks_flush_failures_total
flush_queue|sum|loki_ingester_flush_queue_length
wal_disk_full_count|sum|loki_ingester_wal_disk_full_failures_total
wal_corruptions_count|sum|loki_ingester_wal_corruptions_total
checkpoints_failed_count|sum|loki_ingester_checkpoint_creations_failed_total
append_failures_count|sum|loki_distributor_ingester_append_failures_total
'@
exit 0
