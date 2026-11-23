#!/usr/bin/env bash
#
# nodes.sh - each Jenkins node: online or not and why, its executors, and
# what Jenkins' own monitors say of it: disk, temporary space, memory, swap,
# response time, clock
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
# The built-in node and every agent, as /computer/api/json gives them.
# Jenkins shows its node monitors (disk, memory, swap, response time,
# clock) to administrators only: a read-only user gets the rest, and
# monitors_readable 0. A node a monitor took offline (free disk below its
# threshold, 1 GB by default) says so in its reason, which any user sees.
#
# Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
# in JENKINS_API_TOKEN (a secret), with curl and jq; the token goes to curl
# on its standard input, never on a command line. Over https, the
# certificate is checked against JENKINS_CACERT when it is set.
#
# Metrics:
#   up                    1 when Jenkins answers, else 0
#   nodes                 the nodes
#   monitors_readable     1 when Jenkins shows this user its node
#                         monitors (an administrator), else 0
#   online                1 when a node is online, else 0, tagged
#                         node=<its name> and, when offline, reason=<why>
#   temporarily_offline   1 when someone took it offline, tagged the same
#   executors             its executors
#   busy                  of those, running a build now
#   disk_free_bytes       free space where it keeps its workspace
#   disk_threshold_bytes  the free space below which Jenkins takes it offline
#   tmp_free_bytes        free space in its temporary folder
#   memory_free_bytes     free physical memory
#   memory_total_bytes    physical memory
#   swap_free_bytes       free swap
#   response_ms           how long it takes to answer Jenkins, on average
#   clock_diff_ms         its clock against the controller's
#   nodes_not_shown       past the first 100, how many were left out
#
# Example output:
#   metric up 1
#
# Reading the results (starting points: tune them to the controller):
#   Healthy  online 1 for every node you expect; disk_free_bytes far above
#            disk_threshold_bytes; clock_diff_ms within a second.
#   Watch    disk_free_bytes under twice disk_threshold_bytes: Jenkins will
#            take the node offline; response_ms in the seconds: the agent
#            or its network is struggling; swap_free_bytes falling.
#   Act      online 0 where temporarily_offline is 0: the node dropped
#            (its reason says why: the agent stopped, its disk filled);
#            clock_diff_ms in the minutes: builds and their logs disagree.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Jenkins up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, or the address is not Jenkins

set -u

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "nodes: $p not found: the jenkins pack reads Jenkins' API with curl and jq" >&2; exit 1; }
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
        *) echo "nodes: $url$1: $(cat "$work/err")" >&2; return 1 ;;
    esac
    case $status in
        200) ;;
        401) echo "nodes: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong" >&2; return 1 ;;
        403) return 3 ;;
        *) echo "nodes: $url$1 answered HTTP $status" >&2; return 1 ;;
    esac
    if ! grep -qi '^x-jenkins:' "$work/head"; then
        echo "nodes: $url answers, but not as Jenkins (no X-Jenkins header)" >&2
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
        3) echo "metric up 0"; echo "nodes: this user may not read $1: give it Overall/Read, Job/Read and Agent/Read" >&2; exit 1 ;;
        *) echo "metric up 0"; exit 1 ;;
    esac
}

read_page '/computer/api/json?tree=computer[displayName,offline,temporarilyOffline,offlineCauseReason,numExecutors,executors[idle],monitorData[*]]'
jq -r "$defs"'
    .computer as $c |
    "metric nodes \($c | length)",
    "metric monitors_readable \(if ([$c[] | (.monitorData // {}) | length] | add // 0) > 0 then 1 else 0 end)",
    ($c[0:100][] |
        (.displayName | safe) as $n |
        (.monitorData // {}) as $m |
        "node=\($n)" as $t |
        "metric online \(if .offline then 0 else 1 end) \($t)\(if .offline and (.offlineCauseReason // "") != "" then " reason=\(.offlineCauseReason | safe)" else "" end)",
        "metric temporarily_offline \(if .temporarilyOffline then 1 else 0 end) \($t)",
        "metric executors \(.numExecutors // 0) \($t)",
        "metric busy \([(.executors // [])[] | select(.idle == false)] | length) \($t)",
        ($m["hudson.node_monitors.DiskSpaceMonitor"] // empty | select(type == "object") |
            "metric disk_free_bytes \(.size) \($t)", "metric disk_threshold_bytes \(.threshold) \($t)"),
        ($m["hudson.node_monitors.TemporarySpaceMonitor"] // empty | select(type == "object") | "metric tmp_free_bytes \(.size) \($t)"),
        ($m["hudson.node_monitors.SwapSpaceMonitor"] // empty | select(type == "object") |
            "metric memory_free_bytes \(.availablePhysicalMemory) \($t)",
            "metric memory_total_bytes \(.totalPhysicalMemory) \($t)",
            "metric swap_free_bytes \(.availableSwapSpace) \($t)"),
        ($m["hudson.node_monitors.ResponseTimeMonitor"] // empty | select(type == "object") | "metric response_ms \(.average) \($t)"),
        ($m["hudson.node_monitors.ClockMonitor"] // empty | select(type == "object") | "metric clock_diff_ms \(.diff) \($t)")
    ),
    "metric nodes_not_shown \([($c | length) - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
