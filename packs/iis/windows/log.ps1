#Requires -Version 5.1

<#
.SYNOPSIS
    log.ps1 - IIS's logs, minute by minute: each site's, and what HTTP.sys turned away, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads one whole minute of each site's W3C log (the minute before last: IIS
    writes its logs out once a minute) and reports the requests in it: by status
    class and by status with its sub-status, by method, the errors Windows
    recorded (sc-win32-status), and how long the answers took (time-taken, p50,
    p90, p99 and the slowest). Then HTTP.sys's own error log, for the same
    minute: the requests it turned away before any site saw them (a stopped
    pool, a full queue, a connection dropped), by reason and pool. It reads only
    the end of each log, at most IIS_LOG_MAX_MB, and keeps nothing between runs.
    It never prints a path, a query or an address: only counts. It only reads:
    it changes nothing.

    Reads the newest log in each W3SVC<site id> folder of IIS_LOG_DIR (default
    C:\inetpub\logs\LogFiles), in IIS's W3C format (its #Fields line says
    which), and the newest httperr*.log in IIS_HTTPERR_DIR (default
    C:\Windows\System32\LogFiles\HTTPERR). The account Vigil runs as must be
    allowed to read them (packs/iis/README.md says how); until it is,
    log_readable 0. Sites are tagged by their folder (W3SVC2): IIS Manager shows
    each site's ID.
    What the scripts share is in _iis.ps1, beside this one.

    Metrics:
      log_readable      1 when this account may read the site logs, else 0 (and
                        they are not read)
      sites_logging     site log folders read
      window_complete   1 when each log's whole minute was read; 0 when one grew
                        faster than IIS_LOG_MAX_MB
      requests          requests logged in the minute, tagged site=<W3SVC and
                        its id>
      status_2xx        of those, answered 2xx, tagged site (and status_1xx,
                        _3xx, _4xx, _5xx)
      status_1xx        answered 1xx, tagged site
      status_3xx        answered 3xx, tagged site
      status_4xx        answered 4xx, tagged site
      status_5xx        answered 5xx, tagged site
      errors_5xx_pct    5xx, as a percentage of its requests, tagged site
      status            requests answered with one status, tagged site and
                        code=<status.sub-status, 500.0>
      method            requests by method, tagged site and method
      win32_errors      requests Windows recorded an error for (sc-win32-status
                        not 0: a client that went away, a connection reset),
                        tagged site
      time_avg_ms       time-taken, on average, tagged site
      time_p50_ms       half the requests took less, tagged site
      time_p90_ms       90% took less, tagged site
      time_p99_ms       99% took less, tagged site
      time_max_ms       the slowest, tagged site
      httperr_readable  1 when this account may read HTTP.sys's error log, else
                        0
      rejected_total    requests HTTP.sys turned away in the minute
      rejected          of those, by reason and pool, tagged reason=<HTTP.sys's
                        word: AppOffline, QueueFull, Disabled,
                        Timer_ConnectionIdle, Connection_Dropped...>,
                        status=<what it answered> and queue=<the pool>
      sites_not_shown   site folders past the first 50, left out

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to the server):
      Healthy  errors_5xx_pct below 1; rejected_total 0; time_p99_ms steady.
      Watch    time_p99_ms rising; win32_errors rising (clients giving up);
               rejected with reason=Timer_*: connections that idled out.
      Act      errors_5xx_pct above a few percent (status says which: 500.0 the
               application, 503 the pool); rejected with reason=AppOffline,
               Disabled or QueueFull: a pool stopped, crashed or overwhelmed,
               and its requests turned away before IIS saw them.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever the logs hold (a log this account may not read is a
      reading)
#>

$Job = 'log'
. (Join-Path $PSScriptRoot '_iis.ps1')

$dir = if ($env:IIS_LOG_DIR) { $env:IIS_LOG_DIR } else { 'C:\inetpub\logs\LogFiles' }
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
