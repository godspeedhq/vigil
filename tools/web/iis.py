# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The iis pack's jobs (tools/web/jobs.py says how they are written): Windows
only, as an account that is not an administrator. IIS's own configuration
(applicationHost.config, the WebAdministration module) is closed to such an
account, so the pack reads what is open to it: the performance counters (in
Performance Monitor Users), the logs (given read access), the System and
Application event logs (in Event Log Readers), and HTTP.sys's certificate
bindings."""
from jobs import job, M, TLS_METRICS

GROUPS = ("The account Vigil runs as needs no administrator: it reads IIS's performance counters as a member "
          "of Performance Monitor Users (LocalSystem, the Vigil service's account, already may).")

# What the Windows scripts add to _iis.ps1.
LIB_PS = r'''
# Get-Set <counter set>: every instance's counters, @{ <instance> =
# @{ <counter> = <value> } }, the names as IIS wrote them (Get-Counter
# lowercases them); $null when the set is not there (IIS not installed, or
# its service stopped).
function Get-Set([string]$set) {
    try { $list = Get-Counter -ListSet $set -ErrorAction Stop } catch { return $null }
    $names = @{}
    foreach ($p in @($list.PathsWithInstances)) {
        $m = [regex]::Match($p, '^\\[^(]+\((.*)\)\\([^\\]+)$')
        if ($m.Success) { $names[$m.Groups[1].Value.ToLowerInvariant()] = $m.Groups[1].Value; $names['#' + $m.Groups[2].Value.ToLowerInvariant()] = $m.Groups[2].Value }
    }
    try { $samples = (Get-Counter -Counter "\$set(*)\*" -ErrorAction Stop).CounterSamples } catch { return $null }
    $r = @{}
    foreach ($x in $samples) {
        $i = [string]$x.InstanceName
        if ($names.ContainsKey($i)) { $i = $names[$i] }
        $c = $x.Path.Substring($x.Path.LastIndexOf([char]92) + 1)
        if (-not $r.ContainsKey($i)) { $r[$i] = @{} }
        $r[$i][$c.ToLowerInvariant()] = $x.CookedValue
    }
    return $r
}
# The instances of a set, _Total left out, sorted.
function Get-Instances($set) { return @($set.Keys | Where-Object { $_ -ne '_Total' -and $_ -ne '_total' } | Sort-Object) }
'''

STATE = {1: 'uninitialized', 2: 'initialized', 3: 'running', 4: 'disabling', 5: 'stopped', 6: 'shutting_down',
         7: 'deleting'}

job(pack='iis', job='sites', metric='', when='run_every   = 1m', runtime='50s',
    title="IIS and its sites, from its counters",
    what="Reports whether IIS's web service runs and for how long, and each site's connections (now and the "
         "most), its requests (by method: GET, POST, HEAD, the others), its 404s and locked errors, the bytes "
         "it sent and received, its anonymous and authenticated users, and its CGI and ISAPI requests running, "
         "from the Web Service counters.",
    reads=GROUPS + " It reads the counter set Web Service, every site.",
    metrics=M(('up', "1 when IIS's web service (W3SVC) answers with its counters, else 0"),
              ('uptime_seconds', 'since the web service started'),
              ('sites', 'sites'),
              ('connections', 'connections now, all sites together'),
              ('site_uptime_seconds', 'since the site started, tagged site=<its name> (0: stopped)'),
              ('site_connections', 'connections now, tagged site'),
              ('site_connections_max', 'the most at once since it started, tagged site'),
              ('site_requests_count', 'requests (a running total), tagged site'),
              ('site_method_count', 'requests by method (a running total), tagged site and method=<get, post, '
                                    'head, put, delete, options or other>'),
              ('site_not_found_count', 'answers 404 (a running total), tagged site'),
              ('site_locked_count', 'requests refused because the file was locked (423), tagged site'),
              ('site_bytes_sent_count', 'bytes sent (a running total), tagged site'),
              ('site_bytes_received_count', 'bytes received (a running total), tagged site'),
              ('site_users', 'users now, tagged site and kind=<anonymous or authenticated>'),
              ('site_cgi_running', 'CGI and ISAPI requests running now, tagged site'),
              ('sites_not_shown', 'sites past the first 100, left out')),
    healthy='up 1; every site_uptime_seconds above 0; site_not_found_count rising slowly (graph the _count '
            'totals as rates).',
    watch='site_not_found_count rising fast (a broken link, a scan); site_connections near what the site '
          'should see.',
    act='up 0: IIS does not serve; site_uptime_seconds 0: that site is stopped.',
    ps=r'''$ws = Get-Set 'Web Service'
if ($null -eq $ws -or -not $ws.ContainsKey('_Total')) { M 'up' 0; exit 0 }
M 'up' 1
M 'uptime_seconds' $ws['_Total']['service uptime']
$names = Get-Instances $ws
M 'sites' $names.Count
M 'connections' $ws['_Total']['current connections']
foreach ($s in @($names | Select-Object -First 100)) {
    $c = $ws[$s]; $t = "site=$(Safe $s)"
    M 'site_uptime_seconds' $c['service uptime'] $t
    M 'site_connections' $c['current connections'] $t
    M 'site_connections_max' $c['maximum connections'] $t
    M 'site_requests_count' $c['total method requests'] $t
    foreach ($m in 'get', 'post', 'head', 'put', 'delete', 'options') { M 'site_method_count' $c["total $m requests"] "$t method=$m" }
    $other = 0; foreach ($m in 'trace', 'move', 'copy', 'mkcol', 'propfind', 'proppatch', 'search', 'lock', 'unlock') { $other += N $c["total $m requests"] }
    M 'site_method_count' ($other + (N $c['total other request methods'])) "$t method=other"
    M 'site_not_found_count' $c['total not found errors'] $t
    M 'site_locked_count' $c['total locked errors'] $t
    M 'site_bytes_sent_count' $c['total bytes sent'] $t
    M 'site_bytes_received_count' $c['total bytes received'] $t
    M 'site_users' $c['current anonymous users'] "$t kind=anonymous"
    M 'site_users' $c['current nonanonymous users'] "$t kind=authenticated"
    M 'site_cgi_running' ((N $c['current cgi requests']) + (N $c['current isapi extension requests'])) $t
}
M 'sites_not_shown' ([Math]::Max($names.Count - 100, 0))
exit 0
''',
    exit_ps='0, IIS up or down')

job(pack='iis', job='pools', metric='pools', when='run_every   = 1m', runtime='50s',
    title="IIS's application pools and their request queues",
    what="Reports each application pool: its state (running, stopped, and the states between), its worker "
         "processes against the most it may run, its uptime, its recycles, its worker processes' failures (all, "
         "recent, failed pings, failed starts and stops) and the time since the last; then its request queue in "
         "HTTP.sys: requests waiting for a worker, how long the oldest has waited, requests turned away, and the "
         "rates. The pools not running first.",
    reads=GROUPS + " It reads the counter sets APP_POOL_WAS and HTTP Service Request Queues.",
    metrics=M(('up', "1 when IIS's process activation service (WAS) answers with its counters, else 0"),
              ('pools', 'application pools'),
              ('pools_not_running', 'of those, not running (stopped, or starting, or stopping)'),
              ('state', 'its state: ' + ', '.join('%d %s' % kv for kv in STATE.items()) + '; tagged pool=<its '
                        'name> and status=<the word>'),
              ('worker_processes', 'worker processes now, tagged pool'),
              ('worker_processes_max', 'the most it may run (its web garden), tagged pool'),
              ('uptime_seconds', 'since it last started, tagged pool'),
              ('recycles_count', 'times it recycled (a running total), tagged pool'),
              ('worker_failures_count', 'its worker processes that failed (a running total), tagged pool'),
              ('recent_failures', 'of those, recently (rapid-fail protection counts these), tagged pool'),
              ('ping_failures_count', 'worker processes that did not answer a ping, tagged pool'),
              ('startup_failures_count', 'worker processes that failed to start, tagged pool'),
              ('shutdown_failures_count', 'worker processes that failed to stop, tagged pool'),
              ('since_failure_seconds', 'since its last worker process failed, tagged pool'),
              ('queue', 'requests waiting in HTTP.sys for a worker, tagged pool'),
              ('queue_oldest_ms', 'how long the oldest of those has waited, tagged pool'),
              ('rejected_count', 'requests HTTP.sys turned away (a running total), tagged pool'),
              ('arrival_rate', 'requests arriving a second, tagged pool'),
              ('rejection_rate', 'requests turned away a second, tagged pool'),
              ('cache_hit_rate', "answers from HTTP.sys's own cache a second, tagged pool"),
              ('pools_not_shown', 'pools past the first 200, left out')),
    healthy='every state 3 (running); queue 0; recent_failures 0; rejected_count flat.',
    watch='recycles_count rising faster than scheduled; queue above 0; worker_processes 0 for a pool that '
          'should be warm (idle time-out).',
    act='state 5 (stopped): the pool answers 503, by hand or by rapid-fail protection (iis_events says which); '
        'recent_failures rising: workers crash; rejected_count rising: requests turned away (queue full, or '
        'the pool stopped).',
    ps=r'''$wp = Get-Set 'APP_POOL_WAS'
if ($null -eq $wp) { M 'up' 0; exit 0 }
M 'up' 1
$q = Get-Set 'HTTP Service Request Queues'
if ($null -eq $q) { $q = @{} }
$names = Get-Instances $wp
$words = @{ @STATES@ }
M 'pools' $names.Count
M 'pools_not_running' (@($names | Where-Object { (N $wp[$_]['current application pool state']) -ne 3 })).Count
$order = @($names | Sort-Object @{ Expression = { if ((N $wp[$_]['current application pool state']) -eq 3) { 1 } else { 0 } } }, @{ Expression = { $_ } })
foreach ($p in @($order | Select-Object -First 200)) {
    $c = $wp[$p]; $t = "pool=$(Safe $p)"
    $st = [int](N $c['current application pool state'])
    $w = if ($words.ContainsKey($st)) { $words[$st] } else { 'unknown' }
    M 'state' $st "$t status=$w"
    M 'worker_processes' $c['current worker processes'] $t
    M 'worker_processes_max' $c['maximum worker processes'] $t
    M 'uptime_seconds' $c['current application pool uptime'] $t
    M 'recycles_count' $c['total application pool recycles'] $t
    M 'worker_failures_count' $c['total worker process failures'] $t
    M 'recent_failures' $c['recent worker process failures'] $t
    M 'ping_failures_count' $c['total worker process ping failures'] $t
    M 'startup_failures_count' $c['total worker process startup failures'] $t
    M 'shutdown_failures_count' $c['total worker process shutdown failures'] $t
    M 'since_failure_seconds' $c['time since last worker process failure'] $t
    if ($q.ContainsKey($p)) {
        $r = $q[$p]
        M 'queue' $r['currentqueuesize'] $t
        M 'queue_oldest_ms' $r['maxqueueitemage'] $t
        M 'rejected_count' $r['rejectedrequests'] $t
        M 'arrival_rate' $r['arrivalrate'] $t
        M 'rejection_rate' $r['rejectionrate'] $t
        M 'cache_hit_rate' $r['cachehitrate'] $t
    }
}
M 'pools_not_shown' ([Math]::Max($names.Count - 200, 0))
exit 0
'''.replace('@STATES@', '; '.join("%d = '%s'" % kv for kv in STATE.items())),
    exit_ps='0, IIS up or down')

job(pack='iis', job='workers', metric='workers', when='run_every   = 1m', runtime='50s',
    title="IIS's worker processes: requests, threads, errors and caches",
    what="Reports each worker process (w3wp.exe) of each application pool: the requests it is running and "
         "has served, its threads against the most it may use, the share of its answers that were 500, 404, 403 "
         "and 401, its websockets, and its caches (files, URIs, the output cache) with their memory.",
    reads=GROUPS + " It reads the counter set W3SVC_W3WP: one instance a worker process, named <its process "
                   "id>_<its pool>.",
    metrics=M(('workers', 'worker processes, all pools together'),
              ('active_requests', 'requests it is running now, tagged pool=<its pool> and pid=<its process id>'),
              ('requests_count', 'requests it served (a running total), tagged pool and pid'),
              ('requests_rate', 'requests a second, tagged pool and pid'),
              ('threads_active', 'threads busy with a request, tagged pool and pid'),
              ('threads', 'threads it has, tagged pool and pid'),
              ('threads_max', 'the most it may have, tagged pool and pid'),
              ('sent_500_pct', 'its answers that were 500, as a percentage, tagged pool and pid'),
              ('sent_404_pct', 'its answers that were 404, tagged pool and pid'),
              ('sent_403_pct', 'its answers that were 403, tagged pool and pid'),
              ('sent_401_pct', 'its answers that were 401, tagged pool and pid'),
              ('websockets', 'websocket requests open, tagged pool and pid'),
              ('file_cache_bytes', 'memory of its file cache, tagged pool and pid'),
              ('output_cache_bytes', 'memory of its output cache, tagged pool and pid'),
              ('uri_cache_hits_count', 'URIs found in its cache (a running total), tagged pool and pid'),
              ('uri_cache_misses_count', 'URIs not found in it, tagged pool and pid'),
              ('workers_not_shown', 'worker processes past the first 100, left out')),
    healthy='sent_500_pct near 0; active_requests low; threads_active below threads_max.',
    watch='active_requests climbing: requests run longer, or pile up; sent_404_pct rising.',
    act='sent_500_pct above a few percent: the application fails; threads_active at threads_max: the worker '
        'has no thread left for a new request.',
    ps=r'''$w = Get-Set 'W3SVC_W3WP'
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
''',
    exit_ps='0, with or without worker processes (an idle pool has none)')

job(pack='iis', job='log', metric='log', when='run_every   = 1m', runtime='50s',
    env=[('IIS_LOG_DIR', r'C:\inetpub\logs\LogFiles'), ('IIS_HTTPERR_DIR', r'C:\Windows\System32\LogFiles\HTTPERR'),
         ('IIS_LOG_MAX_MB', '32')],
    title="IIS's logs, minute by minute: each site's, and what HTTP.sys turned away",
    what="Reads one whole minute of each site's W3C log (the minute before last: IIS writes its logs out "
         "once a minute) and reports the requests in it: by status class and by status with its sub-status, "
         "by method, the errors Windows recorded (sc-win32-status), and how long the answers took (time-taken, "
         "p50, p90, p99 and the slowest). Then HTTP.sys's own error log, for the same minute: the requests it "
         "turned away before any site saw them (a stopped pool, a full queue, a connection dropped), by reason "
         "and pool. It reads only the end of each log, at most IIS_LOG_MAX_MB, and keeps nothing between "
         "runs. It never prints a path, a query or an address: only counts.",
    reads="Reads the newest log in each W3SVC<site id> folder of IIS_LOG_DIR (default "
          r"C:\inetpub\logs\LogFiles), in IIS's W3C format (its #Fields line says which), and the newest "
          r"httperr*.log in IIS_HTTPERR_DIR (default C:\Windows\System32\LogFiles\HTTPERR). The account Vigil "
          "runs as must be allowed to read them (packs/iis/README.md says how); until it is, log_readable 0. "
          "Sites are tagged by their folder (W3SVC2): IIS Manager shows each site's ID.",
    metrics=M(('log_readable', '1 when this account may read the site logs, else 0 (and they are not read)'),
              ('sites_logging', 'site log folders read'),
              ('window_complete', "1 when each log's whole minute was read; 0 when one grew faster than "
                                  "IIS_LOG_MAX_MB"),
              ('requests', 'requests logged in the minute, tagged site=<W3SVC and its id>'),
              ('status_2xx', 'of those, answered 2xx, tagged site (and status_1xx, _3xx, _4xx, _5xx)'),
              ('status_1xx', 'answered 1xx, tagged site'),
              ('status_3xx', 'answered 3xx, tagged site'),
              ('status_4xx', 'answered 4xx, tagged site'),
              ('status_5xx', 'answered 5xx, tagged site'),
              ('errors_5xx_pct', '5xx, as a percentage of its requests, tagged site'),
              ('status', 'requests answered with one status, tagged site and code=<status.sub-status, 500.0>'),
              ('method', 'requests by method, tagged site and method'),
              ('win32_errors', 'requests Windows recorded an error for (sc-win32-status not 0: a client that '
                               'went away, a connection reset), tagged site'),
              ('time_avg_ms', 'time-taken, on average, tagged site'),
              ('time_p50_ms', 'half the requests took less, tagged site'),
              ('time_p90_ms', '90% took less, tagged site'),
              ('time_p99_ms', '99% took less, tagged site'),
              ('time_max_ms', 'the slowest, tagged site'),
              ('httperr_readable', "1 when this account may read HTTP.sys's error log, else 0"),
              ('rejected_total', 'requests HTTP.sys turned away in the minute'),
              ('rejected', 'of those, by reason and pool, tagged reason=<HTTP.sys\'s word: AppOffline, '
                           'QueueFull, Disabled, Timer_ConnectionIdle, Connection_Dropped...>, status=<what '
                           'it answered> and queue=<the pool>'),
              ('sites_not_shown', 'site folders past the first 50, left out')),
    healthy='errors_5xx_pct below 1; rejected_total 0; time_p99_ms steady.',
    watch='time_p99_ms rising; win32_errors rising (clients giving up); rejected with reason=Timer_*: '
          'connections that idled out.',
    act='errors_5xx_pct above a few percent (status says which: 500.0 the application, 503 the pool); '
        'rejected with reason=AppOffline, Disabled or QueueFull: a pool stopped, crashed or overwhelmed, and '
        'its requests turned away before IIS saw them.',
    ps=r'''$dir = if ($env:IIS_LOG_DIR) { $env:IIS_LOG_DIR } else { 'C:\inetpub\logs\LogFiles' }
$herr = if ($env:IIS_HTTPERR_DIR) { $env:IIS_HTTPERR_DIR } else { 'C:\Windows\System32\LogFiles\HTTPERR' }
$cap = 32; if ($env:IIS_LOG_MAX_MB) { $cap = [int]$env:IIS_LOG_MAX_MB }
# The minute before last, in UTC, as IIS writes it: "2026-11-24 06:49".
$start = ([long][Math]::Floor($script:Now / 60) - 2) * 60
$want = [DateTimeOffset]::FromUnixTimeSeconds($start).UtcDateTime.ToString('yyyy-MM-dd HH:mm', $script:Inv)
# Read-W3C <file>: @{ Lines; Fields; Cut; Readable }: the lines of the
# minute, and the fields their #Fields line names.
function Read-W3C([string]$f) {
    try { $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite, Delete') } catch { return @{ Readable = $false } }
    try {
        $size = $fs.Length; $max = [long]$cap * 1048576; $cut = $size -gt $max
        $head = New-Object byte[] ([Math]::Min($size, 4096)); [void]$fs.Read($head, 0, $head.Length)
        $from = if ($cut) { $size - $max } else { 0 }
        [void]$fs.Seek($from, 'Begin')
        $buf = New-Object byte[] ($size - $from); $got = 0
        while ($got -lt $buf.Length) { $n = $fs.Read($buf, $got, $buf.Length - $got); if ($n -le 0) { break }; $got += $n }
    } finally { $fs.Dispose() }
    $fields = @()
    foreach ($l in ([Text.Encoding]::ASCII.GetString($head) -split "`r?`n")) { if ($l.StartsWith('#Fields: ')) { $fields = @($l.Substring(9).Trim() -split ' ') } }
    $lines = New-Object System.Collections.Generic.List[string]
    $before = $false; $inside = $false
    foreach ($l in ([Text.Encoding]::UTF8.GetString($buf, 0, $got) -split "`r?`n")) {
        if ($l.StartsWith('#Fields: ')) { $fields = @($l.Substring(9).Trim() -split ' '); continue }
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l.StartsWith($want)) { $inside = $true; $lines.Add($l) } elseif (-not $inside) { $before = $true }
    }
    return @{ Readable = $true; Lines = $lines; Fields = $fields; Complete = (-not $cut -or ($before -and $lines.Count -gt 0)) }
}
$sites = @(Get-ChildItem -LiteralPath $dir -Directory -Filter 'W3SVC*' -ErrorAction SilentlyContinue | Sort-Object Name)
$readable = 1; $complete = 1; $shown = 0
$out = New-Object System.Collections.Generic.List[string]
foreach ($s in $sites) {
    $f = @(Get-ChildItem -LiteralPath $s.FullName -File -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)
    if (-not $f.Count) { continue }
    $r = Read-W3C $f[-1].FullName
    if (-not $r.Readable) { $readable = 0; continue }
    if (-not $r.Complete) { $complete = 0 }
    if (++$shown -gt 50) { continue }
    $ix = @{}; for ($k = 0; $k -lt $r.Fields.Count; $k++) { $ix[$r.Fields[$k]] = $k }
    $t = "site=$(Safe $s.Name)"
    $cls = @{}; $code = @{}; $meth = @{}; $w32 = 0; $times = New-Object System.Collections.Generic.List[double]
    foreach ($l in $r.Lines) {
        $v = $l -split ' '
        $st = if ($ix.ContainsKey('sc-status')) { $v[$ix['sc-status']] } else { '' }
        if ($st -notmatch '^\d{3}$') { continue }
        $sub = if ($ix.ContainsKey('sc-substatus')) { $v[$ix['sc-substatus']] } else { '0' }
        $cls[$st.Substring(0, 1)] = 1 + [int]$cls[$st.Substring(0, 1)]
        $code["$st.$sub"] = 1 + [int]$code["$st.$sub"]
        $me = if ($ix.ContainsKey('cs-method')) { $v[$ix['cs-method']] } else { 'other' }
        if ($me -notmatch '^(GET|POST|HEAD|PUT|DELETE|PATCH|OPTIONS)$') { $me = 'other' }
        $meth[$me] = 1 + [int]$meth[$me]
        if ($ix.ContainsKey('sc-win32-status') -and $v[$ix['sc-win32-status']] -ne '0') { $w32++ }
        if ($ix.ContainsKey('time-taken')) { $times.Add((N $v[$ix['time-taken']])) }
    }
    $n = 0; foreach ($x in $cls.Values) { $n += $x }
    $out.Add((M 'requests' $n $t))
    foreach ($c in 1..5) { $out.Add((M "status_${c}xx" ([int]$cls[[string]$c]) $t)) }
    $out.Add((M 'errors_5xx_pct' $(if ($n) { [Math]::Round(100 * [int]$cls['5'] / $n, 2) } else { 0 }) $t))
    foreach ($k in @($code.Keys | Sort-Object | Select-Object -First 40)) { $out.Add((M 'status' $code[$k] "$t code=$k")) }
    foreach ($k in @($meth.Keys | Sort-Object)) { $out.Add((M 'method' $meth[$k] "$t method=$k")) }
    $out.Add((M 'win32_errors' $w32 $t))
    if ($times.Count) {
        $o = @($times | Sort-Object); $c = $o.Count
        $out.Add((M 'time_avg_ms' ([Math]::Round((($o | Measure-Object -Sum).Sum / $c), 1)) $t))
        foreach ($q in @(@('p50', 0.50), @('p90', 0.90), @('p99', 0.99))) { $out.Add((M "time_$($q[0])_ms" $o[[Math]::Max([int][Math]::Floor($c * $q[1] + 0.999) - 1, 0)] $t)) }
        $out.Add((M 'time_max_ms' $o[$c - 1] $t))
    }
}
M 'log_readable' $readable
if (-not $readable) { [Console]::Error.WriteLine("${Job}: this account may not read the logs in $dir (packs/iis/README.md says how to allow it)") }
M 'sites_logging' ([Math]::Min($shown, 50))
M 'window_complete' $complete
$out
M 'sites_not_shown' ([Math]::Max($shown - 50, 0))
# HTTP.sys's error log: what it turned away before any site saw it.
$h = @(Get-ChildItem -LiteralPath $herr -File -Filter 'httperr*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)
if (-not $h.Count) { M 'httperr_readable' 0; exit 0 }
$r = Read-W3C $h[-1].FullName
if (-not $r.Readable) { M 'httperr_readable' 0; exit 0 }
M 'httperr_readable' 1
$ix = @{}; for ($k = 0; $k -lt $r.Fields.Count; $k++) { $ix[$r.Fields[$k]] = $k }
$by = @{}
foreach ($l in $r.Lines) {
    $v = $l -split ' '
    $key = "reason=$(Safe $v[$ix['s-reason']]) status=$(Safe $v[$ix['sc-status']]) queue=$(Safe $v[$ix['s-queuename']])"
    $by[$key] = 1 + [int]$by[$key]
}
$tot = 0; foreach ($x in $by.Values) { $tot += $x }
M 'rejected_total' $tot
foreach ($k in @($by.Keys | Sort-Object { -$by[$_] }, { $_ } | Select-Object -First 40)) { M 'rejected' $by[$k] $k }
exit 0
''',
    exit_ps='0, whatever the logs hold (a log this account may not read is a reading)')

job(pack='iis', job='events', metric='events', when='run_every   = 5m', runtime='2m',
    env=[('IIS_EVENT_HOURS', '1')],
    title="IIS's events: pools disabled, workers crashed or hung, recycles",
    what="Counts IIS's events of the last hour (IIS_EVENT_HOURS) in the System and Application logs, from "
         "the process activation service (WAS) and the web service (W3SVC, its worker processes): application "
         "pools stopped by rapid-fail protection, worker processes that crashed, that did not answer a ping or "
         "failed to start, recycles and idle shutdowns; then each kind of event by pool. These say why a pool "
         "is stopped, or why its workers keep starting.",
    reads="Reads the System and Application event logs (Get-WinEvent), the providers Microsoft-Windows-WAS, "
          "Microsoft-Windows-IIS-W3SVC and Microsoft-Windows-IIS-W3SVC-WP. The account Vigil runs as needs "
          "Event Log Readers (LocalSystem may already).",
    metrics=M(('readable', '1 when this account may read the event logs, else 0'),
              ('events', "IIS's events in the last hour"),
              ('errors', 'of those, errors and critical ones'),
              ('warnings', 'warnings'),
              ('rapid_fail_count', 'application pools stopped by rapid-fail protection (event 5002)'),
              ('crashes_count', 'worker processes that ended unexpectedly (5009, 5011)'),
              ('unresponsive_count', 'worker processes that did not answer a ping (5010)'),
              ('start_failures_count', 'worker processes or pools that failed to start (5053, 5057, 5059, 5085)'),
              ('recycles_count', 'recycles: on schedule, on memory, on requests, on a configuration change '
                                 '(5074 to 5081, 5117)'),
              ('idle_shutdowns_count', 'worker processes shut down for being idle (5186)'),
              ('event', 'events of one kind, tagged id=<the event id>, pool=<the pool it names, or none> and '
                        'level=<error, warning or information>'),
              ('events_not_shown', 'kinds past the first 50, left out')),
    healthy='rapid_fail_count 0; crashes_count 0; unresponsive_count 0.',
    watch='recycles_count above what the schedule makes; crashes_count above 0 once.',
    act='rapid_fail_count above 0: a pool was stopped after its workers kept failing, and stays stopped '
        'until someone starts it (event says which); crashes_count or unresponsive_count rising: the '
        'application crashes or hangs.',
    ps=r'''$hours = 1; if ($env:IIS_EVENT_HOURS) { $hours = [double]$env:IIS_EVENT_HOURS }
$filter = @{ LogName = 'System', 'Application'; ProviderName = 'Microsoft-Windows-WAS', 'Microsoft-Windows-IIS-W3SVC', 'Microsoft-Windows-IIS-W3SVC-WP'; StartTime = (Get-Date).AddHours(-$hours) }
$ev = @()
try { $ev = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop) }
catch {
    # None at all is an exception too: only a refusal is not a reading.
    if ($_.Exception.Message -match 'denied|unauthori') { M 'readable' 0; [Console]::Error.WriteLine("${Job}: this account may not read the event logs: add it to Event Log Readers"); exit 0 }
}
M 'readable' 1
M 'events' $ev.Count
M 'errors' (@($ev | Where-Object { $_.Level -le 2 -and $_.Level -ge 1 })).Count
M 'warnings' (@($ev | Where-Object { $_.Level -eq 3 })).Count
function Count-Ids($ids) { return (@($ev | Where-Object { $ids -contains $_.Id -and $_.ProviderName -eq 'Microsoft-Windows-WAS' })).Count }
M 'rapid_fail_count' (Count-Ids @(5002))
M 'crashes_count' (Count-Ids @(5009, 5011))
M 'unresponsive_count' (Count-Ids @(5010))
M 'start_failures_count' (Count-Ids @(5053, 5057, 5059, 5085))
M 'recycles_count' (Count-Ids @(5074, 5075, 5076, 5077, 5078, 5079, 5080, 5081, 5117))
M 'idle_shutdowns_count' (Count-Ids @(5186))
$by = @{}
foreach ($e in $ev) {
    $pool = 'none'
    $m = [regex]::Match([string]$e.Message, "application pool '([^']+)'", 'IgnoreCase')
    if ($m.Success) { $pool = $m.Groups[1].Value }
    $lv = switch ($e.Level) { 1 { 'critical' } 2 { 'error' } 3 { 'warning' } default { 'information' } }
    $k = "id=$($e.Id) pool=$(Safe $pool) level=$lv"
    $by[$k] = 1 + [int]$by[$k]
}
foreach ($k in @($by.Keys | Sort-Object { -$by[$_] }, { $_ } | Select-Object -First 50)) { M 'event' $by[$k] $k }
M 'events_not_shown' ([Math]::Max($by.Count - 50, 0))
exit 0
''',
    exit_ps='0, whatever the events (an event log this account may not read is a reading)')

job(pack='iis', job='tls', metric='tls', when='run_every   = 15m', runtime='2m',
    env=[('IIS_TLS', ''), ('IIS_CACERT', '')],
    title="the certificates IIS serves, from HTTP.sys's bindings",
    what="Finds IIS's https bindings in HTTP.sys (netsh http show sslcert, which any account may read) and "
         "makes a TLS handshake with each, on this machine: the certificate it serves, the days until it "
         "expires, whether it is within its dates, and whether it checks against the trusted CAs and its name. "
         "An address binding (0.0.0.0:443) is asked for the first name in its certificate; a name binding "
         "(www.example.com:443) for its name. Nothing is sent but the handshake.",
    reads="IIS_TLS, when set, lists the endpoints instead, separated by spaces: host:port, or host:port/name. "
          "IIS_CACERT, a CA file, checks a private CA.",
    metrics=[('bindings_found', "https bindings found in HTTP.sys (when IIS_TLS is not set)")] + TLS_METRICS,
    healthy='tls_up 1; cert_expires_days above 30; cert_verified 1.',
    watch='cert_expires_days below 30: renewal should have happened by now.',
    act='cert_expires_days below 7, or cert_valid 0: clients will refuse it; cert_verified 0: clients that '
        'check refuse it now (reason says why); tls_up 0: the binding does not answer.',
    ps=r'''if ($env:IIS_TLS) { $list = @($env:IIS_TLS -split '\s+' | Where-Object { $_ }) }
else {
    $list = @()
    $text = @(netsh http show sslcert 2>$null)
    $bind = $null; $hash = $null; $store = 'MY'
    foreach ($l in $text + @('')) {
        if ($l -match '^\s*(IP:port|Hostname:port)\s*:\s*(\S+)\s*$') { $bind = @($Matches[1], $Matches[2]); $hash = $null; $store = 'MY' }
        elseif ($l -match '^\s*Certificate Hash\s*:\s*([0-9a-fA-F]+)') { $hash = $Matches[1] }
        elseif ($l -match '^\s*Certificate Store Name\s*:\s*(\S+)') {
            $store = $Matches[1]
            if ($bind) {
                $hp = $bind[1]; $port = $hp.Substring($hp.LastIndexOf(':') + 1)
                if ($bind[0] -eq 'Hostname:port') { $list += "127.0.0.1:$port/$($hp.Substring(0, $hp.LastIndexOf(':')))" }
                else {
                    $name = 'localhost'
                    try {
                        $c = Get-Item -LiteralPath "Cert:\LocalMachine\$store\$hash" -ErrorAction Stop
                        $dns = @($c.DnsNameList | Where-Object { $_ -and -not ([string]$_).StartsWith('*') })
                        if ($dns.Count) { $name = [string]$dns[0] }
                    } catch { }
                    $ip = $hp.Substring(0, $hp.LastIndexOf(':')).Trim('[', ']')
                    if ($ip -eq '0.0.0.0' -or $ip -eq '::') { $ip = '127.0.0.1' }
                    $list += "${ip}:$port/$name"
                }
                $bind = $null
            }
        }
    }
    M 'bindings_found' $list.Count
}
Read-Certs $list
exit 0
''',
    exit_ps='0, whatever the certificates')
