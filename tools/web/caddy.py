# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The caddy pack's jobs (tools/web/jobs.py says how they are written). Every
request to Caddy's admin API is a GET: the API could change Caddy's
configuration, and the pack never asks it to."""
from jobs import job, M, tls_job

ADMIN = ('CADDY_ADMIN', 'http://localhost:2019')
READS = ("Reads Caddy's admin API at CADDY_ADMIN (default http://localhost:2019, where Caddy listens unless "
         "told otherwise), with GET only: the API could change Caddy's configuration, and this job never asks "
         "it to.")
ADMIN_SH = 'admin=${CADDY_ADMIN:-http://localhost:2019}\nadmin=${admin%/}\n'
ADMIN_PS = "$admin = if ($env:CADDY_ADMIN) { $env:CADDY_ADMIN.TrimEnd('/') } else { 'http://localhost:2019' }\n"
# prom <metric> [<label>]: a Prometheus page's samples of one metric, as
# "<label's value> <value>" (or "<value>"), summed by that label.
PROM_SH = r'''prom() {
    awk -v m="$1" -v l="${2-}" '
        index($0, m "{") == 1 || index($0, m " ") == 1 {
            k = ""
            if (l != "" && match($0, l "=\"[^\"]*\"")) k = substr($0, RSTART + length(l) + 2, RLENGTH - length(l) - 3)
            s[k] += $NF; seen = 1
        }
        # %.15g: awk would print a timestamp with six digits (1.79551e+09).
        END { if (seen) for (k in s) printf "%s%.15g\n", (l == "" ? "" : k " "), s[k] }' "$work/metrics"
}
'''
PROM_PS = r'''function Prom($m, $l) {
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
'''

job(pack='caddy', job='status', metric='', when='run_every   = 1m', runtime='30s', env=[ADMIN],
    needs_sh=['curl', 'jq'],
    title="a Caddy server, from its admin API",
    what="Reports whether Caddy's admin API answers, what its configuration serves (HTTP servers, the "
         "addresses they listen on, routes, site names, reverse proxies, file servers, and certificate "
         "policies), whether its HTTP metrics are on, whether the last configuration change loaded and how "
         "long ago, and its process's goroutines and open files against its limit.",
    reads=READS + " It reads /config/ and /metrics.",
    metrics=M(('up', '1 when the admin API answers, else 0'),
              ('servers', 'HTTP servers in the configuration'),
              ('listeners', 'addresses they listen on'),
              ('routes', 'routes, all servers together'),
              ('sites', 'site names the routes match'),
              ('reverse_proxies', 'reverse_proxy handlers'),
              ('file_servers', 'file_server handlers'),
              ('tls_policies', 'certificate automation policies'),
              ('metrics_enabled', "1 when Caddy's HTTP metrics are on (the traffic job needs them), else 0"),
              ('reload_ok', '1 when the last configuration change loaded, 0 when it failed (Caddy kept the old one)'),
              ('last_reload_seconds', 'since the configuration last loaded'),
              ('goroutines', "Caddy's goroutines"),
              ('open_fds', 'files and sockets Caddy holds open'),
              ('max_fds', 'the most it may'),
              ('fds_pct', 'open_fds as a percentage of max_fds')),
    healthy='up 1; reload_ok 1; fds_pct well below 100.',
    watch='goroutines climbing for hours: a leak, or connections held open; fds_pct above 70.',
    act='up 0; reload_ok 0: a configuration change was refused and Caddy still runs the old one (its log '
        'says why); fds_pct near 100: new connections fail.',
    sh=ADMIN_SH + PROM_SH + r'''fetch "$admin/config/"
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    *) exit 1 ;;
esac
echo "metric up 1"
jq -r '
    (.apps.http.servers // {}) as $s |
    [$s[]] as $all |
    "metric servers \($all | length)",
    "metric listeners \([$all[].listen[]?] | unique | length)",
    "metric routes \([$all[].routes[]?] | length)",
    "metric sites \([$all[].routes[]?.match[]?.host[]?] | unique | length)",
    "metric reverse_proxies \([$all[] | .. | objects | select(.handler? == "reverse_proxy")] | length)",
    "metric file_servers \([$all[] | .. | objects | select(.handler? == "file_server")] | length)",
    "metric tls_policies \([.apps.tls.automation.policies[]?] | length)",
    "metric metrics_enabled \(if (.apps.http.metrics != null) or ([$all[].metrics] | any(. != null)) then 1 else 0 end)"
' "$work/body" 2> /dev/null || { echo "$job: $admin/config/ is not a Caddy configuration" >&2; exit 1; }
fetch "$admin/metrics" || exit 1
cp "$work/body" "$work/metrics"
ok=$(prom caddy_config_last_reload_successful)
ts=$(prom caddy_config_last_reload_success_timestamp_seconds)
[ -n "$ok" ] && echo "metric reload_ok $ok"
[ -n "$ts" ] && echo "metric last_reload_seconds $(awk -v n="$now" -v t="$ts" 'BEGIN { printf "%d", n - t }')"
g=$(prom go_goroutines); o=$(prom process_open_fds); x=$(prom process_max_fds)
[ -n "$g" ] && echo "metric goroutines $g"
if [ -n "$o" ]; then
    echo "metric open_fds $o"
    [ -n "$x" ] && echo "metric max_fds $x" && awk -v o="$o" -v x="$x" 'BEGIN { if (x > 0) printf "metric fds_pct %.2f\n", 100 * o / x }'
fi
exit 0
''',
    ps=ADMIN_PS + PROM_PS + r'''$r = Get-Http "$admin/config/"
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
''',
    exit_sh='0 on success, Caddy up or down; 1 if curl or jq is missing, or the address is not '
            "Caddy's admin API",
    exit_ps="0 on success, Caddy up or down; 1 if the address is not Caddy's admin API")

job(pack='caddy', job='traffic', metric='traffic', when='run_every   = 1m', runtime='30s', env=[ADMIN],
    title="the traffic each Caddy server handles",
    what="Reports, for each of Caddy's HTTP servers, the requests it handled, those in flight, the errors "
         "its handlers returned, its answers by status class, and how long they took on average, from "
         "Caddy's own metrics. These need Caddy's HTTP metrics on: the global option { metrics } in a "
         "Caddyfile.",
    reads=READS + " It reads /config/apps/http (whether the metrics are on) and /metrics.",
    needs_sh=["curl", "jq"],
    metrics=M(('up', '1 when the admin API answers, else 0'), ('metrics_enabled', "1 when Caddy's HTTP metrics are on, else 0 (and nothing more is reported)"),
              ('requests_count', 'requests handled (a running total), tagged server=<its name>'),
              ('in_flight', 'requests being handled now, tagged server'),
              ('handler_errors_count', 'requests a handler failed (a running total), tagged server'),
              ('status_2xx_count', 'answers 2xx (a running total), tagged server'),
              ('status_3xx_count', 'answers 3xx, tagged server'),
              ('status_4xx_count', 'answers 4xx, tagged server'),
              ('status_5xx_count', 'answers 5xx, tagged server'),
              ('duration_avg_ms', 'time to answer, on average since Caddy started, tagged server'),
              ('servers_not_shown', 'servers past the first 50, left out')),
    healthy='status_5xx_count and handler_errors_count flat (graph the _count totals as rates).',
    watch='status_4xx_count rising faster than requests_count; in_flight climbing.',
    act='status_5xx_count or handler_errors_count rising: requests failing (the upstreams job says '
        'whether an upstream is down).',
    sh=ADMIN_SH + PROM_SH + r'''# On or not is in the configuration: after a reload, the counters are
# empty until a request comes.
fetch "$admin/config/apps/http"
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    *) exit 1 ;;
esac
echo "metric up 1"
on=$(jq -r 'if (.metrics != null) or ([(.servers // {})[].metrics] | any(. != null)) then 1 else 0 end' "$work/body" 2> /dev/null)
echo "metric metrics_enabled ${on:-0}"
[ "$on" = 1 ] || exit 0
fetch "$admin/metrics" || exit 1
cp "$work/body" "$work/metrics"
prom caddy_http_requests_total server | sort | head -n 50 > "$work/servers"
while read -r s n; do
    t="server=$(tag "$s")"
    echo "metric requests_count $n $t"
    echo "metric in_flight $(awk -v s="server=\"$s\"" 'index($0, "caddy_http_requests_in_flight{") == 1 && index($0, s) { v += $NF } END { printf "%.0f", v }' "$work/metrics") $t"
    echo "metric handler_errors_count $(awk -v s="server=\"$s\"" 'index($0, "caddy_http_request_errors_total{") == 1 && index($0, s) { v += $NF } END { printf "%.0f", v }' "$work/metrics") $t"
    awk -v s="server=\"$s\"" -v t="$t" '
        index($0, "caddy_http_request_duration_seconds_count{") == 1 && index($0, s) {
            if (match($0, /code="[0-9]/)) c[substr($0, RSTART + 6, 1)] += $NF
            n += $NF
        }
        index($0, "caddy_http_request_duration_seconds_sum{") == 1 && index($0, s) { sum += $NF }
        END {
            for (k = 2; k <= 5; k++) printf "metric status_%dxx_count %.0f %s\n", k, c[k], t
            printf "metric duration_avg_ms %.2f %s\n", (n > 0 ? 1000 * sum / n : 0), t
        }' "$work/metrics"
done < "$work/servers"
echo "metric servers_not_shown $(( $(prom caddy_http_requests_total server | wc -l) - $(wc -l < "$work/servers") ))"
exit 0
''',
    ps=ADMIN_PS + PROM_PS + r'''$r = Get-Http "$admin/config/"
if ($r.State -eq 'down') { M 'up' 0; exit 0 }
if ($r.State -ne 'ok') { Stop-Run $r.Why }
M 'up' 1
$on = Test-CaddyMetrics ($r.Body | ConvertFrom-Json)
M 'metrics_enabled' $on
if (-not $on) { exit 0 }
$r = Get-Http "$admin/metrics"
if ($r.State -ne 'ok') { Stop-Run $r.Why }
$script:Prom = @($r.Body -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') })
$req = Prom 'caddy_http_requests_total' 'server'
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
''',
    exit_sh="0 on success, Caddy up or down; 1 if curl is missing, or the address is not Caddy's admin API",
    exit_ps="0 on success, Caddy up or down; 1 if the address is not Caddy's admin API")

job(pack='caddy', job='upstreams', metric='upstreams', when='run_every   = 1m', runtime='30s', env=[ADMIN],
    needs_sh=['curl', 'jq'],
    title="the upstreams Caddy's reverse proxies send to",
    what="Reports every upstream of Caddy's reverse proxies: the requests it is handling now, its recent "
         "failures, and, where Caddy checks its health, whether it is healthy.",
    reads=READS + " It reads /reverse_proxy/upstreams and /metrics.",
    metrics=M(('up', '1 when the admin API answers, else 0'), ('upstreams', 'upstreams, all reverse proxies together'),
              ('upstreams_failing', 'of those, with recent failures'),
              ('upstreams_unhealthy', 'of those Caddy checks, unhealthy'),
              ('active_requests', 'requests it is handling now, tagged upstream=<its address>'),
              ('fails', 'its failures counted now (they expire after fail_duration), tagged upstream'),
              ('healthy', "1 when Caddy's health checks find it healthy, else 0, tagged upstream (only for "
                          'upstreams Caddy checks)'),
              ('upstreams_not_shown', 'upstreams past the first 100, left out')),
    healthy='upstreams_failing 0; upstreams_unhealthy 0.',
    watch='fails above 0 on one upstream: it fails now and then.',
    act='upstreams_unhealthy above 0: Caddy has stopped sending to it; every upstream of a proxy failing: '
        'that site answers 502.',
    sh=ADMIN_SH + PROM_SH + r'''fetch "$admin/reverse_proxy/upstreams"
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    *) exit 1 ;;
esac
echo "metric up 1"
cp "$work/body" "$work/up.json"
fetch "$admin/metrics" > /dev/null 2>&1 && cp "$work/body" "$work/metrics" || : > "$work/metrics"
prom caddy_reverse_proxy_upstreams_healthy upstream > "$work/health"
jq -r --rawfile h "$work/health" '
    def tag: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | .[0:120] | if . == "" then "none" else . end;
    ($h | split("\n") | map(select(. != "") | split(" ")) | map({key: .[0], value: (.[1] | tonumber)}) | from_entries) as $hs |
    (. // []) as $u |
    "metric upstreams \($u | length)",
    "metric upstreams_failing \([$u[] | select(.fails > 0)] | length)",
    "metric upstreams_unhealthy \([$hs[] | select(. == 0)] | length)",
    ($u | sort_by(-.fails, .address) | .[0:100][] | "upstream=\(.address | tag)" as $t |
        "metric active_requests \(.num_requests) \($t)",
        "metric fails \(.fails) \($t)",
        (if $hs[.address] != null then "metric healthy \($hs[.address]) \($t)" else empty end)),
    "metric upstreams_not_shown \([($u | length) - 100, 0] | max)"
' "$work/up.json" || { echo "$job: $admin/reverse_proxy/upstreams is not a list of upstreams" >&2; exit 1; }
exit 0
''',
    ps=ADMIN_PS + PROM_PS + r'''$r = Get-Http "$admin/reverse_proxy/upstreams"
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
''',
    exit_sh="0 on success, Caddy up or down; 1 if curl or jq is missing, or the address is not Caddy's admin API",
    exit_ps="0 on success, Caddy up or down; 1 if the address is not Caddy's admin API")

tls_job('caddy',
        endpoints_sh=ADMIN_SH + r'''# Caddy's own CA, when it issued certificates itself, so they check.
if [ -z "${CADDY_CACERT-}" ] && fetch "$admin/pki/ca/local" 2> /dev/null; then
    jq -r '.root_certificate // empty' "$work/body" > "$work/caddy-ca.pem" 2> /dev/null
    [ -s "$work/caddy-ca.pem" ] && CADDY_CACERT=$work/caddy-ca.pem
fi
if [ -n "${CADDY_TLS-}" ]; then
    read -r -a list <<< "$CADDY_TLS"
else
    fetch "$admin/config/"
    case $? in 0) ;; 2) echo "$job: Caddy does not answer at $admin" >&2; exit 1 ;; *) exit 1 ;; esac
    list=()
    while read -r h; do [ -n "$h" ] && list+=("${CADDY_TLS_ADDRESS:-127.0.0.1:443}/$h"); done < <(jq -r '
        [(.apps.http.servers // {})[].routes[]?.match[]?.host[]?, .apps.tls.automation.policies[]?.subjects[]?] |
        unique[] | select(startswith("*") | not)' "$work/body")
    echo "metric sites_found ${#list[@]}"
fi''',
        endpoints_ps=r'''Get-CaddyEndpoints''',
        default="every site name in Caddy's configuration, at CADDY_TLS_ADDRESS (default 127.0.0.1:443)",
        what_extra=" With CADDY_TLS unset, it asks Caddy's admin API for the site names it serves and checks "
                   "each one, and certificates from Caddy's own local CA check against that CA.",
        reads_extra=READS + " ",
        extra_env=[ADMIN, ('CADDY_TLS_ADDRESS', '127.0.0.1:443')],
        needs=('curl', 'jq', 'openssl'), env_default='',
        extra_metrics=[('sites_found', "site names found in Caddy's configuration (when CADDY_TLS is not set)")])

# What the Windows scripts add to _caddy.ps1.
LIB_PS = r'''
# Every handler's name in Caddy's servers, however deep (subroutes too).
function Get-Handlers($o) {
    foreach ($x in @($o)) {
        if ($null -eq $x -or $x -is [string] -or $x -is [ValueType]) { continue }
        foreach ($p in $x.PSObject.Properties) {
            if ($p.Name -eq 'handler') { [string]$p.Value }
            elseif ($null -ne $p.Value -and -not ($p.Value -is [string]) -and -not ($p.Value -is [ValueType])) { Get-Handlers $p.Value }
        }
    }
}
# 1 when Caddy's HTTP metrics are on in its configuration (the global option,
# or a server's own), else 0.
function Test-CaddyMetrics($c) {
    if (-not $c) { return 0 }
    if ($null -ne $c.apps.http.metrics) { return 1 }
    foreach ($s in @(Props $c.apps.http.servers)) { if ($null -ne $s.Value.metrics) { return 1 } }
    return 0
}
# The sum of a Prometheus metric's samples, among some lines.
function Sum-Prom($lines, [string]$m) {
    $s = [double]0
    foreach ($x in @($lines)) { if ($x.StartsWith("$m{") -or $x.StartsWith("$m ")) { $s += [double](($x -split ' ')[-1]) } }
    return $s
}
# The endpoints the tls job checks: CADDY_TLS, or every site name in
# Caddy's configuration at CADDY_TLS_ADDRESS. Certificates from Caddy's own
# local CA check against it.
$script:SitesFound = $null
function Get-CaddyEndpoints {
    $admin = if ($env:CADDY_ADMIN) { $env:CADDY_ADMIN.TrimEnd('/') } else { 'http://localhost:2019' }
    if (-not $script:Ca) {
        $r = Get-Http "$admin/pki/ca/local"
        if ($r.State -eq 'ok') {
            try {
                $pem = ($r.Body | ConvertFrom-Json).root_certificate
                if ($pem) { $script:Ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, [Text.Encoding]::ASCII.GetBytes($pem)) }
            } catch { $script:Ca = $null }
        }
    }
    if ($env:CADDY_TLS) { return @($env:CADDY_TLS -split '\s+' | Where-Object { $_ }) }
    $r = Get-Http "$admin/config/"
    if ($r.State -eq 'down') { Stop-Run "Caddy does not answer at $admin" }
    if ($r.State -ne 'ok') { Stop-Run $r.Why }
    $c = $r.Body | ConvertFrom-Json
    $names = @()
    if ($c -and $c.apps.http.servers) {
        foreach ($s in @(Props $c.apps.http.servers)) {
            foreach ($rt in @($s.Value.routes)) { foreach ($m in @($rt.match)) { $names += @($m.host) } }
        }
    }
    if ($c -and $c.apps.tls.automation.policies) { foreach ($p in @($c.apps.tls.automation.policies)) { $names += @($p.subjects) } }
    $names = @($names | Where-Object { $_ -and -not ([string]$_).StartsWith('*') } | Sort-Object -Unique)
    $script:SitesFound = $names.Count
    $addr = if ($env:CADDY_TLS_ADDRESS) { $env:CADDY_TLS_ADDRESS } else { '127.0.0.1:443' }
    return @($names | ForEach-Object { "$addr/$_" })
}
'''
