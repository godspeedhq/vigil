#Requires -Version 5.1

<#
.SYNOPSIS
    tsdb.ps1 - Prometheus' time series database, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports Prometheus' TSDB: the series and chunks in its head, the samples
    appended, what its blocks and its WAL take on disk, how far back its data
    goes, and everything that failed: compactions, WAL writes, truncations and
    checkpoints, reloads of its blocks, and corruptions found. It only reads:
    every request is a GET, and it changes nothing.

    Reads PROMETHEUS_URL (default http://localhost:9090): /metrics, Prometheus'
    page about itself.
    What the scripts share is in _prometheus.ps1, beside this one.

    Metrics:
      up                             1 when Prometheus answered its metrics
                                     page, else 0 (and nothing more is read)
      head_series                    series in memory: the cardinality it
                                     carries now
      head_chunks                    chunks in memory
      series_created_count           series created (a running total): its rate
                                     is churn
      samples_appended_count         samples appended (a running total)
      out_of_order_samples_count     samples refused: out of order (a running
                                     total)
      blocks                         blocks on disk it has loaded
      blocks_bytes                   what they take
      wal_bytes                      what the WAL takes
      head_chunks_bytes              what the head's chunks on disk take
      retention_seconds              how long it keeps data (0: no limit by
                                     time)
      oldest_sample_seconds          how far back its data goes, in seconds
      newest_sample_seconds          seconds since the newest sample it holds:
                                     it is ingesting when this stays small
      compactions_count              compactions run (a running total)
      compactions_failed_count       compactions that failed (a running total)
      wal_corruptions_count          corruptions found in the WAL (a running
                                     total)
      wal_writes_failed_count        WAL writes that failed (a running total)
      wal_truncations_failed_count   WAL truncations that failed (a running
                                     total)
      checkpoints_failed_count       checkpoints that failed (a running total)
      head_truncations_failed_count  head truncations that failed (a running
                                     total)
      reloads_failed_count           reloads of its blocks from disk that failed
                                     (a running total)
      mmap_corruptions_count         corruptions found in the head's chunks on
                                     disk (a running total)
      clean_start                    1 when it started from a clean shutdown; 0
                                     when it had to recover; -1 when it cannot
                                     tell

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  head_series steady or growing slowly; newest_sample_seconds under
               a minute; every failed count at 0.
      Watch    head_series or series_created_count climbing fast (a label with
               too many values: memory follows); wal_bytes growing without end
               (checkpoints or truncations failing); clean_start 0 after a
               restart.
      Act      any of compactions_failed_count, wal_writes_failed_count,
               checkpoints_failed_count, reloads_failed_count moving: the disk
               is full, read-only or failing; wal_corruptions_count or
               mmap_corruptions_count above 0; newest_sample_seconds growing: it
               has stopped ingesting.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when Prometheus does not answer (up 0
      is the reading); 1 when it answers wrong (a login refused, not HTTP), said
      on stderr
#>

$Job = 'tsdb'
. (Join-Path $PSScriptRoot '_prometheus.ps1')

Read-Page '/metrics'
Get-Readings @'
head_series|sum|prometheus_tsdb_head_series
head_chunks|sum|prometheus_tsdb_head_chunks
series_created_count|sum|prometheus_tsdb_head_series_created_total
samples_appended_count|sum|prometheus_tsdb_head_samples_appended_total
out_of_order_samples_count|sum|prometheus_tsdb_out_of_order_samples_total
blocks|sum|prometheus_tsdb_blocks_loaded
blocks_bytes|sum|prometheus_tsdb_storage_blocks_bytes
wal_bytes|sum|prometheus_tsdb_wal_storage_size_bytes
head_chunks_bytes|sum|prometheus_tsdb_head_chunks_storage_size_bytes
retention_seconds|sum|prometheus_tsdb_retention_limit_seconds
oldest_sample_seconds|age|prometheus_tsdb_lowest_timestamp_seconds
newest_sample_seconds|age|prometheus_tsdb_head_max_time_seconds
compactions_count|sum|prometheus_tsdb_compactions_total
compactions_failed_count|sum|prometheus_tsdb_compactions_failed_total
wal_corruptions_count|sum|prometheus_tsdb_wal_corruptions_total
wal_writes_failed_count|sum|prometheus_tsdb_wal_writes_failed_total
wal_truncations_failed_count|sum|prometheus_tsdb_wal_truncations_failed_total
checkpoints_failed_count|sum|prometheus_tsdb_checkpoint_creations_failed_total
head_truncations_failed_count|sum|prometheus_tsdb_head_truncations_failed_total
reloads_failed_count|sum|prometheus_tsdb_reloads_failures_total
mmap_corruptions_count|sum|prometheus_tsdb_mmap_chunk_corruptions_total
clean_start|min|prometheus_tsdb_clean_start
'@
exit 0
