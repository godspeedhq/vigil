#Requires -Version 5.1

<#
.SYNOPSIS
    upstreams.ps1 - the upstreams Caddy's reverse proxies send to, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports every upstream of Caddy's reverse proxies: the requests it is
    handling now, its recent failures, and, where Caddy checks its health,
    whether it is healthy. It only reads: it changes nothing.

    Reads Caddy's admin API at CADDY_ADMIN (default http://localhost:2019, where
    Caddy listens unless told otherwise), with GET only: the API could change
    Caddy's configuration, and this job never asks it to. It reads
    /reverse_proxy/upstreams and /metrics.
    What the scripts share is in _caddy.ps1, beside this one.

    Metrics:
      up                   1 when the admin API answers, else 0
      upstreams            upstreams, all reverse proxies together
      upstreams_failing    of those, with recent failures
      upstreams_unhealthy  of those Caddy checks, unhealthy
      active_requests      requests it is handling now, tagged upstream=<its
                           address>
      fails                its failures counted now (they expire after
                           fail_duration), tagged upstream
      healthy              1 when Caddy's health checks find it healthy, else 0,
                           tagged upstream (only for upstreams Caddy checks)
      upstreams_not_shown  upstreams past the first 100, left out

    Example output (the rest are in the same form):
      metric up 1
      metric upstreams 4
      metric upstreams_failing 0
      metric upstreams_unhealthy 1
      metric active_requests 0 upstream=10.255.255.1:81
      metric fails 0 upstream=10.255.255.1:81
      metric healthy 1 upstream=10.255.255.1:81
      metric active_requests 0 upstream=gone:80
      metric fails 0 upstream=gone:80
      metric healthy 0 upstream=gone:80
      metric upstreams_not_shown 0

    Reading the results (starting points: tune them to the server):
      Healthy  upstreams_failing 0; upstreams_unhealthy 0.
      Watch    fails above 0 on one upstream: it fails now and then.
      Act      upstreams_unhealthy above 0: Caddy has stopped sending to it;
               every upstream of a proxy failing: that site answers 502.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Caddy up or down; 1 if the address is not Caddy's
      admin API
#>

$Job = 'upstreams'
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
$r = Get-Http "$admin/reverse_proxy/upstreams"
if ($r.State -eq 'down') { M 'up' 0; exit 0 }
if ($r.State -ne 'ok') { Stop-Run $r.Why }
M 'up' 1
# Windows PowerShell 5.1 hands back a JSON array as one object: kept in a
# variable first, @() makes it the list.
$j = $r.Body | ConvertFrom-Json
$u = @(@($j) | Where-Object { $_ })
$m = Get-Http "$admin/metrics"
$script:Prom = if ($m.State -eq 'ok') { @($m.Body -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') }) } else { @() }
$hs = Prom 'caddy_reverse_proxy_upstreams_healthy' 'upstream'
M 'upstreams' $u.Count
M 'upstreams_failing' (@($u | Where-Object { $_.fails -gt 0 })).Count
M 'upstreams_unhealthy' (@($hs.Values | Where-Object { $_ -eq 0 })).Count
foreach ($x in @($u | Sort-Object @{ Expression = { -[int]$_.fails } }, @{ Expression = { [string]$_.address } } | Select-Object -First 100)) {
    $t = "upstream=$(Safe $x.address)"
    M 'active_requests' $x.num_requests $t
    M 'fails' $x.fails $t
    if ($hs.Contains([string]$x.address)) { M 'healthy' $hs[[string]$x.address] $t }
}
M 'upstreams_not_shown' ([Math]::Max($u.Count - 100, 0))
exit 0
