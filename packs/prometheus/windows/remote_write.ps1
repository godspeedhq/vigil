#Requires -Version 5.1

<#
.SYNOPSIS
    remote_write.ps1 - Prometheus' remote write, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports Prometheus' remote write queues: the samples sent, failed, retried
    and dropped, those waiting (for each remote), the shards in use against the
    most allowed, and how far the slowest remote is behind what Prometheus has
    ingested. It reports zeros where no remote write is configured. It only
    reads: every request is a GET, and it changes nothing.

    Reads PROMETHEUS_URL (default http://localhost:9090): /metrics, Prometheus'
    page about itself.
    What the scripts share is in _prometheus.ps1, beside this one.

    Metrics:
      up                        1 when Prometheus answered its metrics page,
                                else 0 (and nothing more is read)
      remotes                   remote write destinations configured
      samples_sent_count        samples sent (a running total)
      samples_failed_count      samples a remote refused for good: they are lost
                                to it (a running total)
      samples_failed            the same, for each remote, tagged remote=<its
                                name>
      samples_failed_not_shown  how many more there were than the 20 shown
      samples_retried_count     samples sent again after a failure that may
                                pass: the remote was down or slow (a running
                                total)
      samples_dropped_count     samples dropped before sending: relabelled away,
                                or too old (a running total)
      samples_pending           samples waiting in the queues
      pending                   the same, for each remote, tagged remote
      pending_not_shown         how many more there were than the 20 shown
      shards                    shards sending now
      shards_max                the most it may use
      shards_desired            how many it works out it needs: above
                                shards_max, it cannot keep up
      behind_seconds            how far the slowest remote that has sent
                                anything is behind the newest sample ingested,
                                in seconds
      remotes_never_sent        remotes that have not taken a single sample
                                since Prometheus started

    Example output (the rest are in the same form):
      metric up 1
      metric remotes 3
      metric samples_sent_count 1802600
      metric samples_failed_count 898000
      metric samples_failed 898000 remote=mimir
      metric samples_failed 0 remote=dead
      metric samples_failed 0 remote=victoriametrics
      metric samples_failed_not_shown 0
      metric samples_retried_count 6500
      metric samples_dropped_count 0
      metric samples_pending 4593
      metric pending 1947 remote=mimir
      metric pending 1947 remote=victoriametrics
      metric pending 699 remote=dead
      metric pending_not_shown 0
      metric shards 3
      metric shards_max 102
      metric shards_desired 1.044234
      metric behind_seconds 1
      metric remotes_never_sent 1

    Reading the results (starting points: tune them to your own):
      Healthy  samples_failed_count not moving; behind_seconds under a minute;
               samples_pending small and steady.
      Watch    samples_retried_count climbing (a remote that is slow or
               flapping); shards near shards_max.
      Act      behind_seconds growing: a remote is down or too slow, and pending
               says which; remotes_never_sent above 0 once Prometheus has run a
               few minutes: a remote that was never there; samples_failed_count
               moving: samples_failed says which remote refuses them (a limit
               reached there, or samples it rejects); shards_desired above
               shards_max.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when Prometheus does not answer (up 0
      is the reading); 1 when it answers wrong (a login refused, not HTTP), said
      on stderr
#>

$Job = 'remote_write'
. (Join-Path $PSScriptRoot '_prometheus.ps1')

Read-Page '/metrics'
Get-Readings @'
remotes|count|prometheus_remote_storage_samples_pending
samples_sent_count|sum|prometheus_remote_storage_samples_total
samples_failed_count|sum|prometheus_remote_storage_samples_failed_total
samples_failed|by|prometheus_remote_storage_samples_failed_total||remote_name:remote
samples_retried_count|sum|prometheus_remote_storage_samples_retried_total
samples_dropped_count|sum|prometheus_remote_storage_samples_dropped_total
samples_pending|sum|prometheus_remote_storage_samples_pending
pending|by|prometheus_remote_storage_samples_pending||remote_name:remote
shards|sum|prometheus_remote_storage_shards
shards_max|sum|prometheus_remote_storage_shards_max
shards_desired|sum|prometheus_remote_storage_shards_desired
_in|max|prometheus_remote_storage_highest_timestamp_in_seconds
_sent|minpos|prometheus_remote_storage_queue_highest_sent_timestamp_seconds
behind_seconds|sub|_in|_sent
remotes_never_sent|count|prometheus_remote_storage_queue_highest_sent_timestamp_seconds||=0
'@
exit 0
