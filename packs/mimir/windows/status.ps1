#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - is Mimir ready, its rings whole, its requests answered, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether Mimir is ready, the members of its rings that are active and
    those that are not (ingesters above all: a write needs a quorum of them),
    the requests it answered and those that failed, the requests in flight, and
    those it refused to protect itself. It only reads: every request is a GET,
    and it changes nothing.

    Reads MIMIR_URL (default http://localhost:9009): /metrics, Mimir's page
    about itself, and /ready.
    What the scripts share is in _mimir.ps1, beside this one.

    Metrics:
      up                          1 when Mimir answered its metrics page, else 0
                                  (and nothing more is read)
      ready                       1 when Mimir says it is ready (/ready answers
                                  200), else 0: it is starting, or a ring it
                                  needs is not whole
      version                     always 1, tagged version=<its version>
      uptime_seconds              seconds since it started
      ingesters_active            ingesters active in the ring
      ingesters_unhealthy         ingesters in the ring that stopped sending
                                  heartbeats
      store_gateways_active       store-gateways active in their ring
      compactors_active           compactors active in their ring
      ring_unhealthy              members of any ring that stopped sending
                                  heartbeats
      ring_not_active             members of any ring joining, leaving or
                                  pending
      requests_count              requests answered (a running total)
      requests_4xx_count          of those, answered 4xx: a query that does not
                                  parse, samples refused, a limit reached (a
                                  running total)
      requests_5xx_count          answered 5xx: Mimir failed (a running total)
      inflight_requests           requests in flight now
      distributor_rejected_count  requests a distributor refused: one of its
                                  instance limits was reached (a running total)
      ingester_rejected_count     requests an ingester refused: one of its
                                  instance limits was reached (a running total)
      querier_rejected_count      queries refused (a running total)

    Example output (the rest are in the same form):
      metric up 1
      metric ready 1
      metric version 1 version=3.2.6
      metric uptime_seconds 308
      metric ingesters_active 1
      metric ingesters_unhealthy 0
      metric store_gateways_active 1
      metric compactors_active 1
      metric ring_unhealthy 0
      metric ring_not_active 0
      metric requests_count 1440
      metric requests_4xx_count 530
      metric requests_5xx_count 8
      metric inflight_requests 14
      metric distributor_rejected_count 0
      metric ingester_rejected_count 0
      metric querier_rejected_count 0

    Reading the results (starting points: tune them to your own):
      Healthy  up 1; ready 1; ingesters_unhealthy and ring_unhealthy 0;
               requests_5xx_count not moving.
      Watch    requests_4xx_count climbing (the ingestion job says whether
               samples are being discarded); ring_not_active above 0 outside a
               rollout; inflight_requests climbing.
      Act      up 0 or ready 0; ingesters_unhealthy above 0: with a replication
               factor of 3, a second one lost stops writes; requests_5xx_count
               moving; distributor_rejected_count or ingester_rejected_count
               moving: Mimir is turning work away to stay up.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when Mimir does not answer (up 0 is the
      reading); 1 when it answers wrong (a login refused, not HTTP), said on
      stderr
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_mimir.ps1')

Read-Page '/metrics'
Test-Answers 'ready' '/ready'
Get-Readings @'
version|info|mimir_build_info||version:version
uptime_seconds|age|process_start_time_seconds
ingesters_active|sum|cortex_ring_members|name=ingester,state=ACTIVE
ingesters_unhealthy|sum|cortex_ring_members|name=ingester,state=Unhealthy
store_gateways_active|sum|cortex_ring_members|name=store-gateway,state=ACTIVE
compactors_active|sum|cortex_ring_members|name=compactor,state=ACTIVE
ring_unhealthy|sum|cortex_ring_members|state=Unhealthy
ring_not_active|sum|cortex_ring_members|state~^[JLP]
requests_count|sum|cortex_request_duration_seconds_count
requests_4xx_count|sum|cortex_request_duration_seconds_count|status_code~^4
requests_5xx_count|sum|cortex_request_duration_seconds_count|status_code~^5
inflight_requests|sum|cortex_inflight_requests
distributor_rejected_count|sum|cortex_distributor_instance_rejected_requests_total
ingester_rejected_count|sum|cortex_ingester_instance_rejected_requests_total
querier_rejected_count|sum|cortex_querier_queries_rejected_total
'@
exit 0
