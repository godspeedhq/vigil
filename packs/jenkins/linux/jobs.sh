#!/usr/bin/env bash
#
# jobs.sh - every Jenkins job, folders and multibranch pipelines too:
# failing, unstable or disabled, its health, its last ten builds, and how
# long since it last succeeded
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
# Every job (/api/json, four levels of folders deep): its last completed
# build's result, its health (Jenkins' weather), when it last succeeded and
# failed, its last ten builds. The worst first: failing, then unstable,
# then the longest without a success; past 100, the rest counted in the
# totals only.
#
# Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
# in JENKINS_API_TOKEN (a secret), with curl and jq; the token goes to curl
# on its standard input, never on a command line. Over https, the
# certificate is checked against JENKINS_CACERT when it is set.
#
# Metrics:
#   up                        1 when Jenkins answers, else 0
#   jobs                      the jobs (folders not counted)
#   failing                   of those, whose last completed build failed
#   unstable                  of those, whose last completed build was
#                             unstable (tests failed)
#   aborted                   of those, whose last completed build was
#                             aborted
#   disabled                  of those, disabled
#   never_built               of those, never built
#   building                  of those, building now
#   in_queue                  of those, waiting in the queue
#   builds_last_hour          builds started in the last hour (of each
#                             job's last ten)
#   failures_last_hour        of those, failed
#   job_failing               1 when one job's last completed build
#                             failed, else 0, tagged job=<its full name>
#   job_unstable              1 when it was unstable, tagged the same
#   health_score              Jenkins' health for it, 0 to 100 (its
#                             weather: the share of recent builds that
#                             passed), tagged the same
#   success_rate_pct          of its last ten completed builds, the share
#                             that succeeded
#   builds_since_success      builds since its last success
#   last_success_age_seconds  how long since its last successful build
#   last_failure_age_seconds  how long since its last failed build
#   last_build_age_seconds    how long since its last build started
#   last_duration_seconds     how long its last build took
#   jobs_not_shown            past the worst 100, how many were left out
#
# Example output:
#   metric up 1
#
# Reading the results (starting points: tune them to the controller):
#   Healthy  failing and unstable 0, or a known few; health_score high;
#            last_success_age_seconds recent for the jobs you build often.
#   Watch    unstable rising: tests failing; success_rate_pct falling: a
#            flaky job; builds_since_success above 0 for a job you release
#            from; a nightly job past a day and a half without a success.
#   Act      failing rising, or a job_failing you depend on (a release, a
#            deploy) 1; failures_last_hour climbing; last_duration_seconds
#            climbing build after build.
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Jenkins up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, or the address is not Jenkins

set -u

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "jobs: $p not found: the jenkins pack reads Jenkins' API with curl and jq" >&2; exit 1; }
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
        *) echo "jobs: $url$1: $(cat "$work/err")" >&2; return 1 ;;
    esac
    case $status in
        200) ;;
        401) echo "jobs: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong" >&2; return 1 ;;
        403) return 3 ;;
        *) echo "jobs: $url$1 answered HTTP $status" >&2; return 1 ;;
    esac
    if ! grep -qi '^x-jenkins:' "$work/head"; then
        echo "jobs: $url answers, but not as Jenkins (no X-Jenkins header)" >&2
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
        3) echo "metric up 0"; echo "jobs: this user may not read $1: give it Overall/Read, Job/Read and Agent/Read" >&2; exit 1 ;;
        *) echo "metric up 0"; exit 1 ;;
    esac
}

read_page '/api/json?tree=jobs[name,url,color,inQueue,healthReport[score],lastBuild[number,result,timestamp,duration],lastSuccessfulBuild[number,timestamp],lastFailedBuild[timestamp],lastCompletedBuild[result],builds[result,timestamp]{0,10},jobs[name,url,color,inQueue,healthReport[score],lastBuild[number,result,timestamp,duration],lastSuccessfulBuild[number,timestamp],lastFailedBuild[timestamp],lastCompletedBuild[result],builds[result,timestamp]{0,10},jobs[name,url,color,inQueue,healthReport[score],lastBuild[number,result,timestamp,duration],lastSuccessfulBuild[number,timestamp],lastFailedBuild[timestamp],lastCompletedBuild[result],builds[result,timestamp]{0,10},jobs[name,url,color,inQueue,healthReport[score],lastBuild[number,result,timestamp,duration],lastSuccessfulBuild[number,timestamp],lastFailedBuild[timestamp],lastCompletedBuild[result],builds[result,timestamp]{0,10}]]]]'
now=$(date +%s)
jq -r --argjson now "$now" "$defs"'
    def age(t): if t then ([($now - (t / 1000)), 0] | max) else -1 end;
    [.. | objects | select(has("color"))] as $all |
    [$all[] | . + {
        res: (.lastCompletedBuild.result // "NONE"),
        age: age(.lastSuccessfulBuild.timestamp),
        recent: [(.builds // [])[] | select(.result != null)]
    }] as $j |
    [$j[].builds // [] | .[] | select(.timestamp != null and ($now - .timestamp / 1000) < 3600)] as $hour |
    "metric jobs \($j | length)",
    "metric failing \([$j[] | select(.res == "FAILURE")] | length)",
    "metric unstable \([$j[] | select(.res == "UNSTABLE")] | length)",
    "metric aborted \([$j[] | select(.res == "ABORTED")] | length)",
    "metric disabled \([$j[] | select(.color == "disabled")] | length)",
    "metric never_built \([$j[] | select(.lastBuild == null)] | length)",
    "metric building \([$j[] | select(.color | tostring | endswith("_anime"))] | length)",
    "metric in_queue \([$j[] | select(.inQueue == true)] | length)",
    "metric builds_last_hour \($hour | length)",
    "metric failures_last_hour \([$hour[] | select(.result == "FAILURE")] | length)",
    ($j | sort_by([(if .res == "FAILURE" then 0 elif .res == "UNSTABLE" then 1 else 2 end), -.age]) | .[0:100][] |
        "job=\(. | fullname | safe)" as $t |
        "metric job_failing \(if .res == "FAILURE" then 1 else 0 end) \($t)",
        "metric job_unstable \(if .res == "UNSTABLE" then 1 else 0 end) \($t)",
        ((.healthReport // [])[0].score // empty | "metric health_score \(.) \($t)"),
        (if (.recent | length) > 0 then "metric success_rate_pct \(100 * ([.recent[] | select(.result == "SUCCESS")] | length) / (.recent | length) * 100 | round / 100) \($t)" else empty end),
        (if .lastBuild.number then "metric builds_since_success \(.lastBuild.number - (.lastSuccessfulBuild.number // 0)) \($t)" else empty end),
        (if .age >= 0 then "metric last_success_age_seconds \(.age | floor) \($t)" else empty end),
        (age(.lastFailedBuild.timestamp) | if . >= 0 then "metric last_failure_age_seconds \(floor) \($t)" else empty end),
        (age(.lastBuild.timestamp) | if . >= 0 then "metric last_build_age_seconds \(floor) \($t)" else empty end),
        (if .lastBuild.duration and .lastBuild.duration > 0 then "metric last_duration_seconds \(.lastBuild.duration / 1000 | floor) \($t)" else empty end)),
    "metric jobs_not_shown \([($j | length) - 100, 0] | max)"
' "$work/body" || exit 1
exit 0
