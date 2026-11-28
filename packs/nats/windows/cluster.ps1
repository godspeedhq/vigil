#Requires -Version 5.1

<#
.SYNOPSIS
    cluster.ps1 - a NATS server's routes to the rest of its cluster, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether the server is in a cluster, the routes configured, the other
    servers it has routes to, each named, the route connections (2.10 and later
    pool several to each server), the bytes waiting on them, the slowest round
    trip, and its leaf nodes. It only reads: every request is a GET, and it
    changes nothing.

    Reads NATS_URL (default http://localhost:8222), its monitoring port: /varz
    and /routez.
    What the scripts share is in _nats.ps1, beside this one.

    Metrics:
      up                    1 when the server answered, else 0 (and nothing more
                            is read)
      clustered             1 when it has a cluster port; 0 alone (and nothing
                            more is read)
      routes_configured     routes in its configuration (cluster.routes): the
                            servers it is told to reach
      route_peers           other servers of its cluster it has a route to
      route_peer            always 1, one line for each of them, tagged
                            peer=<its name>
      route_peer_not_shown  how many more there were than the 20 shown
      route_connections     route connections: with route pooling (2.10 and
                            later), several to each server
      route_pending_bytes   bytes waiting to be sent on its routes
      route_rtt_max_ms      the slowest route's round trip, in milliseconds
      leafnodes             leaf node connections

    Example output (the rest are in the same form):
      metric up 1
      metric clustered 1
      metric routes_configured 2
      metric route_peers 2
      metric route_peer 1 peer=n2
      metric route_peer 1 peer=n3
      metric route_connections 8
      metric route_pending_bytes 0
      metric route_rtt_max_ms 0.46
      metric leafnodes 0

    Reading the results (starting points: tune them to your own):
      Healthy  route_peers the cluster's size less one, steady;
               route_pending_bytes near 0.
      Watch    route_rtt_max_ms well above its usual; route_pending_bytes
               growing.
      Act      route_peers below the cluster's size less one: a server is down
               or cut off (route_peer says which are there); with JetStream, a
               cluster that loses more than half its servers stops accepting
               writes.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when NATS does not answer (up 0 is the
      reading); 1 when it answers wrong (not HTTP, a page missing), said on
      stderr
#>

$Job = 'cluster'
. (Join-Path $PSScriptRoot '_nats.ps1')

$r = Get-Answer '/varz'
switch ($r.State) {
    'ok' { Write-Output 'metric up 1' }
    'down' { Write-Output 'metric up 0'; exit 0 }
    'notready' { Write-Output 'metric up 0'; exit 0 }
    'missing' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/varz: no such page (HTTP 404): is NATS_URL its monitoring port (-m 8222)?"); exit 0 }
    default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
}
$v = $r.Body | ConvertFrom-Json
function Ts($s) {
    if ($s -is [DateTime]) { return ([DateTimeOffset]$s.ToUniversalTime()).ToUnixTimeSeconds() }
    return [DateTimeOffset]::Parse(([string]$s).Substring(0, 19) + 'Z', $script:Inv).ToUnixTimeSeconds()
}
function Pct($a, $b) { if ([double]$b -gt 0) { [Math]::Round([double]$a * 100 / [double]$b, 2, [MidpointRounding]::AwayFromZero) } else { 0 } }
function Ms($d) {
    $sum = 0.0
    $unit = @{ 'h' = 3600000.0; 'm' = 60000.0; 's' = 1000.0; 'ms' = 1.0; "$([char]0xB5)s" = 0.001; 'us' = 0.001; 'ns' = 0.000001 }
    foreach ($x in [regex]::Matches([string]$d, "([0-9.]+)(h|ms|m|s|$([char]0xB5)s|us|ns)")) {
        $sum += [double]::Parse($x.Groups[1].Value, $script:Inv) * $unit[$x.Groups[2].Value]
    }
    [Math]::Round($sum, 3, [MidpointRounding]::AwayFromZero)
}
function Num($v) { if ($null -eq $v) { 0 } else { $v } }

if (-not $v.cluster -or -not $v.cluster.cluster_port) { Write-Output 'metric clustered 0'; exit 0 }
Write-Output 'metric clustered 1'
$rr = Get-Answer '/routez'
if ($rr.State -ne 'ok') { [Console]::Error.WriteLine("${Job}: $($script:Url)/routez did not answer"); exit 1 }
$rz = $rr.Body | ConvertFrom-Json
$routes = @($rz.routes | Where-Object { $_ })
$peers = @($routes | ForEach-Object { [string]$_.remote_name } | Sort-Object -Unique -CaseSensitive)
Write-Output "metric routes_configured $(@($v.cluster.urls | Where-Object { $_ }).Count)"
Write-Output "metric route_peers $($peers.Count)"
foreach ($p in ($peers | Select-Object -First 20)) { Write-Output "metric route_peer 1 peer=$(Safe $p)" }
Write-Output "metric route_peer_not_shown $([Math]::Max($peers.Count - 20, 0))"
Write-Output "metric route_connections $($rz.num_routes)"
$pend = 0; foreach ($x in $routes) { $pend += [double]$x.pending_size }
Write-Output "metric route_pending_bytes $(Fmt $pend)"
$rtt = 0.0; foreach ($x in $routes) { $m = Ms $x.rtt; if ($m -gt $rtt) { $rtt = $m } }
Write-Output "metric route_rtt_max_ms $(Fmt $rtt)"
Write-Output "metric leafnodes $(Num $v.leafnodes)"
exit 0
