#!/usr/bin/env bash
#
# status.sh - an nginx server's connections and requests
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
# Reads nginx's stub_status page and reports what it says: its connections,
# reading, writing and waiting, and the connections and requests since nginx
# last started. It only reads: it changes nothing.
#
# Reads the page at NGINX_STATUS_URL (default http://127.0.0.1/nginx_status),
# which you turn on once: location = /nginx_status { stub_status; allow
# 127.0.0.1; deny all; }.
# What the scripts share is in _nginx.sh, beside this one.
#
# Metrics:
#   up                  1 when the page answers, else 0
#   active_connections  client connections now, waiting ones included
#   reading             connections reading a request
#   writing             connections writing a response
#   waiting             idle keep-alive connections
#   accepts_count       connections accepted (a running total)
#   handled_count       connections handled (a running total)
#   requests_count      requests served (a running total)
#   dropped_count       connections accepted but not handled (a running total)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric active_connections 6
#   metric reading 0
#   metric writing 5
#   metric waiting 1
#   metric accepts_count 240
#   metric handled_count 240
#   metric requests_count 311
#   metric dropped_count 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  up 1; dropped_count not rising; requests_count rising at your
#            usual rate (graph the _count totals as a rate).
#   Watch    active_connections near worker_connections times the workers (the
#            server job says how near).
#   Act      up 0; dropped_count rising, which means nginx is turning
#            connections away, usually at a resource limit.
#
# Requires: bash, curl
# Exit code: 0 on success, server up or down; 1 if curl is missing, or the
#   page answers but is not a stub_status page

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_nginx.sh"
needs curl

url=${NGINX_STATUS_URL:-http://127.0.0.1/nginx_status}
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
