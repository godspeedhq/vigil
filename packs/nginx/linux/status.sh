#!/usr/bin/env bash
#
# status.sh - an nginx server's connections and requests
#
# Reads nginx's stub_status page, at NGINX_STATUS_URL (set by the job), and
# reports what it says. The totals are since nginx last started.
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
# Example output:
#   metric up 1
#   metric active_connections 3
#   metric reading 0
#   metric writing 1
#   metric waiting 2
#   metric accepts_count 18432
#   metric handled_count 18432
#   metric requests_count 52117
#   metric dropped_count 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  up 1; dropped_count not rising; requests_count rising at your
#            usual rate (graph the _count totals as a rate).
#   Watch    active_connections near worker_connections times the workers.
#   Act      up 0; dropped_count rising, which means nginx is turning
#            connections away, usually at a resource limit.
#
# Requires: bash, curl, and nginx's stub_status page
# Exit code: 0 on success, server up or down; 1 if curl is missing, or the
#   page answers but is not a stub_status page
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

set -u

url=${NGINX_STATUS_URL:-http://127.0.0.1/nginx_status}
command -v curl > /dev/null 2>&1 || { echo 'status: curl not found' >&2; exit 1; }

page=$(curl -sS -m 10 -f "$url" 2>&1)
rc=$?
# Nothing listening, or no answer in time: a reading, not a failure.
case $rc in
    0) ;;
    6 | 7 | 28)
        echo "metric up 0"
        exit 0
        ;;
    *)
        echo "status: $url did not give a stub_status page: $page" >&2
        exit 1
        ;;
esac

# Active connections: 3
# server accepts handled requests
#  18432 18432 52117
# Reading: 0 Writing: 1 Waiting: 2
active=$(printf '%s\n' "$page" | sed -n 's/^Active connections: *\([0-9]*\).*/\1/p')
set -- $(printf '%s\n' "$page" | sed -n '3s/^ *\([0-9]*\) *\([0-9]*\) *\([0-9]*\).*/\1 \2 \3/p')
accepts=${1-} handled=${2-} requests=${3-}
rww=$(printf '%s\n' "$page" | sed -n 's/^Reading: *\([0-9]*\) *Writing: *\([0-9]*\) *Waiting: *\([0-9]*\).*/\1 \2 \3/p')
if [ -z "$active" ] || [ -z "$requests" ] || [ -z "$rww" ]; then
    echo "status: $url is not a stub_status page" >&2
    exit 1
fi
set -- $rww

echo "metric up 1"
echo "metric active_connections $active"
echo "metric reading $1"
echo "metric writing $2"
echo "metric waiting $3"
echo "metric accepts_count $accepts"
echo "metric handled_count $handled"
echo "metric requests_count $requests"
echo "metric dropped_count $((accepts - handled))"
