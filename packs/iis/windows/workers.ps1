#Requires -Version 5.1

<#
.SYNOPSIS
    workers.ps1 - IIS's worker processes: requests, threads, errors and caches, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each worker process (w3wp.exe) of each application pool: the
    requests it is running and has served, its threads against the most it may
    use, the share of its answers that were 500, 404, 403 and 401, its
    websockets, and its caches (files, URIs, the output cache) with their
    memory. It only reads: it changes nothing.

    The account Vigil runs as needs no administrator: it reads IIS's performance
    counters as a member of Performance Monitor Users (LocalSystem, the Vigil
    service's account, already may). It reads the counter set W3SVC_W3WP: one
    instance a worker process, named <its process id>_<its pool>.
    What the scripts share is in _iis.ps1, beside this one.

    Metrics:
      workers                 worker processes, all pools together
      active_requests         requests it is running now, tagged pool=<its pool>
                              and pid=<its process id>
      requests_count          requests it served (a running total), tagged pool
                              and pid
      requests_rate           requests a second, tagged pool and pid
      threads_active          threads busy with a request, tagged pool and pid
      threads                 threads it has, tagged pool and pid
      threads_max             the most it may have, tagged pool and pid
      sent_500_pct            its answers that were 500, as a percentage, tagged
                              pool and pid
      sent_404_pct            its answers that were 404, tagged pool and pid
      sent_403_pct            its answers that were 403, tagged pool and pid
      sent_401_pct            its answers that were 401, tagged pool and pid
      websockets              websocket requests open, tagged pool and pid
      file_cache_bytes        memory of its file cache, tagged pool and pid
      output_cache_bytes      memory of its output cache, tagged pool and pid
      uri_cache_hits_count    URIs found in its cache (a running total), tagged
                              pool and pid
      uri_cache_misses_count  URIs not found in it, tagged pool and pid
      workers_not_shown       worker processes past the first 100, left out

    Example output (the rest are in the same form):
      metric workers 2
      metric active_requests 0 pool=vigil-ok pid=11136
      metric requests_count 73 pool=vigil-ok pid=11136
      metric requests_rate 0 pool=vigil-ok pid=11136
      metric threads_active 0 pool=vigil-ok pid=11136
      metric threads 5 pool=vigil-ok pid=11136
      metric threads_max 256 pool=vigil-ok pid=11136
      metric sent_500_pct 0 pool=vigil-ok pid=11136
      metric sent_404_pct 0 pool=vigil-ok pid=11136
      metric sent_403_pct 0 pool=vigil-ok pid=11136
      metric sent_401_pct 0 pool=vigil-ok pid=11136
      metric websockets 0 pool=vigil-ok pid=11136
      metric file_cache_bytes 58 pool=vigil-ok pid=11136
      metric output_cache_bytes 0 pool=vigil-ok pid=11136
      metric uri_cache_hits_count 179 pool=vigil-ok pid=11136
      metric uri_cache_misses_count 15 pool=vigil-ok pid=11136

    Reading the results (starting points: tune them to the server):
      Healthy  sent_500_pct near 0; active_requests low; threads_active below
               threads_max.
      Watch    active_requests climbing: requests run longer, or pile up;
               sent_404_pct rising.
      Act      sent_500_pct above a few percent: the application fails;
               threads_active at threads_max: the worker has no thread left for
               a new request.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, with or without worker processes (an idle pool has none)
#>

$Job = 'workers'
. (Join-Path $PSScriptRoot '_iis.ps1')

$w = Get-Set 'W3SVC_W3WP'
$names = if ($w) { @(Get-Instances $w | Where-Object { $_ -match '^\d+_' }) } else { @() }
M 'workers' $names.Count
foreach ($i in @($names | Sort-Object { -(N $w[$_]['active requests']) }, { $_ } | Select-Object -First 100)) {
    $c = $w[$i]
    $pid_, $pool = $i -split '_', 2
    $t = "pool=$(Safe $pool) pid=$pid_"
    M 'active_requests' $c['active requests'] $t
    M 'requests_count' $c['total http requests served'] $t
    M 'requests_rate' $c['requests / sec'] $t
    M 'threads_active' $c['active threads count'] $t
    M 'threads' $c['total threads'] $t
    M 'threads_max' $c['maximum threads count'] $t
    foreach ($k in '500', '404', '403', '401') { M "sent_${k}_pct" ([Math]::Round((N $c["% $k http response sent"]), 2)) $t }
    M 'websockets' $c['websocket active requests'] $t
    M 'file_cache_bytes' $c['current file cache memory usage'] $t
    M 'output_cache_bytes' $c['output cache current memory usage'] $t
    M 'uri_cache_hits_count' $c['uri cache hits'] $t
    M 'uri_cache_misses_count' $c['uri cache misses'] $t
}
M 'workers_not_shown' ([Math]::Max($names.Count - 100, 0))
exit 0
