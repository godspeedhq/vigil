#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - is this NATS server healthy, and are its clients keeping up, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether the server answers and is healthy (ready, and with JetStream
    on, current with its cluster), what it is, how long since it started and
    since its configuration last loaded, its connections against its limit, its
    subscriptions, the slow consumers it has cut off (clients, routes, gateways
    and leaf nodes that could not keep up), stale connections, the messages and
    bytes in and out, and the client with the most bytes waiting to be sent to
    it, named. It only reads: every request is a GET, and it changes nothing.

    Reads NATS_URL (default http://localhost:8222), its monitoring port: /varz,
    /healthz and /connz?sort=pending&limit=1.
    What the scripts share is in _nats.ps1, beside this one.

    Metrics:
      up                            1 when the server answered, else 0 (and
                                    nothing more is read)
      healthy                       1 when /healthz answers ok; 0 when it
                                    answers 503: not ready, or JetStream not
                                    current with its cluster
      info                          always 1, tagged server=<its name>,
                                    version=, cluster=<its name, or none> and
                                    jetstream=<on or off>
      uptime_seconds                since the server started
      last_reload_seconds           since its configuration last loaded
                                    (started, or reloaded)
      connections                   clients connected
      max_connections               the most it allows (max_connections)
      connections_pct               connections, of max_connections
      total_connections_count       clients that have connected (a running
                                    total)
      subscriptions                 subscriptions, routes' and the system's
                                    included
      slow_consumers_count          connections it cut off for not reading fast
                                    enough (a running total)
      slow_consumer_clients_count   of them, clients (a running total; 2.10 and
                                    later, as the next three)
      slow_consumer_routes_count    routes to other servers of its cluster
      slow_consumer_gateways_count  gateways to other clusters
      slow_consumer_leafs_count     leaf nodes
      stale_connections_count       connections closed for not answering its
                                    pings (a running total)
      in_msgs_count                 messages received, from clients and other
                                    servers (a running total)
      out_msgs_count                messages sent (a running total)
      in_bytes_count                bytes received (a running total)
      out_bytes_count               bytes sent (a running total)
      pending_bytes_max             bytes waiting to be sent to the client
                                    furthest behind, tagged client=<its name, or
                                    address:port>

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  up 1; healthy 1; connections_pct well below 80;
               slow_consumers_count flat; pending_bytes_max small.
      Watch    connections_pct above 80; pending_bytes_max growing: that client
               is falling behind (client says which).
      Act      up 0 or healthy 0; slow_consumers_count moving: the server is
               cutting off clients (or routes) that cannot keep up, and they
               lose messages; connections_pct near 100: new clients are refused.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when NATS does not answer (up 0 is the
      reading); 1 when it answers wrong (not HTTP, a page missing), said on
      stderr
#>

$Job = 'status'
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
# /healthz answers 503 when the server is not ready: JetStream not current
# with its cluster, or not started.
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

$h = Get-Answer '/healthz'
if ($h.State -eq 'ok') { Write-Output 'metric healthy 1' } elseif ($h.State -eq 'notready') { Write-Output 'metric healthy 0' }
$js = if ($v.jetstream -and $v.jetstream.config) { 'on' } else { 'off' }
Write-Output "metric info 1 server=$(Safe $v.server_name) version=$(Safe $v.version) cluster=$(Safe $v.cluster.name) jetstream=$js"
Write-Output "metric uptime_seconds $((Ts $v.now) - (Ts $v.start))"
Write-Output "metric last_reload_seconds $((Ts $v.now) - (Ts $v.config_load_time))"
Write-Output "metric connections $($v.connections)"
Write-Output "metric max_connections $($v.max_connections)"
Write-Output "metric connections_pct $(Fmt (Pct $v.connections $v.max_connections))"
Write-Output "metric total_connections_count $($v.total_connections)"
Write-Output "metric subscriptions $($v.subscriptions)"
Write-Output "metric slow_consumers_count $($v.slow_consumers)"
if ($v.slow_consumer_stats) {
    Write-Output "metric slow_consumer_clients_count $($v.slow_consumer_stats.clients)"
    Write-Output "metric slow_consumer_routes_count $($v.slow_consumer_stats.routes)"
    Write-Output "metric slow_consumer_gateways_count $($v.slow_consumer_stats.gateways)"
    Write-Output "metric slow_consumer_leafs_count $($v.slow_consumer_stats.leafs)"
}
Write-Output "metric stale_connections_count $(Num $v.stale_connections)"
Write-Output "metric in_msgs_count $($v.in_msgs)"
Write-Output "metric out_msgs_count $($v.out_msgs)"
Write-Output "metric in_bytes_count $($v.in_bytes)"
Write-Output "metric out_bytes_count $($v.out_bytes)"
# The client with the most bytes waiting to be sent to it: the next slow
# consumer, before the server cuts it off.
$c = Get-Answer '/connz?sort=pending&limit=1'
if ($c.State -eq 'ok') {
    $top = @(($c.Body | ConvertFrom-Json).connections) | Select-Object -First 1
    $who = if ($top -and $top.name) { $top.name } elseif ($top) { "$($top.ip):$($top.port)" } else { '' }
    Write-Output "metric pending_bytes_max $(if ($top) { Num $top.pending_bytes } else { 0 }) client=$(Safe $who)"
}
exit 0
