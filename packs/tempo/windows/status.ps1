#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - is Tempo ready, its ring whole, its requests answered, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether Tempo is ready, the members of its ingester ring that are
    active and those that are not, the requests it answered and those that
    failed, and the requests in flight. It only reads: every request is a GET,
    and it changes nothing.

    Reads TEMPO_URL (default http://localhost:3200): /metrics, Tempo's page
    about itself, and /ready.
    What the scripts share is in _tempo.ps1, beside this one.

    Metrics:
      up                   1 when Tempo answered its metrics page, else 0 (and
                           nothing more is read)
      ready                1 when Tempo says it is ready (/ready answers 200),
                           else 0: it is starting, or an ingester is not in its
                           ring
      version              always 1, tagged version=<its version>
      uptime_seconds       seconds since it started
      ingesters_active     ingesters active in the ring
      ingesters_unhealthy  ingesters in the ring that stopped sending heartbeats
      ring_unhealthy       members of any ring that stopped sending heartbeats
      ring_not_active      members of any ring joining, leaving or pending
      requests_count       requests answered (a running total)
      requests_4xx_count   of those, answered 4xx: a search that does not parse,
                           a trace that is not there, a limit reached (a running
                           total)
      requests_5xx_count   answered 5xx: Tempo failed (a running total)
      inflight_requests    requests in flight now

    Example output (the rest are in the same form):
      metric up 1
      metric ready 1
      metric version 1 version=v2.10.10
      metric uptime_seconds 305
      metric ingesters_active 1
      metric ingesters_unhealthy 0
      metric ring_unhealthy 0
      metric ring_not_active 0
      metric requests_count 911
      metric requests_4xx_count 72
      metric requests_5xx_count 8
      metric inflight_requests 21

    Reading the results (starting points: tune them to your own):
      Healthy  up 1; ready 1; ingesters_unhealthy and ring_unhealthy 0;
               requests_5xx_count not moving.
      Watch    requests_4xx_count climbing; ring_not_active above 0 outside a
               rollout.
      Act      up 0 or ready 0; ingesters_unhealthy above 0: spans may be
               refused and recent traces missing; requests_5xx_count moving.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when Tempo does not answer (up 0 is the
      reading); 1 when it answers wrong (a login refused, not HTTP), said on
      stderr
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_tempo.ps1')

Read-Page '/metrics'
Test-Answers 'ready' '/ready'
Get-Readings @'
version|info|tempo_build_info||version:version
uptime_seconds|age|process_start_time_seconds
ingesters_active|sum|tempo_ring_members|name=ingester,state=ACTIVE
ingesters_unhealthy|sum|tempo_ring_members|name=ingester,state=Unhealthy
ring_unhealthy|sum|tempo_ring_members|state=Unhealthy
ring_not_active|sum|tempo_ring_members|state~^[JLP]
requests_count|sum|tempo_request_duration_seconds_count
requests_4xx_count|sum|tempo_request_duration_seconds_count|status_code~^4
requests_5xx_count|sum|tempo_request_duration_seconds_count|status_code~^5
inflight_requests|sum|tempo_inflight_requests
'@
exit 0
