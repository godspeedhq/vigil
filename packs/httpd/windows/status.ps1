#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - an Apache httpd server, from its server-status page, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads httpd's server-status page (mod_status, machine-readable form) and
    reports: its version and MPM, its uptime and the graceful restarts since,
    the requests, bytes and time served, its workers (busy, idle, finishing)
    against those running, every worker's state from the scoreboard, its
    connections (with the event MPM: writing, keep-alive, closing), and, with
    mod_ssl, its TLS session cache. Then, on Linux and macOS, whether a file in
    its configuration folder changed after its youngest worker process started:
    a graceful restart starts new ones, so that is an edit httpd has not loaded
    (a worker httpd starts later for more load hides an older edit). It only
    reads: it changes nothing.

    Reads HTTPD_STATUS_URL?auto (default http://127.0.0.1/server-status), which
    you turn on once: <Location "/server-status"> SetHandler server-status;
    Require local </Location>, with ExtendedStatus On for the totals. HTTPD_CONF
    is the main configuration file (by default, the first of
    /etc/httpd/conf/httpd.conf, /etc/apache2/apache2.conf,
    /usr/local/apache2/conf/httpd.conf, /opt/homebrew/etc/httpd/httpd.conf,
    /usr/local/etc/httpd/httpd.conf that is there), and HTTPD_PID_FILE the file
    of its process id (by default, the first of /run/httpd/httpd.pid,
    /var/run/apache2/apache2.pid, /run/apache2/apache2.pid,
    /usr/local/apache2/logs/httpd.pid, /opt/homebrew/var/run/httpd/httpd.pid,
    /usr/local/var/run/httpd/httpd.pid that is there): its children, in the
    process list (ps), are the worker processes.
    What the scripts share is in _httpd.ps1, beside this one.

    Metrics:
      up                        1 when the page answers, else 0
      info                      always 1, tagged version=<httpd's> and
                                mpm=<event, worker or prefork>
      extended_status           1 when ExtendedStatus is on (the totals need
                                it), else 0
      uptime_seconds            since httpd started (a graceful restart does not
                                reset it)
      restarts                  graceful restarts since httpd started (its
                                configuration generation)
      accesses_count            requests served (a running total)
      bytes_count               bytes served (a running total)
      duration_ms_count         time spent serving them (a running total)
      cpu_load_pct              httpd's CPU, as a percentage of one CPU, since
                                the restart
      busy_workers              workers serving a request
      idle_workers              workers waiting for one
      finishing_workers         workers finishing after a graceful restart
      scoreboard_slots          slots in the scoreboard: ServerLimit times
                                ThreadLimit, the ceiling no setting can pass
      busy_pct                  busy workers, as a percentage of the workers
                                running (busy and idle): near 100 once httpd may
                                start no more (MaxRequestWorkers)
      processes                 child processes
      stopping_processes        child processes stopping
      connections               connections open (event MPM)
      conns_writing             of those, writing a reply without a worker
                                (event MPM)
      conns_keepalive           idle keep-alive connections, held without a
                                worker (event MPM)
      conns_closing             closing (event MPM)
      workers_in_state          workers in one scoreboard state, tagged
                                state=<waiting, starting, reading, sending,
                                keepalive, dns, closing, logging, finishing,
                                cleanup, open>
      ssl_cache_entries         TLS sessions in the cache (mod_ssl, shmcb)
      ssl_cache_usage_pct       how full the cache is
      ssl_cache_hits_count      sessions resumed from it (a running total)
      ssl_cache_misses_count    sessions looked for and not found (a running
                                total)
      ssl_cache_discards_count  sessions thrown out for lack of room (a running
                                total)
      config_changed            files under the configuration folder changed
                                after the youngest worker process started: an
                                edit not loaded yet (0 when none; Linux and
                                macOS)

    Example output (the rest are in the same form):
      metric up 1
      metric info 1 version=2.4.71 mpm=event
      metric extended_status 1
      metric uptime_seconds 98
      metric restarts 0
      metric accesses_count 232
      metric bytes_count 52224
      metric duration_ms_count 70
      metric cpu_load_pct 0.19
      metric busy_workers 4
      metric idle_workers 16
      metric finishing_workers 0
      metric scoreboard_slots 20
      metric busy_pct 20.00
      metric processes 2
      metric stopping_processes 0

    Reading the results (starting points: tune them to the server):
      Healthy  up 1; busy_pct well below 100; config_changed 0.
      Watch    busy_pct above 70; workers_in_state state=reading high (slow
               clients, or a slow-request attack); config_changed above 0 for
               long: an edit not reloaded (or one that would fail);
               ssl_cache_discards_count rising: the session cache is too small.
      Act      up 0; busy_pct near 100 with idle_workers 0: every worker busy,
               new requests wait (MaxRequestWorkers reached); stopping_processes
               or finishing_workers stuck above 0: a graceful restart that does
               not finish.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, httpd up or down; 1 if the page answers but is not
      a server-status page
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_httpd.ps1')

$url = if ($env:HTTPD_STATUS_URL) { $env:HTTPD_STATUS_URL } else { 'http://127.0.0.1/server-status' }
$r = Get-Http "$url`?auto"
if ($r.State -eq 'down') { M 'up' 0; exit 0 }
if ($r.State -ne 'ok') { Stop-Run $r.Why }
$v = @{}
foreach ($l in ($r.Body -split "`r?`n")) { $i = $l.IndexOf(': '); if ($i -gt 0) { $v[$l.Substring(0, $i)] = $l.Substring($i + 2) } }
if (-not $v.ContainsKey('Scoreboard')) { Stop-Run "$url is not a server-status page" }
M 'up' 1
$ver = ([string]$v['ServerVersion']) -replace '^Apache/', '' -replace ' .*', ''
Write-Output "metric info 1 version=$(Safe $ver) mpm=$(Safe $v['ServerMPM'])"
$ext = $v.ContainsKey('Total Accesses')
M 'extended_status' $(if ($ext) { 1 } else { 0 })
if ($v.ContainsKey('ServerUptimeSeconds')) { M 'uptime_seconds' $v['ServerUptimeSeconds'] }
if ($v.ContainsKey('ParentServerConfigGeneration')) { M 'restarts' ((N $v['ParentServerConfigGeneration']) - 1) }
if ($ext) {
    M 'accesses_count' $v['Total Accesses']
    M 'bytes_count' ((N $v['Total kBytes']) * 1024)
    if ($v.ContainsKey('Total Duration')) { M 'duration_ms_count' $v['Total Duration'] }
    if ($v.ContainsKey('CPULoad')) { M 'cpu_load_pct' ([Math]::Round((N $v['CPULoad']), 2)) }
}
$s = [string]$v['Scoreboard']; $max = $s.Length
M 'busy_workers' (N $v['BusyWorkers'])
M 'idle_workers' (N $v['IdleWorkers'])
M 'finishing_workers' (N $v['GracefulWorkers'])
M 'scoreboard_slots' $max
$run = (N $v['BusyWorkers']) + (N $v['IdleWorkers'])
M 'busy_pct' $(if ($run -gt 0) { [Math]::Round(100 * (N $v['BusyWorkers']) / $run, 2) } else { 0 })
if ($v.ContainsKey('Processes')) { M 'processes' $v['Processes'] }
if ($v.ContainsKey('Stopping')) { M 'stopping_processes' $v['Stopping'] }
if ($v.ContainsKey('ConnsTotal')) {
    M 'connections' $v['ConnsTotal']
    M 'conns_writing' (N $v['ConnsAsyncWriting'])
    M 'conns_keepalive' (N $v['ConnsAsyncKeepAlive'])
    M 'conns_closing' (N $v['ConnsAsyncClosing'])
}
foreach ($p in '_=waiting S=starting R=reading W=sending K=keepalive D=dns C=closing L=logging G=finishing I=cleanup .=open' -split ' ') {
    $c, $n = $p -split '=', 2
    M 'workers_in_state' (($s.ToCharArray() | Where-Object { $_ -eq $c[0] }) | Measure-Object).Count "state=$n"
}
if ($v.ContainsKey('CacheCurrentEntries')) {
    M 'ssl_cache_entries' $v['CacheCurrentEntries']
    M 'ssl_cache_usage_pct' (N (([string]$v['CacheUsage']) -replace '%.*', ''))
    M 'ssl_cache_hits_count' (N $v['CacheRetrieveHitCount'])
    M 'ssl_cache_misses_count' (N $v['CacheRetrieveMissCount'])
    M 'ssl_cache_discards_count' (N $v['CacheDiscardCount'])
}
exit 0
