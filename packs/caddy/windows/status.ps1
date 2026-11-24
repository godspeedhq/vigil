#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - a Caddy server, from its admin API, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether Caddy's admin API answers, what its configuration serves
    (HTTP servers, the addresses they listen on, routes, site names, reverse
    proxies, file servers, and certificate policies), whether its HTTP metrics
    are on, whether the last configuration change loaded and how long ago, and
    its process's goroutines and open files against its limit. It only reads: it
    changes nothing.

    Reads Caddy's admin API at CADDY_ADMIN (default http://localhost:2019, where
    Caddy listens unless told otherwise), with GET only: the API could change
    Caddy's configuration, and this job never asks it to. It reads /config/ and
    /metrics.
    What the scripts share is in _caddy.ps1, beside this one.

    Metrics:
      up                   1 when the admin API answers, else 0
      servers              HTTP servers in the configuration
      listeners            addresses they listen on
      routes               routes, all servers together
      sites                site names the routes match
      reverse_proxies      reverse_proxy handlers
      file_servers         file_server handlers
      tls_policies         certificate automation policies
      metrics_enabled      1 when Caddy's HTTP metrics are on (the traffic job
                           needs them), else 0
      reload_ok            1 when the last configuration change loaded, 0 when
                           it failed (Caddy kept the old one)
      last_reload_seconds  since the configuration last loaded
      goroutines           Caddy's goroutines
      open_fds             files and sockets Caddy holds open
      max_fds              the most it may
      fds_pct              open_fds as a percentage of max_fds

    Example output (the rest are in the same form):
      metric up 1
      metric servers 2
      metric listeners 2
      metric routes 3
      metric sites 1
      metric reverse_proxies 3
      metric file_servers 0
      metric tls_policies 1
      metric metrics_enabled 1
      metric reload_ok 1
      metric last_reload_seconds 126
      metric goroutines 35
      metric open_fds 15
      metric max_fds 524287
      metric fds_pct 0.00

    Reading the results (starting points: tune them to the server):
      Healthy  up 1; reload_ok 1; fds_pct well below 100.
      Watch    goroutines climbing for hours: a leak, or connections held open;
               fds_pct above 70.
      Act      up 0; reload_ok 0: a configuration change was refused and Caddy
               still runs the old one (its log says why); fds_pct near 100: new
               connections fail.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Caddy up or down; 1 if the address is not Caddy's
      admin API
#>

$Job = 'status'
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
$r = Get-Http "$admin/config/"
if ($r.State -eq 'down') { M 'up' 0; exit 0 }
if ($r.State -ne 'ok') { Stop-Run $r.Why }
M 'up' 1
$c = $r.Body | ConvertFrom-Json
$all = @()
if ($c -and $c.apps.http.servers) { $all = @(Props $c.apps.http.servers | ForEach-Object { $_.Value }) }
$routes = @($all | ForEach-Object { @($_.routes) } | Where-Object { $_ })
$handlers = @(Get-Handlers $all)
M 'servers' $all.Count
M 'listeners' (@($all | ForEach-Object { @($_.listen) } | Where-Object { $_ } | Sort-Object -Unique)).Count
M 'routes' $routes.Count
M 'sites' (@($routes | ForEach-Object { @($_.match) } | Where-Object { $_ } | ForEach-Object { @($_.host) } | Where-Object { $_ } | Sort-Object -Unique)).Count
M 'reverse_proxies' (@($handlers | Where-Object { $_ -eq 'reverse_proxy' })).Count
M 'file_servers' (@($handlers | Where-Object { $_ -eq 'file_server' })).Count
M 'tls_policies' (@($c.apps.tls.automation.policies | Where-Object { $_ })).Count
M 'metrics_enabled' (Test-CaddyMetrics $c)
$r = Get-Http "$admin/metrics"
if ($r.State -ne 'ok') { Stop-Run $r.Why }
$script:Prom = @($r.Body -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') })
$ok = Prom 'caddy_config_last_reload_successful'
$ts = Prom 'caddy_config_last_reload_success_timestamp_seconds'
if ($ok.Count) { M 'reload_ok' $ok[''] }
if ($ts.Count) { M 'last_reload_seconds' ([Math]::Floor($script:Now - $ts[''])) }
$g = Prom 'go_goroutines'; if ($g.Count) { M 'goroutines' $g[''] }
$o = Prom 'process_open_fds'; $x = Prom 'process_max_fds'
if ($o.Count) { M 'open_fds' $o['']; if ($x.Count -and $x[''] -gt 0) { M 'max_fds' $x['']; M 'fds_pct' ([Math]::Round(100 * $o[''] / $x[''], 2)) } }
exit 0
