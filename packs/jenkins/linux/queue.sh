#!/usr/bin/env bash
#
# queue.sh - what is waiting in Jenkins' build queue, the oldest first, and
# why
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
# Each item of the queue (/queue/api/json): how long it has waited, and why,
# as Jenkins says it ("Waiting for next available executor on linux",
# "Build #12 is already in progress"). Past the oldest 100, the rest
# counted.
#
# Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
# in JENKINS_API_TOKEN (a secret), with curl and jq; the token goes to curl
# on its standard input, never on a command line. Over https, the
# certificate is checked against JENKINS_CACERT when it is set.
#
# Metrics:
#   up                1 when Jenkins answers, else 0
#   queue_length      items waiting
#   oldest_seconds    how long the oldest has waited
#   stuck             items waiting far longer than they should
#   waiting_seconds   how long one item has waited, tagged job=<the job's
#                     full name>, state=<stuck, blocked, buildable or
#                     waiting> and why=<Jenkins' reason>
#   items_not_shown   past the oldest 100, how many were left out
#
# Example output:
#   metric up 1
#
# Reading the results (starting points: tune them to the controller):
#   Healthy  queue_length near 0 most of the time; oldest_seconds in
#            seconds.
#   Watch    oldest_seconds in minutes with state=buildable: builds wait for
#            an executor (jenkins_status executors_busy_pct at 100); add
#            agents or executors.
#   Act      stuck above 0: a build that will not start (its label matches
#            no node online, every such node is offline); why says which.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Jenkins up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, or the address is not Jenkins

set -u

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "queue: $p not found: the jenkins pack reads Jenkins' API with curl and jq" >&2; exit 1; }
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
        *) echo "queue: $url$1: $(cat "$work/err")" >&2; return 1 ;;
    esac
    case $status in
        200) ;;
        401) echo "queue: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong" >&2; return 1 ;;
        403) return 3 ;;
        *) echo "queue: $url$1 answered HTTP $status" >&2; return 1 ;;
    esac
    if ! grep -qi '^x-jenkins:' "$work/head"; then
        echo "queue: $url answers, but not as Jenkins (no X-Jenkins header)" >&2
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
        3) echo "metric up 0"; echo "queue: this user may not read $1: give it Overall/Read, Job/Read and Agent/Read" >&2; exit 1 ;;
        *) echo "metric up 0"; exit 1 ;;
    esac
}

read_page '/queue/api/json?tree=items[inQueueSince,why,blocked,buildable,stuck,task[name,url]]'
now=$(date +%s)
jq -r --argjson now "$now" "$defs"'
    [.items[] | . + {age: ([($now - (.inQueueSince / 1000)), 0] | max)}] | sort_by(-.age) as $q |
    "metric queue_length \($q | length)",
    "metric oldest_seconds \(($q[0].age // 0) | floor)",
    "metric stuck \([$q[] | select(.stuck)] | length)",
    ($q[0:100][] |
        "metric waiting_seconds \(.age | floor) job=\(.task | fullname | safe) state=\(if .stuck then "stuck" elif .blocked then "blocked" elif .buildable then "buildable" else "waiting" end) why=\((.why // "none") | safe)"),
    "metric items_not_shown \([($q | length) - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
