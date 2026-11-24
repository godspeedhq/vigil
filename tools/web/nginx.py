# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The nginx pack's jobs (tools/web/jobs.py says how they are written)."""
from jobs import job, M, log_job, tls_job

STATUS_METRICS = M(
    ('up', '1 when the page answers, else 0'),
    ('active_connections', 'client connections now, waiting ones included'),
    ('reading', 'connections reading a request'),
    ('writing', 'connections writing a response'),
    ('waiting', 'idle keep-alive connections'),
    ('accepts_count', 'connections accepted (a running total)'),
    ('handled_count', 'connections handled (a running total)'),
    ('requests_count', 'requests served (a running total)'),
    ('dropped_count', 'connections accepted but not handled (a running total)'),
)

job(pack='nginx', job='status', metric='', when='run_every   = 1m', runtime='30s',
    env=[('NGINX_STATUS_URL', 'http://127.0.0.1/nginx_status')],
    title="an nginx server's connections and requests",
    what="Reads nginx's stub_status page and reports what it says: its connections, reading, writing "
         "and waiting, and the connections and requests since nginx last started.",
    reads="Reads the page at NGINX_STATUS_URL (default http://127.0.0.1/nginx_status), which you turn on "
          "once: location = /nginx_status { stub_status; allow 127.0.0.1; deny all; }.",
    metrics=STATUS_METRICS,
    healthy='up 1; dropped_count not rising; requests_count rising at your usual rate (graph the _count '
            'totals as a rate).',
    watch='active_connections near worker_connections times the workers (the server job says how near).',
    act='up 0; dropped_count rising, which means nginx is turning connections away, usually at a resource '
        'limit.',
    sh=r'''url=${NGINX_STATUS_URL:-http://127.0.0.1/nginx_status}
fetch "$url"
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    *) exit 1 ;;
esac
# Active connections: 3
# server accepts handled requests
#  18432 18432 52117
# Reading: 0 Writing: 1 Waiting: 2
awk '
    /^Active connections:/ { a = $3 }
    /^ *[0-9]+ +[0-9]+ +[0-9]+ *$/ { ac = $1; h = $2; r = $3 }
    /^Reading:/ { rd = $2; wr = $4; wt = $6; ok = 1 }
    END {
        if (a == "" || r == "" || !ok) exit 1
        print "metric up 1"
        print "metric active_connections " a
        print "metric reading " rd
        print "metric writing " wr
        print "metric waiting " wt
        print "metric accepts_count " ac
        print "metric handled_count " h
        print "metric requests_count " r
        print "metric dropped_count " ac - h
    }' "$work/body" || { echo "$job: $url is not a stub_status page" >&2; exit 1; }
exit 0
''',
    ps=r'''$url = if ($env:NGINX_STATUS_URL) { $env:NGINX_STATUS_URL } else { 'http://127.0.0.1/nginx_status' }
$r = Get-Http $url
if ($r.State -eq 'down') { M 'up' 0; exit 0 }
if ($r.State -ne 'ok') { Stop-Run $r.Why }
$t = $r.Body
$a = [regex]::Match($t, 'Active connections:\s*(\d+)')
$n = [regex]::Match($t, '(?m)^\s*(\d+)\s+(\d+)\s+(\d+)\s*$')
$w = [regex]::Match($t, 'Reading:\s*(\d+)\s*Writing:\s*(\d+)\s*Waiting:\s*(\d+)')
if (-not ($a.Success -and $n.Success -and $w.Success)) { Stop-Run "$url is not a stub_status page" }
M 'up' 1
M 'active_connections' $a.Groups[1].Value
M 'reading' $w.Groups[1].Value
M 'writing' $w.Groups[2].Value
M 'waiting' $w.Groups[3].Value
M 'accepts_count' $n.Groups[1].Value
M 'handled_count' $n.Groups[2].Value
M 'requests_count' $n.Groups[3].Value
M 'dropped_count' ([int64]$n.Groups[1].Value - [int64]$n.Groups[2].Value)
exit 0
''',
    exit_sh='0 on success, server up or down; 1 if curl is missing, or the page answers but is not a '
            'stub_status page',
    exit_ps='0 on success, server up or down; 1 if the page answers but is not a stub_status page')

job(pack='nginx', job='server', metric='server', when='run_every   = 1m', runtime='30s',
    env=[('NGINX_PID_FILE', '/run/nginx.pid'), ('NGINX_CONF', '/etc/nginx/nginx.conf'),
         ('NGINX_STATUS_URL', 'http://127.0.0.1/nginx_status')],
    needs_sh=['ps'],
    title="nginx's processes and configuration",
    what="Reports nginx's processes: whether its master runs and for how long, its workers, old workers "
         "still finishing after a reload, and its cache processes. Then its configuration: when it was "
         "last loaded, whether a file in its folder changed since (an edit not yet reloaded), "
         "worker_connections, and how full the workers are: the stub_status page's connections against "
         "workers times worker_connections. On Linux, the open files each worker may hold.",
    reads="Reads the master's process id from NGINX_PID_FILE (default /run/nginx.pid), the process list "
          "(ps), the files under the folder of NGINX_CONF (default /etc/nginx/nginx.conf), and, for how "
          "full the workers are, the stub_status page at NGINX_STATUS_URL. A last reload is when the "
          "youngest worker started: a reload starts new workers.",
    metrics=M(('running', '1 when the master named in the pid file runs, else 0'),
              ('master_uptime_seconds', 'since the master started'),
              ('workers', 'worker processes'),
              ('workers_shutting_down', 'old workers still finishing their connections after a reload'),
              ('cache_processes', 'cache manager and loader processes'),
              ('last_reload_seconds', 'since the youngest worker started: the last reload (or a worker '
                                      'restarted after a crash)'),
              ('config_changed', 'files under the configuration folder changed since then: an edit not '
                                 'reloaded yet (0 when none)'),
              ('worker_processes_setting', 'worker_processes in the configuration (0 for auto)'),
              ('worker_connections', 'worker_connections in the configuration (512 when not set, as nginx)'),
              ('connections_capacity_pct', "the stub_status page's active connections, as a percentage of "
                                           'workers times worker_connections'),
              ('worker_open_files_limit', 'open files a worker may hold (Linux)')),
    healthy='running 1; workers steady; workers_shutting_down 0 soon after a reload; config_changed 0.',
    watch='config_changed above 0 for long: someone edited the configuration and did not reload (or the '
          'edit has an error); connections_capacity_pct above 70; workers_shutting_down above 0 for long: '
          'long connections (websockets, downloads) keep old workers alive.',
    act='running 0; connections_capacity_pct near 100: new connections wait or fail; workers below '
        'worker_processes_setting: workers dying.',
    sh=r'''pidf=${NGINX_PID_FILE:-/run/nginx.pid}
conf=${NGINX_CONF:-/etc/nginx/nginx.conf}
master=$(tr -dc '0-9' < "$pidf" 2> /dev/null)
ps ax -o pid= -o ppid= -o etime= -o args= > "$work/ps" 2> /dev/null || { echo "$job: ps failed" >&2; exit 1; }
if [ -z "$master" ] || ! awk -v m="$master" '$1 == m { f = 1 } END { exit !f }' "$work/ps"; then
    echo "metric running 0"
    exit 0
fi
awk -v m="$master" -v out="$work/workers" '
    function secs(t,   d, a, n) {
        d = 0
        if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
        n = split(t, a, ":")
        return d * 86400 + (n == 3 ? a[1] * 3600 + a[2] * 60 + a[3] : a[1] * 60 + a[2])
    }
    $1 == m { up = secs($3) }
    $2 == m {
        if ($0 ~ /shutting down/) down++
        else if ($0 ~ /worker process/) { w++; s = secs($3); if (young == "" || s < young) young = s; print $1 > out }
        else if ($0 ~ /cache (manager|loader)/) c++
    }
    END {
        print "metric running 1"
        print "metric master_uptime_seconds " up
        print "metric workers " w + 0
        print "metric workers_shutting_down " down + 0
        print "metric cache_processes " c + 0
        print "metric last_reload_seconds " (young == "" ? up : young)
    }' "$work/ps" > "$work/out"
cat "$work/out"
last=$(sed -n 's/^metric last_reload_seconds //p' "$work/out")
workers=$(sed -n 's/^metric workers //p' "$work/out")
if [ -r "$conf" ]; then
    echo "metric config_changed $(changed_since $((now - last)) "$(dirname "$conf")")"
    # The setting anywhere on a line not commented out: events { worker_connections 64; } too.
    wp=$(sed -n 's/^[^#]*worker_processes[[:space:]]\{1,\}\([0-9a-z]*\).*/\1/p' "$conf" | head -n 1)
    wconn=$(sed -n 's/^[^#]*worker_connections[[:space:]]\{1,\}\([0-9]*\).*/\1/p' "$conf" | head -n 1)
    case $wp in '' | auto) wp=0 ;; esac
    wconn=${wconn:-512}
    echo "metric worker_processes_setting $wp"
    echo "metric worker_connections $wconn"
    if fetch "${NGINX_STATUS_URL:-http://127.0.0.1/nginx_status}" 2> /dev/null; then
        active=$(sed -n 's/^Active connections: *\([0-9]*\).*/\1/p' "$work/body")
        [ -n "$active" ] && [ "${workers:-0}" -gt 0 ] &&
            echo "metric connections_capacity_pct $(awk -v a="$active" -v w="$workers" -v c="$wconn" 'BEGIN { printf "%.2f", 100 * a / (w * c) }')"
    fi
else
    echo "$job: this account may not read $conf: set NGINX_CONF" >&2
fi
w1=$(head -n 1 "$work/workers" 2> /dev/null)
if [ -n "$w1" ] && [ -r "/proc/$w1/limits" ]; then
    echo "metric worker_open_files_limit $(awk '/^Max open files/ { print $4 }' "/proc/$w1/limits")"
fi
exit 0
''',
    exit_sh='0 on success, nginx running or not; 1 if ps is missing')

log_job('nginx', '/var/log/nginx/access.log', r'C:\nginx\logs\access.log',
        'rt=$request_time at the end of the log_format', upstream=True)

tls_job('nginx',
        endpoints_sh='read -r -a list <<< "${NGINX_TLS:-localhost:443}"',
        endpoints_ps="$(if ($env:NGINX_TLS) { $env:NGINX_TLS -split '\\s+' | Where-Object { $_ } } else { 'localhost:443' })",
        default='localhost:443')
