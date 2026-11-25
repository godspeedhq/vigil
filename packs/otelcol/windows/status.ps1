#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - is the Collector up, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether the Collector answers, its version, how long it has run, and
    the memory it holds. It only reads: every request is a GET, and it changes
    nothing.

    Reads OTELCOL_URL (default http://localhost:8888): /metrics, the Collector's
    page about itself.
    What the scripts share is in _otelcol.ps1, beside this one.

    Metrics:
      up                1 when the OpenTelemetry Collector answered its metrics
                        page, else 0 (and nothing more is read)
      version           always 1, tagged version=<its version> and name=<the
                        distribution: otelcol, otelcol-contrib ...>
      uptime_seconds    seconds since it started
      memory_rss_bytes  memory it holds (resident)
      heap_bytes        of that, its heap in use

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  up 1; uptime_seconds growing from one run to the next.
      Watch    memory_rss_bytes climbing towards the memory_limiter's limit (it
               will start refusing data).
      Act      up 0: nothing it receives goes anywhere; uptime_seconds going
               back to a small number again and again: it is restarting (out of
               memory, or a configuration it cannot start with).

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when the OpenTelemetry Collector does
      not answer (up 0 is the reading); 1 when it answers wrong (a login
      refused, not HTTP), said on stderr
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_otelcol.ps1')

Read-Page '/metrics'
Get-Readings @'
version|info|target_info||service_version:version,service_name:name
_u1|sum|otelcol_process_uptime
_u2|sum|otelcol_process_uptime_total
_u3|sum|otelcol_process_uptime_seconds_total
_u12|add|_u1|_u2
uptime_seconds|add|_u12|_u3
_m1|sum|otelcol_process_memory_rss
_m2|sum|otelcol_process_memory_rss_bytes
memory_rss_bytes|add|_m1|_m2
heap_bytes|sum|otelcol_process_runtime_heap_alloc_bytes
'@
exit 0
