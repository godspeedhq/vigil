#!/usr/bin/env bash
#
# labels.sh - each Jenkins label: its executors busy and idle, its nodes
# offline, the jobs tied to it
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
# Every label of every node (/computer/api/json, each node's labels): how
# much capacity it has and how much is in use. A job tied to a label runs
# only there: a label at 100% busy holds its jobs in the queue, whatever the
# rest of Jenkins has free.
#
# Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
# in JENKINS_API_TOKEN (a secret), with curl and jq; the token goes to curl
# on its standard input, never on a command line. Over https, the
# certificate is checked against JENKINS_CACERT when it is set.
#
# Metrics:
#   up                1 when Jenkins answers, else 0
#   labels            the labels
#   executors_total   executors with a label, on its nodes online, tagged
#                     label=<its name>
#   executors_busy    of those, running a build now
#   executors_idle    of those, idle
#   busy_pct          executors_busy, as a percentage of executors_total
#   nodes             nodes with the label
#   nodes_offline     of those, offline
#   tied_jobs         jobs tied to the label
#   labels_not_shown  past the first 100, how many were left out
#
# Example output:
#   metric up 1
#
# Reading the results (starting points: tune them to the controller):
#   Healthy  busy_pct below 80 most of the time; nodes_offline 0.
#   Watch    busy_pct at 100 for long stretches: the jobs tied to it wait
#            (jenkins_queue says which).
#   Act      executors_total 0 where tied_jobs is above 0: every node with
#            the label is offline, and its jobs will not run.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Jenkins up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, or the address is not Jenkins

set -u

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "labels: $p not found: the jenkins pack reads Jenkins' API with curl and jq" >&2; exit 1; }
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
        *) echo "labels: $url$1: $(cat "$work/err")" >&2; return 1 ;;
    esac
    case $status in
        200) ;;
        401) echo "labels: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong" >&2; return 1 ;;
        403) return 3 ;;
        *) echo "labels: $url$1 answered HTTP $status" >&2; return 1 ;;
    esac
    if ! grep -qi '^x-jenkins:' "$work/head"; then
        echo "labels: $url answers, but not as Jenkins (no X-Jenkins header)" >&2
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
        3) echo "metric up 0"; echo "labels: this user may not read $1: give it Overall/Read, Job/Read and Agent/Read" >&2; exit 1 ;;
        *) echo "metric up 0"; exit 1 ;;
    esac
}

read_page '/computer/api/json?tree=computer[offline,assignedLabels[name,busyExecutors,idleExecutors,totalExecutors,nodes[nodeName],tiedJobs[name]]]'
jq -r "$defs"'
    [.computer[] | .offline as $o | (.assignedLabels // [])[] | . + {nodeOffline: $o}] | group_by(.name) |
    map(.[0] + {offlineNodes: ([.[] | select(.nodeOffline)] | length)}) as $l |
    "metric labels \($l | length)",
    ($l[0:100][] |
        "label=\(.name | safe)" as $t |
        "metric executors_total \(.totalExecutors // 0) \($t)",
        "metric executors_busy \(.busyExecutors // 0) \($t)",
        "metric executors_idle \(.idleExecutors // 0) \($t)",
        (if (.totalExecutors // 0) > 0 then "metric busy_pct \(100 * .busyExecutors / .totalExecutors * 100 | round / 100) \($t)" else empty end),
        "metric nodes \((.nodes // []) | length) \($t)",
        "metric nodes_offline \(.offlineNodes) \($t)",
        "metric tied_jobs \((.tiedJobs // []) | length) \($t)"),
    "metric labels_not_shown \([($l | length) - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
