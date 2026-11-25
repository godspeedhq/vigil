#Requires -Version 5.1

<#
.SYNOPSIS
    ingestion.ps1 - what Mimir receives, and what it discards, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the samples Mimir's distributor received, the samples it discarded
    and why (a tenant's series limit, its rate limit, samples too old or out of
    order, labels it does not accept), the series and tenants its ingester holds
    in memory, the samples appended and those that failed, and the pushes in
    flight. It only reads: every request is a GET, and it changes nothing.

    Reads MIMIR_URL (default http://localhost:9009): /metrics, Mimir's page
    about itself.
    What the scripts share is in _mimir.ps1, beside this one.

    Metrics:
      up                           1 when Mimir answered its metrics page, else
                                   0 (and nothing more is read)
      samples_in_count             samples sent to the distributor, before any
                                   check (a running total)
      samples_received_count       samples it accepted (a running total)
      discarded_count              samples discarded (a running total)
      discarded                    the same, for each reason, tagged
                                   reason=<per_user_series_limit,
                                   per_metric_series_limit, rate_limited,
                                   sample-out-of-order, sample-too-old,
                                   label_invalid, metric_name_invalid ...>
      discarded_not_shown          how many more there were than the 20 shown
      series                       series the ingester holds in memory
      tenants                      tenants it holds series for
      active_series                series that received a sample lately
      ingested_samples_count       samples the ingester appended (a running
                                   total)
      ingested_failures_count      samples it could not append (a running total)
      append_failures_count        writes an ingester refused or did not answer
                                   (a running total)
      pushes_in_flight             pushes the distributor is handling now
      out_of_order_appended_count  out-of-order samples it took, where that is
                                   allowed (a running total)

    Example output (the rest are in the same form):
      metric up 1
      metric samples_in_count 906600
      metric samples_received_count 887436
      metric discarded_count 892600
      metric discarded 873436 reason=per_user_series_limit
      metric discarded 15315 reason=metric_name_invalid
      metric discarded 3848 reason=label_invalid
      metric discarded 1 reason=sample_duplicate_timestamp
      metric discarded_not_shown 0
      metric series 200
      metric tenants 1
      metric active_series 200
      metric ingested_samples_count 12000
      metric ingested_failures_count 873436
      metric append_failures_count 0
      metric pushes_in_flight 1
      metric out_of_order_appended_count 0

    Reading the results (starting points: tune them to your own):
      Healthy  samples_received_count moving; discarded_count not moving;
               ingested_failures_count at 0.
      Watch    series climbing towards a tenant's limit; ingested_failures_count
               moving a little (out-of-order or duplicate samples from a
               sender).
      Act      discarded_count moving: discarded says why
               (per_user_series_limit: the tenant is at its limit and new series
               are lost; rate_limited: it sends faster than it may;
               sample-too-old; label_invalid); append_failures_count moving:
               ingesters are refusing or missing; samples_received_count not
               moving: nothing arrives.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when Mimir does not answer (up 0 is the
      reading); 1 when it answers wrong (a login refused, not HTTP), said on
      stderr
#>

$Job = 'ingestion'
. (Join-Path $PSScriptRoot '_mimir.ps1')

Read-Page '/metrics'
Get-Readings @'
samples_in_count|sum|cortex_distributor_samples_in_total
samples_received_count|sum|cortex_distributor_received_samples_total
discarded_count|sum|cortex_discarded_samples_total
discarded|by|cortex_discarded_samples_total||reason
series|sum|cortex_ingester_memory_series
tenants|sum|cortex_ingester_memory_users
active_series|sum|cortex_ingester_active_series
ingested_samples_count|sum|cortex_ingester_ingested_samples_total
ingested_failures_count|sum|cortex_ingester_ingested_samples_failures_total
append_failures_count|sum|cortex_distributor_ingester_append_failures_total
pushes_in_flight|sum|cortex_distributor_inflight_push_requests
out_of_order_appended_count|sum|cortex_ingester_tsdb_out_of_order_samples_appended_total
'@
exit 0
