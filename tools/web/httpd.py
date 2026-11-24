# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The httpd pack's jobs (tools/web/jobs.py says how they are written)."""
from jobs import job, M, log_job, tls_job

CONF_SH = '/etc/httpd/conf/httpd.conf /etc/apache2/apache2.conf /usr/local/apache2/conf/httpd.conf ' \
          '/opt/homebrew/etc/httpd/httpd.conf /usr/local/etc/httpd/httpd.conf'
PID_SH = '/run/httpd/httpd.pid /var/run/apache2/apache2.pid /run/apache2/apache2.pid ' \
         '/usr/local/apache2/logs/httpd.pid /opt/homebrew/var/run/httpd/httpd.pid /usr/local/var/run/httpd/httpd.pid'
SCORE = [('_', 'waiting', 'waiting for a connection'), ('S', 'starting', 'starting'),
         ('R', 'reading', 'reading a request'), ('W', 'sending', 'sending a reply'),
         ('K', 'keepalive', 'keeping a connection open, idle'), ('D', 'dns', 'looking up a name'),
         ('C', 'closing', 'closing a connection'), ('L', 'logging', 'logging'),
         ('G', 'finishing', 'finishing gracefully'), ('I', 'cleanup', 'cleaning up an idle worker'),
         ('.', 'open', 'an open slot, no process')]

job(pack='httpd', job='status', metric='', when='run_every   = 1m', runtime='30s',
    env=[('HTTPD_STATUS_URL', 'http://127.0.0.1/server-status'), ('HTTPD_CONF', ''), ('HTTPD_PID_FILE', '')],
    needs_sh=['curl', 'ps'],
    title="an Apache httpd server, from its server-status page",
    what="Reads httpd's server-status page (mod_status, machine-readable form) and reports: its version and "
         "MPM, its uptime and the graceful restarts since, the requests, bytes and time served, its workers "
         "(busy, idle, finishing) against those running, every worker's state from the scoreboard, its "
         "connections (with the event MPM: writing, keep-alive, closing), and, with mod_ssl, its TLS session "
         "cache. Then, on Linux and macOS, whether a file in its configuration folder changed after its "
         "oldest worker process started: a graceful restart replaces them all, so that is an edit httpd "
         "has not loaded.",
    reads="Reads HTTPD_STATUS_URL?auto (default http://127.0.0.1/server-status), which you turn on once: "
          "<Location \"/server-status\"> SetHandler server-status; Require local </Location>, with "
          "ExtendedStatus On for the totals. HTTPD_CONF is the main configuration file (by default, the "
          "first of " + ', '.join(CONF_SH.split()) + " that is there), and HTTPD_PID_FILE the file of its "
          "process id (by default, the first of " + ', '.join(PID_SH.split()) + " that is there): its "
          "children, in the process list (ps), are the worker processes.",
    metrics=M(('up', '1 when the page answers, else 0'),
              ('info', 'always 1, tagged version=<httpd\'s> and mpm=<event, worker or prefork>'),
              ('extended_status', '1 when ExtendedStatus is on (the totals need it), else 0'),
              ('uptime_seconds', 'since httpd started (a graceful restart does not reset it)'),
              ('restarts', 'graceful restarts since httpd started (its configuration generation)'),
              ('accesses_count', 'requests served (a running total)'),
              ('bytes_count', 'bytes served (a running total)'),
              ('duration_ms_count', 'time spent serving them (a running total)'),
              ('cpu_load_pct', "httpd's CPU, as a percentage of one CPU, since the restart"),
              ('busy_workers', 'workers serving a request'),
              ('idle_workers', 'workers waiting for one'),
              ('finishing_workers', 'workers finishing after a graceful restart'),
              ('scoreboard_slots', 'slots in the scoreboard: ServerLimit times ThreadLimit, the ceiling no setting can pass'),
              ('busy_pct', 'busy workers, as a percentage of the workers running (busy and idle): near 100 once httpd may start no more (MaxRequestWorkers)'),
              ('processes', 'child processes'),
              ('stopping_processes', 'child processes stopping'),
              ('connections', 'connections open (event MPM)'),
              ('conns_writing', 'of those, writing a reply without a worker (event MPM)'),
              ('conns_keepalive', 'idle keep-alive connections, held without a worker (event MPM)'),
              ('conns_closing', 'closing (event MPM)'),
              ('workers_in_state', 'workers in one scoreboard state, tagged state=<' +
               ', '.join(n for _, n, _ in SCORE) + '>'),
              ('ssl_cache_entries', 'TLS sessions in the cache (mod_ssl, shmcb)'),
              ('ssl_cache_usage_pct', "how full the cache is"),
              ('ssl_cache_hits_count', 'sessions resumed from it (a running total)'),
              ('ssl_cache_misses_count', 'sessions looked for and not found (a running total)'),
              ('ssl_cache_discards_count', 'sessions thrown out for lack of room (a running total)'),
              ('config_changed', 'files under the configuration folder changed after the oldest worker '
                                 'process started: an edit not loaded yet (0 when none; Linux and macOS)')),
    healthy='up 1; busy_pct well below 100; config_changed 0.',
    watch='busy_pct above 70; workers_in_state state=reading high (slow clients, or a slow-request attack); '
          'config_changed above 0 for long: an edit not reloaded (or one that would fail); '
          'ssl_cache_discards_count rising: the session cache is too small.',
    act='up 0; busy_pct near 100 with idle_workers 0: every worker busy, new requests wait (MaxRequestWorkers reached); '
        'stopping_processes or finishing_workers stuck above 0: a graceful restart that does not finish.',
    sh=r'''url=${HTTPD_STATUS_URL:-http://127.0.0.1/server-status}
fetch "$url?auto"
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    *) exit 1 ;;
esac
grep -q '^Scoreboard:' "$work/body" || { echo "$job: $url is not a server-status page" >&2; exit 1; }
awk -F': ' '
    # A number as httpd gave it: awk would print a large one as 3e+09.
    function num(x) { return (x ~ /^-?[0-9]+([.][0-9]+)?$/) ? x : 0 }
    { v[$1] = $2 }
    END {
        print "metric up 1"
        ver = v["ServerVersion"]; sub(/^Apache\//, "", ver); sub(/ .*/, "", ver)
        printf "metric info 1 version=%s mpm=%s\n", (ver == "" ? "unknown" : ver), (v["ServerMPM"] == "" ? "unknown" : v["ServerMPM"])
        ext = ("Total Accesses" in v) ? 1 : 0
        print "metric extended_status " ext
        if ("ServerUptimeSeconds" in v) print "metric uptime_seconds " num(v["ServerUptimeSeconds"])
        if ("ParentServerConfigGeneration" in v) print "metric restarts " v["ParentServerConfigGeneration"] - 1
        if (ext) {
            print "metric accesses_count " num(v["Total Accesses"])
            printf "metric bytes_count %.0f\n", v["Total kBytes"] * 1024
            if ("Total Duration" in v) print "metric duration_ms_count " num(v["Total Duration"])
            if ("CPULoad" in v) printf "metric cpu_load_pct %.2f\n", v["CPULoad"]
        }
        s = v["Scoreboard"]; max = length(s)
        print "metric busy_workers " num(v["BusyWorkers"])
        print "metric idle_workers " num(v["IdleWorkers"])
        print "metric finishing_workers " num(v["GracefulWorkers"])
        print "metric scoreboard_slots " max
        run = v["BusyWorkers"] + v["IdleWorkers"]
        printf "metric busy_pct %.2f\n", (run > 0 ? 100 * v["BusyWorkers"] / run : 0)
        if ("Processes" in v) print "metric processes " num(v["Processes"])
        if ("Stopping" in v) print "metric stopping_processes " num(v["Stopping"])
        if ("ConnsTotal" in v) {
            print "metric connections " num(v["ConnsTotal"])
            print "metric conns_writing " num(v["ConnsAsyncWriting"])
            print "metric conns_keepalive " num(v["ConnsAsyncKeepAlive"])
            print "metric conns_closing " num(v["ConnsAsyncClosing"])
        }
        n = split("@SCORE@", sc, " ")
        for (i = 1; i <= n; i++) {
            split(sc[i], p, "=")
            c = 0; t = s
            while ((j = index(t, p[1])) > 0) { c++; t = substr(t, j + 1) }
            print "metric workers_in_state " c " state=" p[2]
        }
        if ("CacheCurrentEntries" in v) {
            print "metric ssl_cache_entries " num(v["CacheCurrentEntries"])
            u = v["CacheUsage"]; sub(/%.*/, "", u); print "metric ssl_cache_usage_pct " u + 0
            print "metric ssl_cache_hits_count " num(v["CacheRetrieveHitCount"])
            print "metric ssl_cache_misses_count " num(v["CacheRetrieveMissCount"])
            print "metric ssl_cache_discards_count " num(v["CacheDiscardCount"])
        }
    }' "$work/body" > "$work/out"
cat "$work/out"
conf=${HTTPD_CONF-}
if [ -z "$conf" ]; then
    for conf in @CONF@; do [ -e "$conf" ] && break; done
fi
pidf=${HTTPD_PID_FILE-}
if [ -z "$pidf" ]; then
    for pidf in @PID@; do [ -e "$pidf" ] && break; done
fi
parent=$(tr -dc '0-9' < "$pidf" 2> /dev/null)
# The oldest worker process: every one is newer than the last graceful
# restart, so a file changed after it started has not been loaded.
if [ -n "$parent" ] && [ -r "$conf" ]; then
    oldest=$(ps ax -o ppid= -o etime= 2> /dev/null | awk -v m="$parent" '
        function secs(t,   d, a, n) {
            d = 0
            if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
            n = split(t, a, ":")
            return d * 86400 + (n == 3 ? a[1] * 3600 + a[2] * 60 + a[3] : a[1] * 60 + a[2])
        }
        $1 == m { s = secs($2); if (s > o) o = s }
        END { print o + 0 }')
    [ "${oldest:-0}" -gt 0 ] && echo "metric config_changed $(changed_since $((now - oldest)) "$(dirname "$conf")")"
fi
exit 0
'''.replace('@SCORE@', ' '.join('%s=%s' % (c, n) for c, n, _ in SCORE)).replace('@CONF@', CONF_SH).replace('@PID@', PID_SH),
    ps=r'''$url = if ($env:HTTPD_STATUS_URL) { $env:HTTPD_STATUS_URL } else { 'http://127.0.0.1/server-status' }
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
foreach ($p in '@SCORE@' -split ' ') {
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
'''.replace('@SCORE@', ' '.join('%s=%s' % (c, n) for c, n, _ in SCORE)),
    exit_sh='0 on success, httpd up or down; 1 if curl is missing, or the page answers but is not a '
            'server-status page',
    exit_ps='0 on success, httpd up or down; 1 if the page answers but is not a server-status page')

log_job('httpd', '/var/log/httpd/access_log /var/log/apache2/access.log /usr/local/apache2/logs/access_log '
        '/opt/homebrew/var/log/httpd/access_log /usr/local/var/log/httpd/access_log',
        r'C:\Apache24\logs\access.log', 'rtus=%D at the end of the LogFormat', upstream=False)

tls_job('httpd',
        endpoints_sh='read -r -a list <<< "${HTTPD_TLS:-localhost:443}"',
        endpoints_ps="$(if ($env:HTTPD_TLS) { $env:HTTPD_TLS -split '\\s+' | Where-Object { $_ } } else { 'localhost:443' })",
        default='localhost:443')
