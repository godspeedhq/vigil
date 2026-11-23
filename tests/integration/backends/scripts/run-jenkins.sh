#!/usr/bin/env bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# run-jenkins.sh - the jenkins pack against real Jenkins with trouble on
# purpose, with its evidence kept like the other runs'.
#
#   scripts/run-jenkins.sh
#
# It starts compose.jenkins.yaml's Jenkins (2.580.2 and 2.528.3 LTS), each
# set up by configs/services/jenkins/vigil.groovy: a read-only user with
# SystemRead (monitor), one without (reader), two agents that never
# connect (one taken offline by hand), jobs failing (one in a folder),
# unstable, disabled and never built, a build far past its estimate, and
# one waiting for a label no node has. The API tokens are read from each
# Jenkins with docker exec, into this run's own folder. Every job of the
# pack is run as monitor, while the long build runs, and what it reads is
# checked; then a user without SystemRead, a wrong token and a Jenkins that
# is down; then tests/integration/service-packs.sh runs the pack through
# Vigil. The Jenkins are taken down at the end.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: Jenkins runs in containers'
for p in curl jq; do command -v "$p" > /dev/null 2>&1 || die "$p not found: the pack reads Jenkins with curl and jq"; done
file=compose.jenkins.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-jenkins-it.XXXXXX") || exit 1
root=$work/none
dc() { docker compose -p vigil-jenkins --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
# Each token, as a value the evidence must not hold.
tokens() { for f in "$work"/*.token; do [ -f "$f" ] && cat "$f" && echo; done; }
# shellcheck disable=SC2046
trap 'dc down -v > /dev/null 2>&1; evidence_save $(tokens); rm -rf "$work"' EXIT
evidence_start pack-jenkins "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/jenkins/linux

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'Jenkins would not start'; }
for s in jk2580 jk2528; do
    for _ in $(seq 1 150); do docker exec "vigil-jenkins-$s-1" test -f /var/jenkins_home/vigil/ready 2> /dev/null && break; sleep 3; done
    docker exec "vigil-jenkins-$s-1" test -f /var/jenkins_home/vigil/ready 2> /dev/null || { dc logs --tail 20 "$s"; die "$s was not set up"; }
    # Its tokens, into this run's own folder (this account's alone).
    for u in monitor reader; do
        (umask 077 && docker exec "vigil-jenkins-$s-1" cat "/var/jenkins_home/vigil/$u-token" > "$work/$s-$u.token")
    done
done
printf 'jenkins  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }

# The long build: its second, 15 minutes against an estimate of 3 seconds.
for s in jk2580:18081 jk2528:18082; do
    port=${s#*:}
    for _ in $(seq 1 60); do
        printf 'user = "monitor:%s"\n' "$(cat "$work/${s%%:*}-monitor.token")" |
            curl -sg -K - "http://127.0.0.1:$port/job/slow/api/json?tree=lastBuild[number,building]" | jq -e '.lastBuild.number == 2 and .lastBuild.building' > /dev/null 2>&1 && break
        sleep 3
    done
done
sleep 20

jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/jenkins/pack.config")
for s in jk2580:18081:2.580.2 jk2528:18082:2.528.3; do
    name=${s%%:*} rest=${s#*:} port=${rest%%:*} version=${rest#*:}
    say "Jenkins $version: every job, as the pack's scripts print it, as monitor (read-only, and SystemRead)."
    export JENKINS_URL=http://127.0.0.1:$port JENKINS_USER=monitor
    export JENKINS_API_TOKEN; JENKINS_API_TOKEN=$(cat "$work/$name-monitor.token")
    for j in $jobs; do
        printf '\n$ bash packs/jenkins/linux/%s.sh\n' "$j"
        bash "$pack/$j.sh" > "$work/$j.out" 2> "$work/$j.err"
        printf 'exit %s\n' "$?" >> "$work/$j.err"
        cat "$work/$j.out"
        grep -v '^exit 0$' "$work/$j.err"
        cp "$work/$j.out" "$work/$name-$j.out"
    done

    say "Jenkins $version: what they read."
    for j in $jobs; do check "$name: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
    check "$name: answers" 1 "$(val status up '')"
    check "$name: Jenkins $version" 1 "$(val status version "version=${version//./\\.}\$")"
    check "$name: three nodes, two offline" '3 2' "$(val status nodes '') $(val status nodes_offline '')"
    check "$name: one taken offline by hand" 1 "$(val status nodes_temporarily_offline '')"
    check "$name: offline, and its reason" yes "$(grep -q '^metric online 0 node=maint-agent reason=patching__back_Monday$' "$work/nodes.out" && echo yes || echo no)"
    check "$name: since when" yes "$(least nodes offline_seconds 'node=maint-agent$' 1)"
    check "$name: the monitors, an administrator's only" 0 "$(val nodes monitors_readable '')"
    check "$name: the label whose nodes are all offline: no executors" '0 2' "$(val labels executors_total 'label=agents$') $(val labels nodes_offline 'label=agents$')"
    check "$name: the item waiting for a label no node has" yes "$(grep -qE '^metric waiting_seconds [0-9]+ job=waiting state=(stuck|buildable) why=There_are_no_nodes_with_the_label' "$work/queue.out" && echo yes || echo no)"
    check "$name: the long build, running" yes "$(least builds running '' 1)"
    check "$name: far past its estimate" 1 "$(val builds overdue '')"
    check "$name: its estimate_pct above 200" yes "$(least builds estimate_pct 'job=slow ' 200)"
    check "$name: two failing, one in a folder" '2 1' "$(val jobs failing '') $(val jobs job_failing 'job=team/nightly$')"
    check "$name: one unstable" 1 "$(val jobs unstable '')"
    check "$name: one disabled" 1 "$(val jobs disabled '')"
    check "$name: never built, at least two" yes "$(least jobs never_built '' 2)"
    check "$name: the failing job's health 0" 0 "$(val jobs health_score 'job=fail$')"
    check "$name: the passing job's last builds, all passed" 100 "$(val jobs success_rate_pct 'job=pass$')"
    check "$name: builds in the last hour" yes "$(least jobs builds_last_hour '' 5)"
    check "$name: its own load averages" yes "$(grep -q '^metric executors_defined [0-9.]* window=10s$' "$work/load.out" && echo yes || echo no)"
    check "$name: the plugins, with SystemRead" 1 "$(val plugins readable '')"
    check "$name: and how many" yes "$(least plugins plugins '' 20)"

    JENKINS_USER=reader JENKINS_API_TOKEN=$(cat "$work/$name-reader.token") bash "$pack/plugins.sh" > "$work/reader.out" 2>&1
    check "$name: a read-only user without SystemRead runs plugins" 0 "$?"
    check "$name: and reads readable 0" yes "$(grep -q '^metric readable 0$' "$work/reader.out" && echo yes || echo no)"
    JENKINS_API_TOKEN=not-the-token bash "$pack/status.sh" > "$work/wrong.out" 2>&1
    check "$name: a wrong token fails the run" 1 "$?"
    check "$name: and says so" yes "$(grep -q 'Jenkins refused the login (HTTP 401)' "$work/wrong.out" && echo yes || echo no)"
done
JENKINS_URL=http://127.0.0.1:1 bash "$pack/status.sh" > "$work/down.out" 2>&1
check 'a Jenkins that does not answer still runs' 0 "$?"
check 'and reads as up 0' yes "$(grep -q '^metric up 0$' "$work/down.out" && echo yes || echo no)"

say "The pack through Vigil."
export VIGIL_IT_JENKINS_URL=http://127.0.0.1:18081 VIGIL_IT_JENKINS_USER=monitor
export VIGIL_IT_JENKINS_TOKEN; VIGIL_IT_JENKINS_TOKEN=$(cat "$work/jk2580-monitor.token")
unset JENKINS_URL JENKINS_USER JENKINS_API_TOKEN
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
