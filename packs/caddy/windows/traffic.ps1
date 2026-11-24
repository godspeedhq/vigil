#Requires -Version 5.1

<#
.SYNOPSIS
    traffic.ps1 - the traffic each Caddy server handles, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports, for each of Caddy's HTTP servers, the requests it handled, those in
    flight, the errors its handlers returned, its answers by status class, and
    how long they took on average, from Caddy's own metrics. These need Caddy's
    HTTP metrics on: the global option { metrics } in a Caddyfile. It only
    reads: it changes nothing.

    Reads Caddy's admin API at CADDY_ADMIN (default http://localhost:2019, where
    Caddy listens unless told otherwise), with GET only: the API could change
    Caddy's configuration, and this job never asks it to. It reads /metrics.
    What the scripts share is in _caddy.ps1, beside this one.

    Metrics:
      up                    1 when the admin API answers, else 0
      metrics_enabled       1 when Caddy's HTTP metrics are on, else 0 (and
                            nothing more is reported)
      requests_count        requests handled (a running total), tagged
                            server=<its name>
      in_flight             requests being handled now, tagged server
      handler_errors_count  requests a handler failed (a running total), tagged
                            server
      status_2xx_count      answers 2xx (a running total), tagged server
      status_3xx_count      answers 3xx, tagged server
      status_4xx_count      answers 4xx, tagged server
      status_5xx_count      answers 5xx, tagged server
      duration_avg_ms       time to answer, on average since Caddy started,
                            tagged server
      servers_not_shown     servers past the first 50, left out

    Example output (the rest are in the same form):
      metric up 1
      metric metrics_enabled 1
      metric requests_count 2 server=srv0
      metric in_flight 0 server=srv0
      metric handler_errors_count 0 server=srv0
      metric status_2xx_count 0 server=srv0
      metric status_3xx_count 0 server=srv0
      metric status_4xx_count 0 server=srv0
      metric status_5xx_count 2 server=srv0
      metric duration_avg_ms 0.02 server=srv0
      metric requests_count 98 server=srv1
      metric in_flight 0 server=srv1
      metric handler_errors_count 4 server=srv1
      metric status_2xx_count 94 server=srv1
      metric status_3xx_count 0 server=srv1
      metric status_4xx_count 0 server=srv1

    Reading the results (starting points: tune them to the server):
      Healthy  status_5xx_count and handler_errors_count flat (graph the _count
               totals as rates).
      Watch    status_4xx_count rising faster than requests_count; in_flight
               climbing.
      Act      status_5xx_count or handler_errors_count rising: requests failing
               (the upstreams job says whether an upstream is down).

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Caddy up or down; 1 if the address is not Caddy's
      admin API
#>

$Job = 'traffic'
. (Join-Path $PSScriptRoot '_caddy.ps1')

$admin = if ($env:CADDY_ADMIN) { $env:CADDY_ADMIN.TrimEnd('/') } else { 'http://localhost:2019' }
function Prom($m, $l) {
    $s = [ordered]@{}
    foreach ($x in $script:Prom) {
        if ($x.StartsWith("$m{") -or $x.StartsWith("$m ")) {
            $k = ''
            if ($l) { $g = [regex]::Match($x, "$l=""([^""]*)"""); if ($g.Success) { $k = $g.Groups[1].Value } }
            $s[$k] = [double]$s[$k] + [double]($x -split ' ')[-1]
        }
    }
    $s
}
$r = Get-Http "$admin/metrics"
if ($r.State -eq 'down') { M 'up' 0; exit 0 }
if ($r.State -ne 'ok') { Stop-Run $r.Why }
M 'up' 1
$script:Prom = @($r.Body -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') })
$req = Prom 'caddy_http_requests_total' 'server'
if (-not $req.Count) { M 'metrics_enabled' 0; exit 0 }
M 'metrics_enabled' 1
$names = @($req.Keys | Sort-Object)
foreach ($s in @($names | Select-Object -First 50)) {
    $t = "server=$(Safe $s)"
    $mine = @($script:Prom | Where-Object { $_.Contains("server=""$s""") })
    M 'requests_count' $req[$s] $t
    M 'in_flight' (Sum-Prom $mine 'caddy_http_requests_in_flight') $t
    M 'handler_errors_count' (Sum-Prom $mine 'caddy_http_request_errors_total') $t
    $cnt = @($mine | Where-Object { $_.StartsWith('caddy_http_request_duration_seconds_count{') })
    foreach ($k in 2..5) { M "status_${k}xx_count" (Sum-Prom @($cnt | Where-Object { $_ -match "code=""$k" }) 'caddy_http_request_duration_seconds_count') $t }
    $n = Sum-Prom $cnt 'caddy_http_request_duration_seconds_count'
    $sum = Sum-Prom $mine 'caddy_http_request_duration_seconds_sum'
    M 'duration_avg_ms' $(if ($n -gt 0) { [Math]::Round(1000 * $sum / $n, 2) } else { 0 }) $t
}
M 'servers_not_shown' ([Math]::Max($names.Count - 50, 0))
exit 0
