#!/usr/bin/env bash
#
# builds.sh - the builds running now on Jenkins, the longest first, against
# how long they usually take
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
# Every build running on an executor (/computer/api/json), pipelines too
# (their flyweight executors): how long it has run, Jenkins' estimate from
# its last builds, how far past it, and whether Jenkins itself thinks it
# stuck. Past the longest 100, the rest counted.
#
# Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
# in JENKINS_API_TOKEN (a secret), with curl and jq; the token goes to curl
# on its standard input, never on a command line. Over https, the
# certificate is checked against JENKINS_CACERT when it is set.
#
# Metrics:
#   up                  1 when Jenkins answers, else 0
#   running             builds running now
#   overdue             of those, running more than twice their estimate
#   likely_stuck        of those, that Jenkins thinks stuck (far past the
#                       time its builds take)
#   running_seconds     how long one build has run, tagged job=<the job's
#                       full name>, build=<its number> and node=<where it
#                       runs>
#   estimated_seconds   how long Jenkins expects it to take (from its last
#                       successful builds), tagged the same
#   estimate_pct        running_seconds, as a percentage of the estimate
#   progress_pct        how far along Jenkins thinks it is (0 to 99; none
#                       when it has no estimate)
#   stuck               1 when Jenkins thinks this build stuck, else 0
#   builds_not_shown    past the longest 100, how many were left out
#
# Example output:
#   metric up 1
#   metric running 1
#   metric overdue 1
#   metric likely_stuck 0
#   metric running_seconds 23 job=slow build=2 node=Built-In_Node
#   metric estimated_seconds 3 job=slow build=2 node=Built-In_Node
#   metric estimate_pct 725.97 job=slow build=2 node=Built-In_Node
#   metric progress_pct 99 job=slow build=2 node=Built-In_Node
#   metric stuck 0 job=slow build=2 node=Built-In_Node
#   metric builds_not_shown 0
#
# Reading the results (starting points: tune them to the controller):
#   Healthy  overdue and likely_stuck 0; estimate_pct below 150.
#   Watch    estimate_pct above 150: slower than usual (a slow agent, a
#            slow dependency, tests that grew).
#   Act      likely_stuck or overdue above 0, estimate_pct climbing run after
#            run: a build hung (waiting for input, a lock, a network call),
#            holding its executor.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Jenkins up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, or the address is not Jenkins

set -u

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "builds: $p not found: the jenkins pack reads Jenkins' API with curl and jq" >&2; exit 1; }
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
        *) echo "builds: $url$1: $(cat "$work/err")" >&2; return 1 ;;
    esac
    case $status in
        200) ;;
        401) echo "builds: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong" >&2; return 1 ;;
        403) return 3 ;;
        *) echo "builds: $url$1 answered HTTP $status" >&2; return 1 ;;
    esac
    if ! grep -qi '^x-jenkins:' "$work/head"; then
        echo "builds: $url answers, but not as Jenkins (no X-Jenkins header)" >&2
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
        3) echo "metric up 0"; echo "builds: this user may not read $1: give it Overall/Read, Job/Read and Agent/Read" >&2; exit 1 ;;
        *) echo "metric up 0"; exit 1 ;;
    esac
}

read_page '/computer/api/json?tree=computer[displayName,executors[likelyStuck,progress,currentExecutable[url,number,timestamp,estimatedDuration]],oneOffExecutors[likelyStuck,progress,currentExecutable[url,number,timestamp,estimatedDuration]]]'
now=$(date +%s)
jq -r --argjson now "$now" "$defs"'
    [.computer[] | .displayName as $n | ((.executors // []) + (.oneOffExecutors // []))[] |
        select(.currentExecutable != null and .currentExecutable.url != null) |
        .currentExecutable + {node: $n, stuckNow: (.likelyStuck == true), progress: (.progress // -1)}]
    | unique_by(.url)
    | map(. + {secs: ([($now - (.timestamp / 1000)), 0] | max), est: ((.estimatedDuration // -1) / 1000)})
    | sort_by(-.secs) as $b |
    "metric running \($b | length)",
    "metric overdue \([$b[] | select(.est > 0 and .secs > 2 * .est)] | length)",
    "metric likely_stuck \([$b[] | select(.stuckNow)] | length)",
    ($b[0:100][] |
        "job=\(. | fullname | sub("/[0-9]+$"; "") | safe) build=\(.number) node=\(.node | safe)" as $t |
        "metric running_seconds \(.secs | floor) \($t)",
        (if .est > 0 then "metric estimated_seconds \(.est | floor) \($t)", "metric estimate_pct \(100 * .secs / .est * 100 | round / 100) \($t)" else empty end),
        (if .progress >= 0 then "metric progress_pct \(.progress) \($t)" else empty end),
        "metric stuck \(if .stuckNow then 1 else 0 end) \($t)"),
    "metric builds_not_shown \([($b | length) - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
