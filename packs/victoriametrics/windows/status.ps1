#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - is VictoriaMetrics up, writable and answering queries, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether VictoriaMetrics answers, whether its storage has gone
    read-only for lack of disk, the disk space left and what its data takes, the
    requests it answered and those that failed (for each path), slow queries,
    and how close its queries are to the limit on running at once. It only
    reads: every request is a GET, and it changes nothing.

    Reads VICTORIAMETRICS_URL (default http://localhost:8428): /metrics,
    VictoriaMetrics' page about itself, and /health.
    What the scripts share is in _victoriametrics.ps1, beside this one.

    Metrics:
      up                           1 when VictoriaMetrics answered its metrics
                                   page, else 0 (and nothing more is read)
      healthy                      1 when /health answers 200, else 0
      version                      always 1, tagged version=<its version>
      uptime_seconds               seconds since it started
      read_only                    1 when the storage refuses writes: the disk
                                   has less free than
                                   -storage.minFreeDiskSpaceBytes; else 0
      free_disk_bytes              free space on the disk its data is on
      data_bytes                   what its data and index take on disk
      http_requests_count          requests answered (a running total)
      http_errors_count            requests that failed (a running total)
      http_errors                  the same, for each path, tagged path=<it>
      http_errors_not_shown        how many more there were than the 20 shown
      slow_queries_count           queries slower than
                                   -search.logSlowQueryDuration (a running
                                   total)
      selects                      queries running now
      selects_capacity             the most it runs at once
                                   (-search.maxConcurrentRequests)
      selects_pct                  queries running, as a percentage of that
      selects_limit_reached_count  times a query had to wait for a place (a
                                   running total)
      selects_limit_timeout_count  queries turned away after waiting
                                   -search.maxQueueDuration (a running total)
      errors_logged_count          errors it logged (a running total)
      panics_logged_count          panics it logged (a running total)

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  up 1; healthy 1; read_only 0; http_errors_count and
               errors_logged_count not moving.
      Watch    free_disk_bytes falling towards its limit; selects_pct near 100
               or selects_limit_reached_count moving (queries queue);
               slow_queries_count climbing.
      Act      up 0 or healthy 0; read_only 1: it accepts no more samples until
               space is freed, and everything sent is lost or queued at the
               sender; selects_limit_timeout_count moving: dashboards and rules
               get errors; http_errors_count moving on a write path (http_errors
               says which).

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when VictoriaMetrics does not answer
      (up 0 is the reading); 1 when it answers wrong (a login refused, not
      HTTP), said on stderr
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_victoriametrics.ps1')

Read-Page '/metrics'
Test-Answers 'healthy' '/health'
Get-Readings @'
version|info|vm_app_version||short_version:version
uptime_seconds|max|vm_app_uptime_seconds
read_only|max|vm_storage_is_read_only
free_disk_bytes|min|vm_free_disk_space_bytes
data_bytes|sum|vm_data_size_bytes
http_requests_count|sum|vm_http_requests_total
http_errors_count|sum|vm_http_request_errors_total
http_errors|by|vm_http_request_errors_total||path
slow_queries_count|sum|vm_slow_queries_total
selects|sum|vm_concurrent_select_current
selects_capacity|sum|vm_concurrent_select_capacity
selects_pct|pct|selects|selects_capacity
selects_limit_reached_count|sum|vm_concurrent_select_limit_reached_total
selects_limit_timeout_count|sum|vm_concurrent_select_limit_timeout_total
errors_logged_count|sum|vm_log_messages_total|level=error
panics_logged_count|sum|vm_log_messages_total|level=panic
'@
exit 0
