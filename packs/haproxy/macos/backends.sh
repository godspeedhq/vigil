#!/usr/bin/env bash
#
# backends.sh - HAProxy's backends: where requests go
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
# Reports each backend: whether it is up, its servers (up, active, backup),
# its sessions and queue, how long requests wait in the queue, take to
# connect, to be answered and in all (averages of the last 1024), the
# connection and response errors, retries and redispatches, its answers 4xx
# and 5xx, aborts by clients and by servers, and how long it has been down.
# The down ones first. It only reads: it changes nothing.
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
#   backends                 backends
#   backends_down            of those, down: no server to send to
#   backend_up               1 when it is up, else 0, tagged backend=<its
#                            name>
#   servers                  its servers, tagged backend
#   servers_up               of those, up, tagged backend
#   servers_active           active servers up (its weight goes to them),
#                            tagged backend
#   servers_backup           backup servers up, tagged backend
#   sessions                 sessions now, tagged backend
#   queue                    requests waiting for a server, tagged backend
#   queue_max                the most that waited, tagged backend
#   queue_ms                 time waiting in the queue, on average, tagged
#                            backend
#   connect_ms               time to connect to a server, on average, tagged
#                            backend
#   response_ms              time to the first byte of the answer, on average,
#                            tagged backend
#   total_ms                 time for the whole request, on average, tagged
#                            backend
#   connection_errors_count  connections to a server that failed (a running
#                            total), tagged backend
#   response_errors_count    answers that failed, tagged backend
#   retries_count            connections retried, tagged backend
#   redispatches_count       requests sent to another server after a failure,
#                            tagged backend
#   status_4xx_count         answers 4xx, tagged backend
#   status_5xx_count         answers 5xx, tagged backend
#   client_aborts_count      transfers the client cut, tagged backend
#   server_aborts_count      transfers the server cut, tagged backend
#   down_seconds             down in all since HAProxy started, tagged backend
#   since_change_seconds     since it last went up or down, tagged backend
#   backends_not_shown       backends past the first 100, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric backends 4
#   metric backends_down 2
#   metric backend_up 0 backend=be_dead
#   metric servers 2 backend=be_dead
#   metric servers_up 0 backend=be_dead
#   metric servers_active 0 backend=be_dead
#   metric servers_backup 0 backend=be_dead
#   metric sessions 0 backend=be_dead
#   metric queue 0 backend=be_dead
#   metric queue_max 0 backend=be_dead
#   metric queue_ms 0 backend=be_dead
#   metric connect_ms 0 backend=be_dead
#   metric response_ms 0 backend=be_dead
#   metric total_ms 0 backend=be_dead
#   metric connection_errors_count 4 backend=be_dead
#
# Reading the results (starting points: tune them to the server):
#   Healthy  backends_down 0; queue 0; response_ms steady;
#            connection_errors_count flat.
#   Watch    servers_up below servers; queue above 0 (every server at its
#            maxconn); response_ms climbing; retries_count or
#            redispatches_count rising.
#   Act      backends_down above 0, or backend_up 0: its requests get 503;
#            status_5xx_count or response_errors_count rising: the servers
#            fail.
#
# Requires: bash
# Exit code: 0 on success, HAProxy up or down; 1 if the socket refuses this
#   account or the question

set -u

job=backends
# shellcheck source=/dev/null
. "$(dirname "$0")/_haproxy.sh"

stat '
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
