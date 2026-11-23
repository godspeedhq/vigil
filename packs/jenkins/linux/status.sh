#!/usr/bin/env bash
#
# status.sh - a Jenkins controller: up, its version, executors busy, the
# queue, nodes offline, and whether it is shutting down
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
# Reads Jenkins' REST API (/api/json, /computer/api/json, /queue/api/json)
# at JENKINS_URL, as JENKINS_USER with the API token in JENKINS_API_TOKEN (a
# secret), with curl and jq. A read-only user is enough: Overall/Read,
# Job/Read and Agent/Read. The token goes to curl on its standard input,
# never on a command line. Over https, the certificate is checked against
# JENKINS_CACERT when it is set, else the system's CAs.
#
# Metrics:
#   up                       1 when Jenkins answers, else 0
#   version                  always 1, tagged version=<Jenkins' version>
#   quieting_down            1 when it is preparing to shut down: no new
#                            build starts
#   executors_total          executors on every node online
#   executors_busy           of those, running a build now
#   executors_busy_pct       executors_busy, as a percentage of the total
#   queue_length             items waiting in the build queue
#   queue_buildable          of those, ready and waiting for an executor
#   queue_blocked            of those, blocked (by another build, or a
#                            resource)
#   queue_stuck              of those, waiting far longer than they should
#   nodes                    nodes: the built-in node and every agent
#   nodes_offline            of those, offline
#   nodes_temporarily_offline  of those, taken offline by someone
#
# Example output:
#   metric up 1
#   metric version 1 version=2.580.2
#   metric quieting_down 0
#   metric executors_total 2
#   metric executors_busy 1
#   metric executors_busy_pct 50
#   metric nodes 3
#   metric nodes_offline 2
#   metric nodes_temporarily_offline 1
#   metric queue_length 1
#   metric queue_buildable 1
#   metric queue_blocked 0
#   metric queue_stuck 1
#
# Reading the results (starting points: tune them to the controller):
#   Healthy  up 1; quieting_down 0; executors_busy_pct below 80 most of the
#            time; queue_stuck 0; nodes_offline only those taken offline
#            on purpose.
#   Watch    executors_busy_pct at 100 for long stretches, with
#            queue_buildable above 0: builds wait for executors; add
#            agents. nodes_temporarily_offline you did not expect.
#   Act      up 0; quieting_down 1 when no restart is planned: nothing new
#            builds; queue_stuck above 0: builds that will not start (a
#            label no node has, or every node for it offline);
#            nodes_offline rising.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Jenkins up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, or the address is not Jenkins

set -u

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "status: $p not found: the jenkins pack reads Jenkins' API with curl and jq" >&2; exit 1; }
done
url=${JENKINS_URL:-http://127.0.0.1:8080}
url=${url%/}
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-jenkins.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# get <path>: the body in $work/body, the headers in $work/head; 0, or 2
# when Jenkins does not answer (a reading), or 1 when it answers wrong
# (said on stderr). The login goes on curl's standard input.
get() {
    local code status
    {
        [ -n "${JENKINS_USER-}" ] && printf 'user = "%s:%s"\n' "$JENKINS_USER" "${JENKINS_API_TOKEN-}"
        [ -n "${JENKINS_CACERT-}" ] && printf 'cacert = "%s"\n' "$JENKINS_CACERT"
    } | curl -sS -g -m 30 -K - -D "$work/head" -o "$work/body" -w '%{http_code}' "$url$1" > "$work/code" 2> "$work/err"
    code=$?
    status=$(cat "$work/code" 2> /dev/null)
    case $code in
        0) ;;
        6 | 7 | 28 | 52 | 56) return 2 ;;
        *) echo "status: $url$1: $(cat "$work/err")" >&2; return 1 ;;
    esac
    case $status in
        200) ;;
        401 | 403) echo "status: Jenkins refused the login (HTTP $status): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong, or the user may not read $1" >&2; return 1 ;;
        *) echo "status: $url$1 answered HTTP $status" >&2; return 1 ;;
    esac
    if ! grep -qi '^x-jenkins:' "$work/head"; then
        echo "status: $url answers, but not as Jenkins (no X-Jenkins header)" >&2
        return 1
    fi
}

get '/api/json?tree=quietingDown'
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
echo "metric up 1"
version=$(sed -n 's/^[Xx]-[Jj]enkins: *\([0-9][0-9.]*\).*/\1/p' "$work/head" | head -n 1)
echo "metric version 1 version=${version:-unknown}"
jq -r '"metric quieting_down \(if .quietingDown then 1 else 0 end)"' "$work/body" || exit 1

get '/computer/api/json?tree=busyExecutors,totalExecutors,computer[offline,temporarilyOffline]' || exit 1
jq -r '
    "metric executors_total \(.totalExecutors)",
    "metric executors_busy \(.busyExecutors)",
    (if .totalExecutors > 0 then "metric executors_busy_pct \(100 * .busyExecutors / .totalExecutors * 100 | round / 100)" else empty end),
    "metric nodes \(.computer | length)",
    "metric nodes_offline \([.computer[] | select(.offline)] | length)",
    "metric nodes_temporarily_offline \([.computer[] | select(.temporarilyOffline)] | length)"
' "$work/body" || exit 1

get '/queue/api/json?tree=items[blocked,buildable,stuck]' || exit 1
jq -r '
    "metric queue_length \(.items | length)",
    "metric queue_buildable \([.items[] | select(.buildable)] | length)",
    "metric queue_blocked \([.items[] | select(.blocked)] | length)",
    "metric queue_stuck \([.items[] | select(.stuck)] | length)"
' "$work/body" || exit 1
exit 0
