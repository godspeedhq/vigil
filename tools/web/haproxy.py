# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The haproxy pack's jobs (tools/web/jobs.py says how they are written). They
send HAProxy's runtime API "show info" and "show stat" only: a socket at
"level user" is enough, and refuses anything that would change HAProxy."""
from jobs import job, M

SOCKETS = '/run/haproxy/admin.sock /var/lib/haproxy/stats /var/run/haproxy.sock'
ENV = [('HAPROXY_SOCKET', '')]
READS = ("Asks HAProxy's runtime API at HAPROXY_SOCKET: a socket file (by default the first of " +
         ', '.join(SOCKETS.split()) + " that is there), read with socat or nc, or a TCP address "
         "(127.0.0.1:9999), read by bash itself. A socket at level user is enough: stats socket "
         "ipv4@127.0.0.1:9999 level user.")

# What the scripts add to _haproxy.sh: one question to the runtime API.
LIB_SH = r'''
# ask <command>: HAProxy's answer, in $work/answer. 0; 2 when nothing
# answers (a reading); stops, saying why, when the socket refuses.
ask() {
    local s=${HAPROXY_SOCKET-} host port
    if [ -z "$s" ]; then
        for s in @SOCKETS@; do [ -e "$s" ] && break; done
    fi
    : > "$work/answer"
    case $s in
        /*)
            [ -S "$s" ] || return 2
            [ -w "$s" ] || { echo "$job: this account may not use $s: add it to the socket's group (packs/haproxy/README.md says how)" >&2; exit 1; }
            if command -v socat > /dev/null 2>&1; then
                printf '%s\n' "$1" | socat -t 10 - "UNIX-CONNECT:$s" > "$work/answer" 2> "$work/err" || return 2
            elif command -v nc > /dev/null 2>&1; then
                printf '%s\n' "$1" | nc -U "$s" > "$work/answer" 2> "$work/err" || return 2
            else
                echo "$job: socat or nc not found: needed to read $s (or give HAPROXY_SOCKET a TCP address)" >&2
                exit 1
            fi
            ;;
        *:*)
            host=${s%:*} port=${s##*:}
            { exec 3<> "/dev/tcp/$host/$port"; } 2> /dev/null || return 2
            printf '%s\n' "$1" >&3
            cat <&3 > "$work/answer"
            exec 3<&-
            ;;
        *) echo "$job: HAPROXY_SOCKET is neither a socket file nor host:port: $s" >&2; exit 1 ;;
    esac
    [ -s "$work/answer" ] || return 2
    if grep -q '^Permission denied\|^Unknown command' "$work/answer"; then
        echo "$job: HAProxy refused \"$1\": $(head -n 1 "$work/answer")" >&2
        exit 1
    fi
    return 0
}
# stat <awk program>: "show stat" as CSV, its columns by name: f("scur").
stat() {
    ask 'show stat'
    case $? in 0) ;; *) echo "metric up 0"; exit 0 ;; esac
    echo "metric up 1"
    awk -F, -v now="$now" '
        function f(k) { return (k in col) ? $col[k] : "" }
        # A number as HAProxy gave it: awk would print a large one as 3e+09.
        function num(x) { return (x ~ /^-?[0-9]+([.][0-9]+)?$/) ? x : 0 }
        function tag(s) { gsub(/[^A-Za-z0-9@._:\/+-]/, "_", s); s = substr(s, 1, 120); return s == "" ? "none" : s }
        NR == 1 { sub(/^# /, ""); for (i = 1; i <= NF; i++) col[$i] = i; next }
        $0 == "" { next }
        '"$1" "$work/answer"
}
'''.replace('@SOCKETS@', SOCKETS)

job(pack='haproxy', job='info', metric='', when='run_every   = 1m', runtime='30s', env=ENV, needs_sh=[],
    title="an HAProxy process: its connections, rates, TLS and load",
    what="Reports HAProxy itself: its version and uptime, its connections against maxconn and how often it "
         "reached it, its connection, session, request and TLS rates (and their peaks), TLS session reuse, "
         "how busy its threads are and its run queue, its memory pools and their failures, dropped logs, "
         "failed DNS resolutions, warnings and its stick-table peers.",
    reads=READS + ' It sends "show info".',
    metrics=M(('up', '1 when HAProxy answers, else 0'),
              ('info', 'always 1, tagged version=<its version>'),
              ('uptime_seconds', 'since HAProxy started'),
              ('threads', 'threads'),
              ('connections', 'connections now'),
              ('maxconn', 'the most it accepts (maxconn)'),
              ('connections_pct', 'connections as a percentage of maxconn'),
              ('maxconn_reached_count', 'times it reached maxconn (a running total)'),
              ('conn_rate', 'connections a second, now'),
              ('conn_rate_max', 'the most a second since it started'),
              ('sess_rate', 'sessions a second'),
              ('requests_count', 'requests (a running total)'),
              ('ssl_rate', 'TLS sessions a second'),
              ('ssl_connections', 'TLS connections now'),
              ('ssl_key_rate', 'full TLS handshakes a second (those that are not resumed)'),
              ('ssl_reuse_pct', 'TLS sessions resumed, as a percentage'),
              ('ssl_cache_misses_count', 'TLS session cache misses (a running total)'),
              ('busy_pct', 'how busy its threads are (100 less their idle time)'),
              ('run_queue', 'tasks waiting to run'),
              ('tasks', 'tasks'),
              ('streams', 'streams now'),
              ('stopping', '1 while HAProxy is stopping (an old process after a reload), else 0'),
              ('fd_limit', 'open files it may hold'),
              ('pool_used_bytes', 'memory its pools use'),
              ('pool_failed_count', 'memory it asked for and did not get (a running total)'),
              ('dropped_logs_count', 'log lines it dropped (a running total)'),
              ('failed_resolutions_count', 'DNS resolutions that failed (a running total)'),
              ('warnings', 'warnings since it started (its configuration, its limits)'),
              ('bytes_out_rate', 'bytes sent a second'),
              ('peers_active', 'stick-table peers known'),
              ('peers_connected', 'of those, connected')),
    healthy='up 1; connections_pct below 70; busy_pct below 70; pool_failed_count, dropped_logs_count flat.',
    watch='maxconn_reached_count rising; ssl_reuse_pct falling (each full handshake costs CPU); run_queue '
          'above 0 for long; peers_connected below peers_active.',
    act='up 0; connections_pct near 100: new connections wait in the kernel; busy_pct near 100: HAProxy '
        'is out of CPU; pool_failed_count rising: out of memory.',
    sh=r'''ask 'show info'
case $? in 0) ;; *) echo "metric up 0"; exit 0 ;; esac
grep -q '^Name: HAProxy' "$work/answer" || { echo "$job: that socket is not HAProxy's runtime API" >&2; exit 1; }
awk -F': ' '
    { v[$1] = $2 }
    function num(x) { return (x ~ /^-?[0-9]+([.][0-9]+)?$/) ? x : 0 }
    function p(m, k) { if (k in v) print "metric " m " " num(v[k]) }
    END {
        print "metric up 1"
        ver = v["Version"]; gsub(/[^A-Za-z0-9@._:\/+-]/, "_", ver)
        print "metric info 1 version=" ver
        p("uptime_seconds", "Uptime_sec"); p("threads", "Nbthread")
        p("connections", "CurrConns"); p("maxconn", "Maxconn")
        if (v["Maxconn"] > 0) printf "metric connections_pct %.2f\n", 100 * v["CurrConns"] / v["Maxconn"]
        p("maxconn_reached_count", "MaxconnReached")
        p("conn_rate", "ConnRate"); p("conn_rate_max", "MaxConnRate"); p("sess_rate", "SessRate")
        p("requests_count", "CumReq"); p("ssl_rate", "SslRate"); p("ssl_connections", "CurrSslConns")
        p("ssl_key_rate", "SslFrontendKeyRate"); p("ssl_reuse_pct", "SslFrontendSessionReuse_pct")
        p("ssl_cache_misses_count", "SslCacheMisses")
        if ("Idle_pct" in v) print "metric busy_pct " 100 - v["Idle_pct"]
        p("run_queue", "Run_queue"); p("tasks", "Tasks"); p("streams", "CurrStreams"); p("stopping", "Stopping")
        p("fd_limit", "Ulimit-n"); p("pool_used_bytes", "PoolUsed_bytes"); p("pool_failed_count", "PoolFailed")
        p("dropped_logs_count", "DroppedLogs"); p("failed_resolutions_count", "FailedResolutions")
        p("warnings", "TotalWarnings"); p("bytes_out_rate", "BytesOutRate")
        p("peers_active", "ActivePeers"); p("peers_connected", "ConnectedPeers")
    }' "$work/answer"
exit 0
''',
    exit_sh="0 on success, HAProxy up or down; 1 if the socket refuses this account or the question, or "
            "is not HAProxy's")

job(pack='haproxy', job='frontends', metric='frontends', when='run_every   = 1m', runtime='30s', env=ENV,
    needs_sh=[],
    title="HAProxy's frontends: what clients reach",
    what="Reports each frontend: whether it is open, its sessions against its limit, its session and "
         "request rates, its requests and answers by status class, the requests and answers it denied, "
         "requests it could not read, bytes in and out, and TLS handshakes that failed.",
    reads=READS + ' It sends "show stat".',
    metrics=M(('up', '1 when HAProxy answers, else 0'),
              ('frontends', 'frontends'),
              ('frontends_closed', 'of those, not open (stopped or full)'),
              ('open', '1 when it is open, else 0, tagged frontend=<its name>'),
              ('sessions', 'sessions now, tagged frontend'),
              ('sessions_limit', 'the most it accepts, tagged frontend'),
              ('sessions_pct', 'sessions as a percentage of the limit, tagged frontend'),
              ('session_rate', 'sessions a second, tagged frontend'),
              ('session_rate_max', 'the most a second, tagged frontend'),
              ('request_rate', 'HTTP requests a second, tagged frontend'),
              ('requests_count', 'HTTP requests (a running total), tagged frontend'),
              ('status_1xx_count', 'answers 1xx (a running total), tagged frontend'),
              ('status_2xx_count', 'answers 2xx, tagged frontend'),
              ('status_3xx_count', 'answers 3xx, tagged frontend'),
              ('status_4xx_count', 'answers 4xx, tagged frontend'),
              ('status_5xx_count', 'answers 5xx, tagged frontend'),
              ('denied_requests_count', 'requests denied by its rules, tagged frontend'),
              ('denied_responses_count', 'answers denied, tagged frontend'),
              ('request_errors_count', 'requests it could not read (bad, cut, timed out), tagged frontend'),
              ('bytes_in_count', 'bytes received, tagged frontend'),
              ('bytes_out_count', 'bytes sent, tagged frontend'),
              ('ssl_failed_handshakes_count', 'TLS handshakes that failed, tagged frontend'),
              ('frontends_not_shown', 'frontends past the first 50, left out')),
    healthy='every open 1; sessions_pct below 70; status_5xx_count flat (graph the _count totals as rates).',
    watch='request_errors_count or ssl_failed_handshakes_count rising: clients, or scanners, failing; '
          'denied_requests_count rising: a rule blocking more than before.',
    act='open 0: that frontend accepts nothing; sessions_pct near 100: new clients wait; status_5xx_count '
        'rising: the backends fail (the backends job says which).',
    sh=r'''stat '
    f("svname") == "FRONTEND" {
        n++
        st = f("status"); o = (st == "OPEN") ? 1 : 0
        if (!o) closed++
        if (n > 50) next
        t = "frontend=" tag(f("pxname"))
        print "metric open " o " " t
        print "metric sessions " num(f("scur")) " " t
        if (f("slim") != "") {
            print "metric sessions_limit " num(f("slim")) " " t
            if (f("slim") > 0) printf "metric sessions_pct %.2f %s\n", 100 * f("scur") / f("slim"), t
        }
        print "metric session_rate " num(f("rate")) " " t
        print "metric session_rate_max " num(f("rate_max")) " " t
        print "metric request_rate " num(f("req_rate")) " " t
        print "metric requests_count " num(f("req_tot")) " " t
        for (c = 1; c <= 5; c++) print "metric status_" c "xx_count " num(f("hrsp_" c "xx")) " " t
        print "metric denied_requests_count " num(f("dreq")) " " t
        print "metric denied_responses_count " num(f("dresp")) " " t
        print "metric request_errors_count " num(f("ereq")) " " t
        print "metric bytes_in_count " num(f("bin")) " " t
        print "metric bytes_out_count " num(f("bout")) " " t
        if ("ssl_failed_handshake" in col) print "metric ssl_failed_handshakes_count " num(f("ssl_failed_handshake")) " " t
    }
    END {
        print "metric frontends " n + 0
        print "metric frontends_closed " closed + 0
        print "metric frontends_not_shown " (n > 50 ? n - 50 : 0)
    }'
exit 0
''',
    exit_sh="0 on success, HAProxy up or down; 1 if the socket refuses this account or the question")

job(pack='haproxy', job='backends', metric='backends', when='run_every   = 1m', runtime='30s', env=ENV,
    needs_sh=[],
    title="HAProxy's backends: where requests go",
    what="Reports each backend: whether it is up, its servers (up, active, backup), its sessions and queue, "
         "how long requests wait in the queue, take to connect, to be answered and in all (averages of the "
         "last 1024), the connection and response errors, retries and redispatches, its answers 4xx and "
         "5xx, aborts by clients and by servers, and how long it has been down. The down ones first.",
    reads=READS + ' It sends "show stat".',
    metrics=M(('up', '1 when HAProxy answers, else 0'),
              ('backends', 'backends'),
              ('backends_down', 'of those, down: no server to send to'),
              ('backend_up', '1 when it is up, else 0, tagged backend=<its name>'),
              ('servers', 'its servers, tagged backend'),
              ('servers_up', 'of those, up, tagged backend'),
              ('servers_active', 'active servers up (its weight goes to them), tagged backend'),
              ('servers_backup', 'backup servers up, tagged backend'),
              ('sessions', 'sessions now, tagged backend'),
              ('queue', 'requests waiting for a server, tagged backend'),
              ('queue_max', 'the most that waited, tagged backend'),
              ('queue_ms', 'time waiting in the queue, on average, tagged backend'),
              ('connect_ms', 'time to connect to a server, on average, tagged backend'),
              ('response_ms', 'time to the first byte of the answer, on average, tagged backend'),
              ('total_ms', 'time for the whole request, on average, tagged backend'),
              ('connection_errors_count', 'connections to a server that failed (a running total), tagged backend'),
              ('response_errors_count', 'answers that failed, tagged backend'),
              ('retries_count', 'connections retried, tagged backend'),
              ('redispatches_count', 'requests sent to another server after a failure, tagged backend'),
              ('status_4xx_count', 'answers 4xx, tagged backend'),
              ('status_5xx_count', 'answers 5xx, tagged backend'),
              ('client_aborts_count', 'transfers the client cut, tagged backend'),
              ('server_aborts_count', 'transfers the server cut, tagged backend'),
              ('down_seconds', 'down in all since HAProxy started, tagged backend'),
              ('since_change_seconds', 'since it last went up or down, tagged backend'),
              ('backends_not_shown', 'backends past the first 100, left out')),
    healthy='backends_down 0; queue 0; response_ms steady; connection_errors_count flat.',
    watch='servers_up below servers; queue above 0 (every server at its maxconn); response_ms climbing; '
          'retries_count or redispatches_count rising.',
    act='backends_down above 0, or backend_up 0: its requests get 503; status_5xx_count or '
        'response_errors_count rising: the servers fail.',
    sh=r'''stat '
    f("svname") != "FRONTEND" && f("svname") != "BACKEND" && f("type") == 2 {
        b = f("pxname"); total[b]++
        if (f("status") ~ /^UP/ || f("status") == "no check") up[b]++
    }
    f("svname") == "BACKEND" { nb++; name[nb] = f("pxname"); line[nb] = $0; isup[nb] = (f("status") ~ /^UP/) ? 1 : 0; if (!isup[nb]) down++ }
    END {
        print "metric backends " nb + 0
        print "metric backends_down " down + 0
        shown = 0
        for (pass = 0; pass <= 1; pass++)
            for (i = 1; i <= nb; i++) {
                if (isup[i] != pass) continue
                if (++shown > 100) continue
                $0 = line[i]
                b = name[i]; t = "backend=" tag(b)
                print "metric backend_up " isup[i] " " t
                print "metric servers " total[b] + 0 " " t
                print "metric servers_up " up[b] + 0 " " t
                print "metric servers_active " num(f("act")) " " t
                print "metric servers_backup " num(f("bck")) " " t
                print "metric sessions " num(f("scur")) " " t
                print "metric queue " num(f("qcur")) " " t
                print "metric queue_max " num(f("qmax")) " " t
                print "metric queue_ms " num(f("qtime")) " " t
                print "metric connect_ms " num(f("ctime")) " " t
                print "metric response_ms " num(f("rtime")) " " t
                print "metric total_ms " num(f("ttime")) " " t
                print "metric connection_errors_count " num(f("econ")) " " t
                print "metric response_errors_count " num(f("eresp")) " " t
                print "metric retries_count " num(f("wretr")) " " t
                print "metric redispatches_count " num(f("wredis")) " " t
                print "metric status_4xx_count " num(f("hrsp_4xx")) " " t
                print "metric status_5xx_count " num(f("hrsp_5xx")) " " t
                print "metric client_aborts_count " num(f("cli_abrt")) " " t
                print "metric server_aborts_count " num(f("srv_abrt")) " " t
                print "metric down_seconds " num(f("downtime")) " " t
                print "metric since_change_seconds " num(f("lastchg")) " " t
            }
        print "metric backends_not_shown " (nb > 100 ? nb - 100 : 0)
    }'
exit 0
''',
    exit_sh="0 on success, HAProxy up or down; 1 if the socket refuses this account or the question")

job(pack='haproxy', job='servers', metric='servers', when='run_every   = 1m', runtime='30s', env=ENV,
    needs_sh=[],
    title="HAProxy's servers and their health checks",
    what="Reports every server of every backend: its state (up, draining, in maintenance, down, not "
         "checked), its last health check (its result, its code, how long it took), how long since it "
         "changed and how long it has been down in all, how often its checks failed and it went down, its "
         "sessions against its limit, its queue, its time to answer, its 5xx and its errors, and its weight. "
         "The worst first.",
    reads=READS + ' It sends "show stat".',
    metrics=M(('up', '1 when HAProxy answers, else 0'),
              ('servers', 'servers, all backends together'),
              ('servers_up', 'of those, up'),
              ('servers_down', 'down'),
              ('servers_maint', 'in maintenance'),
              ('servers_drain', 'draining (taking no new sessions)'),
              ('state', '0 up, 1 draining or going down, 2 in maintenance, 3 down, 4 not checked; tagged '
                        'backend=<its name>, server=<its name> and status=<HAProxy\'s word>'),
              ('check', 'always 1, tagged backend, server and check=<its last check: L4OK, L7OK, L4TOUT, '
                        'L4CON, L7STS...> and code=<the HTTP code, when there is one>'),
              ('check_ms', 'how long its last check took, tagged backend and server'),
              ('since_change_seconds', 'since it last went up or down, tagged backend and server'),
              ('down_seconds', 'down in all since HAProxy started, tagged backend and server'),
              ('check_failures_count', 'checks that failed (a running total), tagged backend and server'),
              ('went_down_count', 'times it went down, tagged backend and server'),
              ('sessions', 'sessions now, tagged backend and server'),
              ('sessions_limit', 'the most it takes (maxconn), tagged backend and server'),
              ('queue', 'requests waiting for it, tagged backend and server'),
              ('response_ms', 'time to the first byte of its answer, on average, tagged backend and server'),
              ('status_5xx_count', 'its answers 5xx, tagged backend and server'),
              ('response_errors_count', 'its answers that failed, tagged backend and server'),
              ('connection_errors_count', 'connections to it that failed, tagged backend and server'),
              ('weight', 'its weight, tagged backend and server'),
              ('servers_not_shown', 'servers past the first 200, left out')),
    healthy='servers_down 0; every state 0.',
    watch='servers_drain or servers_maint above 0 after a deploy; check_failures_count rising on a server '
          'that stays up: it flaps; queue above 0.',
    act='servers_down above 0: state 3 says which, check what it failed (L4CON refused, L4TOUT no answer, '
        'L7STS a bad status); every server of a backend down: its requests get 503.',
    sh=r'''stat '
    function rank(s) {
        if (s == "UP") return 0
        if (s ~ /^UP / || s ~ /^(DRAIN|NOLB)/) return 1
        if (s ~ /^MAINT/) return 2
        if (s ~ /^DOWN/) return 3
        return 4
    }
    f("svname") != "FRONTEND" && f("svname") != "BACKEND" && f("type") == 2 {
        n++; st = f("status"); r = rank(st); line[n] = $0; rk[n] = r
        if (r == 0) up++; else if (r == 2) maint++; else if (r == 3) dn++
        if (st ~ /^(DRAIN|NOLB)/) drain++
    }
    END {
        print "metric servers " n + 0
        print "metric servers_up " up + 0
        print "metric servers_down " dn + 0
        print "metric servers_maint " maint + 0
        print "metric servers_drain " drain + 0
        shown = 0
        split("3 2 1 4 0", order, " ")
        for (o = 1; o <= 5; o++)
            for (i = 1; i <= n; i++) {
                if (rk[i] != order[o]) continue
                if (++shown > 200) continue
                $0 = line[i]
                t = "backend=" tag(f("pxname")) " server=" tag(f("svname"))
                print "metric state " rk[i] " " t " status=" tag(f("status"))
                # "* L4TOUT": a check is running; the last result is after the star.
                cs = f("check_status"); sub(/^\* */, "", cs)
                print "metric check 1 " t " check=" tag(cs) " code=" tag(f("check_code"))
                if (f("check_duration") != "") print "metric check_ms " num(f("check_duration")) " " t
                print "metric since_change_seconds " num(f("lastchg")) " " t
                print "metric down_seconds " num(f("downtime")) " " t
                print "metric check_failures_count " num(f("chkfail")) " " t
                print "metric went_down_count " num(f("chkdown")) " " t
                print "metric sessions " num(f("scur")) " " t
                if (f("slim") != "") print "metric sessions_limit " num(f("slim")) " " t
                print "metric queue " num(f("qcur")) " " t
                print "metric response_ms " num(f("rtime")) " " t
                print "metric status_5xx_count " num(f("hrsp_5xx")) " " t
                print "metric response_errors_count " num(f("eresp")) " " t
                print "metric connection_errors_count " num(f("econ")) " " t
                print "metric weight " num(f("weight")) " " t
            }
        print "metric servers_not_shown " (n > 200 ? n - 200 : 0)
    }'
exit 0
''',
    exit_sh="0 on success, HAProxy up or down; 1 if the socket refuses this account or the question")
