#!/usr/bin/env bash
#
# servers.sh - HAProxy's servers and their health checks
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Reports every server of every backend: its state (up, draining, in
# maintenance, down, not checked), its last health check (its result, its
# code, how long it took), how long since it changed and how long it has been
# down in all, how often its checks failed and it went down, its sessions
# against its limit, its queue, its time to answer, its 5xx and its errors,
# and its weight. The worst first. It only reads: it changes nothing.
#
# Asks HAProxy's runtime API at HAPROXY_SOCKET: a socket file (by default the
# first of /run/haproxy/admin.sock, /var/lib/haproxy/stats,
# /var/run/haproxy.sock that is there), read with socat or nc, or a TCP
# address (127.0.0.1:9999), read by bash itself. A socket at level user is
# enough: stats socket ipv4@127.0.0.1:9999 level user. It sends "show stat".
# What the scripts share is in _haproxy.sh, beside this one.
#
# Metrics:
#   up                       1 when HAProxy answers, else 0
#   servers                  servers, all backends together
#   servers_up               of those, up
#   servers_down             down
#   servers_maint            in maintenance
#   servers_drain            draining (taking no new sessions)
#   state                    0 up, 1 draining or going down, 2 in maintenance,
#                            3 down, 4 not checked; tagged backend=<its name>,
#                            server=<its name> and status=<HAProxy's word>
#   check                    always 1, tagged backend, server and check=<its
#                            last check: L4OK, L7OK, L4TOUT, L4CON, L7STS...>
#                            and code=<the HTTP code, when there is one>
#   check_ms                 how long its last check took, tagged backend and
#                            server
#   since_change_seconds     since it last went up or down, tagged backend and
#                            server
#   down_seconds             down in all since HAProxy started, tagged backend
#                            and server
#   check_failures_count     checks that failed (a running total), tagged
#                            backend and server
#   went_down_count          times it went down, tagged backend and server
#   sessions                 sessions now, tagged backend and server
#   sessions_limit           the most it takes (maxconn), tagged backend and
#                            server
#   queue                    requests waiting for it, tagged backend and
#                            server
#   response_ms              time to the first byte of its answer, on average,
#                            tagged backend and server
#   status_5xx_count         its answers 5xx, tagged backend and server
#   response_errors_count    its answers that failed, tagged backend and
#                            server
#   connection_errors_count  connections to it that failed, tagged backend and
#                            server
#   weight                   its weight, tagged backend and server
#   servers_not_shown        servers past the first 200, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric servers 9
#   metric servers_up 4
#   metric servers_down 3
#   metric servers_maint 1
#   metric servers_drain 0
#   metric state 3 backend=be_dead server=gone status=DOWN
#   metric check 1 backend=be_dead server=gone check=L4TOUT code=none
#   metric check_ms 2001 backend=be_dead server=gone
#   metric since_change_seconds 109 backend=be_dead server=gone
#   metric down_seconds 109 backend=be_dead server=gone
#   metric check_failures_count 0 backend=be_dead server=gone
#   metric went_down_count 1 backend=be_dead server=gone
#   metric sessions 0 backend=be_dead server=gone
#   metric queue 0 backend=be_dead server=gone
#   metric response_ms 0 backend=be_dead server=gone
#
# Reading the results (starting points: tune them to the server):
#   Healthy  servers_down 0; every state 0.
#   Watch    servers_drain or servers_maint above 0 after a deploy;
#            check_failures_count rising on a server that stays up: it flaps;
#            queue above 0.
#   Act      servers_down above 0: state 3 says which, check what it failed
#            (L4CON refused, L4TOUT no answer, L7STS a bad status); every
#            server of a backend down: its requests get 503.
#
# Requires: bash
# Exit code: 0 on success, HAProxy up or down; 1 if the socket refuses this
#   account or the question

set -u

job=servers
# shellcheck source=/dev/null
. "$(dirname "$0")/_haproxy.sh"

stat '
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
