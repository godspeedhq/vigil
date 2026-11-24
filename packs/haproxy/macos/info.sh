#!/usr/bin/env bash
#
# info.sh - an HAProxy process: its connections, rates, TLS and load
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
# Reports HAProxy itself: its version and uptime, its connections against
# maxconn and how often it reached it, its connection, session, request and
# TLS rates (and their peaks), TLS session reuse, how busy its threads are and
# its run queue, its memory pools and their failures, dropped logs, failed DNS
# resolutions, warnings and its stick-table peers. It only reads: it changes
# nothing.
#
# Asks HAProxy's runtime API at HAPROXY_SOCKET: a socket file (by default the
# first of /run/haproxy/admin.sock, /var/lib/haproxy/stats,
# /var/run/haproxy.sock that is there), read with socat or nc, or a TCP
# address (127.0.0.1:9999), read by bash itself. A socket at level user is
# enough: stats socket ipv4@127.0.0.1:9999 level user. It sends "show info".
# What the scripts share is in _haproxy.sh, beside this one.
#
# Metrics:
#   up                        1 when HAProxy answers, else 0
#   info                      always 1, tagged version=<its version>
#   uptime_seconds            since HAProxy started
#   threads                   threads
#   connections               connections now
#   maxconn                   the most it accepts (maxconn)
#   connections_pct           connections as a percentage of maxconn
#   maxconn_reached_count     times it reached maxconn (a running total)
#   conn_rate                 connections a second, now
#   conn_rate_max             the most a second since it started
#   sess_rate                 sessions a second
#   requests_count            requests (a running total)
#   ssl_rate                  TLS sessions a second
#   ssl_connections           TLS connections now
#   ssl_key_rate              full TLS handshakes a second (those that are not
#                             resumed)
#   ssl_reuse_pct             TLS sessions resumed, as a percentage
#   ssl_cache_misses_count    TLS session cache misses (a running total)
#   busy_pct                  how busy its threads are (100 less their idle
#                             time)
#   run_queue                 tasks waiting to run
#   tasks                     tasks
#   streams                   streams now
#   stopping                  1 while HAProxy is stopping (an old process
#                             after a reload), else 0
#   fd_limit                  open files it may hold
#   pool_used_bytes           memory its pools use
#   pool_failed_count         memory it asked for and did not get (a running
#                             total)
#   dropped_logs_count        log lines it dropped (a running total)
#   failed_resolutions_count  DNS resolutions that failed (a running total)
#   warnings                  warnings since it started (its configuration,
#                             its limits)
#   bytes_out_rate            bytes sent a second
#   peers_active              stick-table peers known
#   peers_connected           of those, connected
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric info 1 version=3.4.8-1b15b69
#   metric uptime_seconds 129
#   metric threads 4
#   metric connections 4
#   metric maxconn 200
#   metric connections_pct 2.00
#   metric maxconn_reached_count 0
#   metric conn_rate 0
#   metric conn_rate_max 46
#   metric sess_rate 0
#   metric requests_count 56
#   metric ssl_rate 0
#   metric ssl_connections 0
#   metric ssl_key_rate 0
#   metric ssl_reuse_pct 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  up 1; connections_pct below 70; busy_pct below 70;
#            pool_failed_count, dropped_logs_count flat.
#   Watch    maxconn_reached_count rising; ssl_reuse_pct falling (each full
#            handshake costs CPU); run_queue above 0 for long; peers_connected
#            below peers_active.
#   Act      up 0; connections_pct near 100: new connections wait in the
#            kernel; busy_pct near 100: HAProxy is out of CPU;
#            pool_failed_count rising: out of memory.
#
# Requires: bash
# Exit code: 0 on success, HAProxy up or down; 1 if the socket refuses this
#   account or the question, or is not HAProxy's

set -u

job=info
# shellcheck source=/dev/null
. "$(dirname "$0")/_haproxy.sh"

ask 'show info'
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
