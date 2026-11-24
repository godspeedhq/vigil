#!/usr/bin/env bash
#
# frontends.sh - HAProxy's frontends: what clients reach
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
# Reports each frontend: whether it is open, its sessions against its limit,
# its session and request rates, its requests and answers by status class, the
# requests and answers it denied, requests it could not read, bytes in and
# out, and TLS handshakes that failed. It only reads: it changes nothing.
#
# Asks HAProxy's runtime API at HAPROXY_SOCKET: a socket file (by default the
# first of /run/haproxy/admin.sock, /var/lib/haproxy/stats,
# /var/run/haproxy.sock that is there), read with socat or nc, or a TCP
# address (127.0.0.1:9999), read by bash itself. A socket at level user is
# enough: stats socket ipv4@127.0.0.1:9999 level user. It sends "show stat".
# What the scripts share is in _haproxy.sh, beside this one.
#
# Metrics:
#   up                           1 when HAProxy answers, else 0
#   frontends                    frontends
#   frontends_closed             of those, not open (stopped or full)
#   open                         1 when it is open, else 0, tagged
#                                frontend=<its name>
#   sessions                     sessions now, tagged frontend
#   sessions_limit               the most it accepts, tagged frontend
#   sessions_pct                 sessions as a percentage of the limit, tagged
#                                frontend
#   session_rate                 sessions a second, tagged frontend
#   session_rate_max             the most a second, tagged frontend
#   request_rate                 HTTP requests a second, tagged frontend
#   requests_count               HTTP requests (a running total), tagged
#                                frontend
#   status_1xx_count             answers 1xx (a running total), tagged
#                                frontend
#   status_2xx_count             answers 2xx, tagged frontend
#   status_3xx_count             answers 3xx, tagged frontend
#   status_4xx_count             answers 4xx, tagged frontend
#   status_5xx_count             answers 5xx, tagged frontend
#   denied_requests_count        requests denied by its rules, tagged frontend
#   denied_responses_count       answers denied, tagged frontend
#   request_errors_count         requests it could not read (bad, cut, timed
#                                out), tagged frontend
#   bytes_in_count               bytes received, tagged frontend
#   bytes_out_count              bytes sent, tagged frontend
#   ssl_failed_handshakes_count  TLS handshakes that failed, tagged frontend
#   frontends_not_shown          frontends past the first 50, left out
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric open 1 frontend=fe_web
#   metric sessions 4 frontend=fe_web
#   metric sessions_limit 50 frontend=fe_web
#   metric sessions_pct 8.00 frontend=fe_web
#   metric session_rate 0 frontend=fe_web
#   metric session_rate_max 26 frontend=fe_web
#   metric request_rate 0 frontend=fe_web
#   metric requests_count 35 frontend=fe_web
#   metric status_1xx_count 0 frontend=fe_web
#   metric status_2xx_count 23 frontend=fe_web
#   metric status_3xx_count 0 frontend=fe_web
#   metric status_4xx_count 4 frontend=fe_web
#   metric status_5xx_count 4 frontend=fe_web
#   metric denied_requests_count 4 frontend=fe_web
#   metric denied_responses_count 0 frontend=fe_web
#
# Reading the results (starting points: tune them to the server):
#   Healthy  every open 1; sessions_pct below 70; status_5xx_count flat (graph
#            the _count totals as rates).
#   Watch    request_errors_count or ssl_failed_handshakes_count rising:
#            clients, or scanners, failing; denied_requests_count rising: a
#            rule blocking more than before.
#   Act      open 0: that frontend accepts nothing; sessions_pct near 100: new
#            clients wait; status_5xx_count rising: the backends fail (the
#            backends job says which).
#
# Requires: bash
# Exit code: 0 on success, HAProxy up or down; 1 if the socket refuses this
#   account or the question

set -u

job=frontends
# shellcheck source=/dev/null
. "$(dirname "$0")/_haproxy.sh"

stat '
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
