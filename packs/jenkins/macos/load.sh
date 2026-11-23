#!/usr/bin/env bash
#
# load.sh - Jenkins' own load averages: its queue and executors, over ten
# seconds, a minute and an hour
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
# Jenkins' load statistics (/overallLoad/api/json): what it has averaged
# itself, every ten seconds, minute and hour. Smoother than one reading:
# a queue that averaged 5 over the hour is a queue that never empties.
# Each is reported once Jenkins has averaged it (a minute or an hour after
# it started).
#
# Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
# in JENKINS_API_TOKEN (a secret), with curl and jq; the token goes to curl
# on its standard input, never on a command line. Over https, the
# certificate is checked against JENKINS_CACERT when it is set.
#
# Metrics:
#   up                    1 when Jenkins answers, else 0
#   queue_length          items in the queue that can run, on average,
#                         tagged window=<10s, 1m or 1h>
#   queue_length_total    every item in the queue, on average, tagged the
#                         same
#   executors_busy        executors busy, on average, tagged the same
#   executors_idle        executors idle, on average, tagged the same
#   executors_available   executors that could take a build, on average
#   executors_online      executors on nodes online, on average
#   executors_connecting  executors on nodes still connecting, on average
#   executors_defined     executors defined, online or not, on average
#   executors_total       executors in all, on average
#
# Example output:
#   metric up 1
#
# Reading the results (starting points: tune them to the controller):
#   Healthy  queue_length window=1h below 1; executors_busy window=1h
#            well below executors_online.
#   Watch    queue_length window=1h above 1: the queue rarely empties;
#            executors_busy close to executors_online for the hour.
#   Act      executors_connecting window=1h above 0 for long: agents that
#            cannot connect; executors_online falling against
#            executors_defined: nodes dropping.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Jenkins up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, or the address is not Jenkins

set -u

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "load: $p not found: the jenkins pack reads Jenkins' API with curl and jq" >&2; exit 1; }
done
url=${JENKINS_URL:-http://127.0.0.1:8080}
url=${url%/}
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-jenkins.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# get <path>: the body in $work/body; 0, or 2 when Jenkins does not answer
# (a reading), 3 when this user may not read the page, or 1 when it
# answers wrong (said on stderr). The login goes on curl's standard input.
get() {
    local code status
    {
        [ -n "${JENKINS_USER-}" ] && printf 'user = "%s:%s"\n' "$JENKINS_USER" "${JENKINS_API_TOKEN-}"
        [ -n "${JENKINS_CACERT-}" ] && printf 'cacert = "%s"\n' "$JENKINS_CACERT"
    } | curl -sS -g -m 60 -K - -D "$work/head" -o "$work/body" -w '%{http_code}' "$url$1" > "$work/code" 2> "$work/err"
    code=$?
    status=$(cat "$work/code" 2> /dev/null)
    case $code in
        0) ;;
        6 | 7 | 28 | 52 | 56) return 2 ;;
        *) echo "load: $url$1: $(cat "$work/err")" >&2; return 1 ;;
    esac
    case $status in
        200) ;;
        401) echo "load: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong" >&2; return 1 ;;
        403) return 3 ;;
        *) echo "load: $url$1 answered HTTP $status" >&2; return 1 ;;
    esac
    if ! grep -qi '^x-jenkins:' "$work/head"; then
        echo "load: $url answers, but not as Jenkins (no X-Jenkins header)" >&2
        return 1
    fi
}

# jq helpers: a tag's value, and a job's full name from its URL.
defs='def safe: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | if . == "" then "none" else .[0:120] end;
      def fullname: (.url // "") | sub("^.*?/job/"; "") | gsub("/job/"; "/") | sub("/$"; "") | if . == "" then "none" else . end;'

# up, from the page this job reads.
read_page() {
    get "$1"
    case $? in
        0) echo "metric up 1" ;;
        2) echo "metric up 0"; exit 0 ;;
        3) echo "metric up 0"; echo "load: this user may not read $1: give it Overall/Read, Job/Read and Agent/Read" >&2; exit 1 ;;
        *) echo "metric up 0"; exit 1 ;;
    esac
}

read_page '/overallLoad/api/json?tree=queueLength[sec10[latest],min[latest],hour[latest]],totalQueueLength[sec10[latest],min[latest],hour[latest]],busyExecutors[sec10[latest],min[latest],hour[latest]],idleExecutors[sec10[latest],min[latest],hour[latest]],availableExecutors[sec10[latest],min[latest],hour[latest]],onlineExecutors[sec10[latest],min[latest],hour[latest]],connectingExecutors[sec10[latest],min[latest],hour[latest]],definedExecutors[sec10[latest],min[latest],hour[latest]],totalExecutors[sec10[latest],min[latest],hour[latest]]'
jq -r '
    ([["queueLength", "queue_length"], ["totalQueueLength", "queue_length_total"], ["busyExecutors", "executors_busy"], ["idleExecutors", "executors_idle"], ["availableExecutors", "executors_available"], ["onlineExecutors", "executors_online"], ["connectingExecutors", "executors_connecting"], ["definedExecutors", "executors_defined"], ["totalExecutors", "executors_total"]] | .[]) as [$k, $m] |
    (.[$k] // {}) as $s |
    ([["sec10", "10s"], ["min", "1m"], ["hour", "1h"]] | .[]) as [$w, $tag] |
    ($s[$w].latest // empty) | select(type == "number") |
    "metric \($m) \(. * 100 | round / 100) window=\($tag)"
' "$work/body" || exit 1
exit 0
