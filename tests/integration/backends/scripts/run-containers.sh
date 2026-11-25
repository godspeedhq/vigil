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
# run-containers.sh - the docker pack, or the podman pack, against a real
# engine holding containers in every state the pack reads, with its evidence
# kept like the other runs'.
#
#   scripts/run-containers.sh docker|podman
#
# It makes, on the engine of this machine (the account's own, for Podman),
# eleven small containers and two volumes, all labelled vigil.it=containers
# and named vigilit_*: one that runs with a memory limit and a volume, one
# healthy, one unhealthy, one in a restart loop, one that ended with code 7,
# one that ended well, one killed for memory, one paused, one never started,
# one busy at a CPU limit, and one that wrote 20 MB into its own layer. Every
# job is run and what it reads is checked; then a container is stopped and
# started, the loop is watched rising, the number of containers named is
# cut, and nothing answers. Then tests/integration/service-packs.sh runs the
# pack through Vigil. At the end only what this script made is removed: no
# other container, volume or image on the engine is touched, and nothing is
# pruned.
#
# On Linux and macOS (where the engine is in a VM: Docker Desktop, Colima,
# Lima, a podman machine). VIGIL_IT_CONTAINERS_HOLD=<file> keeps the
# containers until the file is removed, for another machine's or another
# shell's tests of the same engine.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

e=${1-}
case $e in docker | podman) ;; *) die 'usage: run-containers.sh docker|podman' ;; esac
for p in "$e" jq awk; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
[ "$e" = podman ] || command -v curl > /dev/null 2>&1 || die 'curl not found'
case $(uname -s) in Darwin) os=macos ;; *) os=linux ;; esac
img=${VIGIL_IT_CONTAINERS_IMAGE:-docker.io/library/busybox:1.37}
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-containers-it.XXXXXX") || exit 1
E=$(printf '%s' "$e" | tr '[:lower:]' '[:upper:]')

# Only what this script made: by its label.
clean() {
    local ids
    ids=$($e ps -aq --filter label=vigil.it=containers 2> /dev/null)
    # shellcheck disable=SC2086
    [ -z "$ids" ] || $e rm -f $ids > /dev/null 2>&1
    $e volume rm vigilit_data vigilit_unused > /dev/null 2>&1
}
trap 'clean; evidence_save; rm -rf "$work"' EXIT
evidence_start "pack-$e${VIGIL_IT_CONTAINERS_AS:+-$VIGIL_IT_CONTAINERS_AS}" "$0" "$0" "$@"

$e info > /dev/null 2>&1 || die "$e does not answer on this machine, as $(id -un)"
if [ "$e" = docker ]; then
    printf 'engine   Docker %s, %s, storage %s, cgroup v%s, as %s\n' "$(docker version --format '{{.Server.Version}}')" "$(docker info --format '{{.OperatingSystem}}')" "$(docker info --format '{{.Driver}}')" "$(docker info --format '{{.CgroupVersion}}')" "$(id -un)"
else
    printf 'engine   Podman %s, %s, rootless %s, cgroup %s, runtime %s, as %s\n' "$(podman version --format '{{.Version}}')" "$(podman info --format '{{.Host.Distribution.Distribution}} {{.Host.Distribution.Version}}')" "$(podman info --format '{{.Host.Security.Rootless}}')" "$(podman info --format '{{.Host.CgroupsVersion}}')" "$(podman info --format '{{.Host.OCIRuntime.Name}}')" "$(id -un)"
fi
printf 'here     %s, bash %s, jq %s\n' "$os" "$BASH_VERSION" "$(jq --version)"

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
# val <job> <reading> [<tags>]: its value; least compares it; has says
# whether such a line was printed; lines counts them.
val() { grep -E "^metric $2 [^ ]+( .*)?${3-}( |$)" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "${3-}")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2 [^ ]+( .*)?${3-}( |$)" "$work/$1.out" && echo yes || echo no; }
lines() { grep -cE "^metric $2 " "$work/$1.out"; }
quiet() {
    bash "$bk_repo/packs/$e/$os/$1.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
}
# run <job> [<label>]: the job's script, its output shown and kept. Other
# containers on the engine are read like any, and left out of what is
# shown: this run's are the ones named vigilit_*.
run() {
    printf '\n$ bash packs/%s/%s/%s.sh%s\n' "$e" "$os" "$1" "${2:+   ($2)}"
    quiet "$1"
    grep -nE '' "$work/$1.out" | grep -E '^[0-9]+:metric [^ ]+ [^ ]+$|^[0-9]+:metric version | name=vigilit_' | cut -d: -f2-
    others=$(grep -cE ' name=' "$work/$1.out")
    mine=$(grep -cE ' name=vigilit_' "$work/$1.out")
    [ "$others" -eq "$mine" ] || printf '  (and %s lines for the engine'"'"'s other containers and volumes, not shown)\n' "$((others - mine))"
    grep -v '^exit 0$' "$work/$1.err"
}
until_least() {
    local i=0
    while [ "$i" -lt "${5:-40}" ]; do
        quiet "$1"
        [ "$(least "$1" "$2" "$3" "$4")" = yes ] && return 0
        sleep 3
        i=$((i + 1))
    done
    return 1
}
jobs_of() { sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/$e/pack.config"; }

say "Eleven containers and two volumes, each in a state the pack reads."
clean
$e pull -q "$img" > /dev/null 2>&1 || die "cannot pull $img"
lab='--label vigil.it=containers'
mk() { "$@" > /dev/null 2> "$work/mk.err" || { cat "$work/mk.err"; die "cannot make a container: $*"; }; }
mk $e volume create --label vigil.it=containers vigilit_data
mk $e volume create --label vigil.it=containers vigilit_unused
# shellcheck disable=SC2086
{
    mk $e run -d $lab --name vigilit_ok --memory 64m --cpus 0.5 -v vigilit_data:/data "$img" sh -c 'while :; do dd if=/dev/zero of=/data/f bs=1k count=100 conv=fsync 2>/dev/null; sleep 1; done'
    mk $e run -d $lab --name vigilit_healthy --health-cmd true --health-interval 2s "$img" sleep 36000
    mk $e run -d $lab --name vigilit_unhealthy --health-cmd false --health-interval 2s --health-retries 2 "$img" sleep 36000
    mk $e run -d $lab --name vigilit_loop --restart always "$img" sh -c 'sleep 1; exit 3'
    mk $e run -d $lab --name vigilit_exit7 "$img" sh -c 'exit 7'
    mk $e run -d $lab --name vigilit_exit0 "$img" true
    mk $e run -d $lab --name vigilit_oom --memory 16m --memory-swap 16m "$img" sh -c 'a=x; while :; do a=$a$a; done'
    mk $e run -d $lab --name vigilit_paused "$img" sleep 36000
    mk $e pause vigilit_paused
    mk $e create $lab --name vigilit_created "$img" sleep 1
    mk $e run -d $lab --name vigilit_busy --cpus 0.3 "$img" sh -c 'while :; do :; done'
    mk $e run -d $lab --name vigilit_writes "$img" sh -c 'dd if=/dev/zero of=/big bs=1M count=20 2>/dev/null; sleep 36000'
}
$e ps -a --filter label=vigil.it=containers --format '{{.Names}}: {{.Status}}' | sort | sed 's/^/  /'
# The faults take a moment to show: the health check to fail twice, the
# loop to turn, the busy one to use its share.
until_least containers healthy 'name=vigilit_healthy' 1
for _ in $(seq 1 40); do quiet containers; [ "$(val containers healthy 'name=vigilit_unhealthy')" = 0 ] && break; sleep 3; done
until_least containers restarts_count 'name=vigilit_loop' 2
until_least resources cpu_seconds_count 'name=vigilit_busy' 3

say "Every job, as the $os scripts print it."
for j in $(jobs_of); do
    run "$j"
    check "$e $j: runs, and $e answers" 'exit 0 1' "$(tail -n 1 "$work/$j.err") $(val "$j" up)"
done

say "What each job must have read."
check 'status: the unhealthy one, the paused one, the one never started, and two that ended with an error are counted' 'yes yes yes yes' \
    "$(least status unhealthy '' 1) $(least status paused '' 1) $(least status created '' 1) $(least status exited_nonzero '' 2)"
check 'status: every container is counted, whatever its state' yes "$(least status containers '' 11)"
check 'containers: the one that runs, runs; the paused one and the one never started do not, and their state is said' '1 0 0' \
    "$(val containers running 'name=vigilit_ok state=running') $(val containers running 'name=vigilit_paused state=paused') $(val containers running 'name=vigilit_created state=created')"
check 'containers: healthy and unhealthy are told apart; one with no health check has no such reading' '1 0 no' \
    "$(val containers healthy 'name=vigilit_healthy') $(val containers healthy 'name=vigilit_unhealthy') $(has containers healthy 'name=vigilit_ok')"
check 'containers: exit codes, as they ended: 7, 0, and 137 for the one killed' '7 0 137' \
    "$(val containers exit_code 'name=vigilit_exit7') $(val containers exit_code 'name=vigilit_exit0') $(val containers exit_code 'name=vigilit_oom')"
check 'containers: the one killed for memory is named, and only that one' '1 0 0' \
    "$(val containers oom_killed 'name=vigilit_oom') $(val containers oom_killed 'name=vigilit_exit7') $(val containers oom_killed 'name=vigilit_ok')"
check 'containers: the loop has restarted, the others have not' 'yes 0' "$(least containers restarts_count 'name=vigilit_loop' 2) $(val containers restarts_count 'name=vigilit_ok')"
check 'containers: uptime for one that runs, none for one that stopped' 'yes no' "$(least containers uptime_seconds 'name=vigilit_ok' 5) $(has containers uptime_seconds 'name=vigilit_exit7')"
check 'containers: the totals count them' 'yes yes yes' "$(least containers containers_unhealthy '' 1) $(least containers containers_oom_killed '' 1) $(least containers containers_exited_nonzero '' 2)"
check 'resources: the limit of the one that has one (64 MB), and its memory as a share of it' '67108864 yes' "$(val resources memory_limit_bytes 'name=vigilit_ok') $(has resources memory_pct 'name=vigilit_ok')"
check 'resources: one with no limit: 0, and no share' '0 no' "$(val resources memory_limit_bytes 'name=vigilit_busy') $(has resources memory_pct 'name=vigilit_busy')"
check 'resources: the busy one has used CPU, far more than the idle one' 'yes yes' "$(least resources cpu_seconds_count 'name=vigilit_busy' 3) $(awk -v b="$(val resources cpu_seconds_count 'name=vigilit_busy')" -v h="$(val resources cpu_seconds_count 'name=vigilit_writes')" 'BEGIN { print (b > h * 5) ? "yes" : "no" }')"
check 'resources: memory and processes for each' 'yes yes' "$(least resources memory_bytes 'name=vigilit_ok' 1) $(least resources pids 'name=vigilit_ok' 1)"
check 'resources: only running containers are measured' 'no no' "$(has resources memory_bytes 'name=vigilit_exit7') $(has resources memory_bytes 'name=vigilit_created')"
[ "$e" = docker ] && check 'resources: the busy one is held back at its CPU limit, and that is counted' 'yes yes' "$(least resources cpu_throttled_seconds_count 'name=vigilit_busy' 1) $(least resources cpu_throttled_containers '' 1)"
check 'disk: the 20 MB one container wrote in its own layer' yes "$(least disk container_bytes 'name=vigilit_writes' 20000000)"
check 'disk: both volumes counted, and the one no container uses' 'yes yes' "$(least disk volumes '' 2) $(least disk volumes_unused '' 1)"
check 'disk: images and what they take' 'yes yes' "$(least disk images '' 1) $(least disk images_bytes '' 1000000)"
[ "$e" = docker ] && check 'disk: the volume in use is sized' yes "$(least disk volume_bytes 'name=vigilit_data' 1)"

say "A restart loop, watched: the count rises from one run to the next."
quiet containers
before=$(val containers restarts_count 'name=vigilit_loop')
sleep 8
run containers 'eight seconds later' | grep -E '^\$|vigilit_loop'
check 'the loop: restarts_count has risen' yes "$(awk -v a="$before" -v b="$(val containers restarts_count 'name=vigilit_loop')" 'BEGIN { print (b > a) ? "yes" : "no [" a " " b "]" }')"
if [ "$e" = docker ]; then
    quiet status
    check 'the loop: Docker counts it as restarting or running, never as stopped' yes "$(awk -v r="$(val status restarting)" -v n="$(val status running)" 'BEGIN { print (r + n >= 1) ? "yes" : "no" }')"
else
    quiet status
    check 'the loop: Podman shows it as running, and counts its restarts' 'yes' "$(least status restarts_total_count '' 2)"
fi

say "A container stops, and is started again."
$e stop -t 1 vigilit_ok > /dev/null 2>&1
run containers 'vigilit_ok stopped' | grep -E '^\$|name=vigilit_ok( |$)'
check 'stopped: running 0, its state and its exit code said' '0 yes' "$(val containers running 'name=vigilit_ok state=exited') $(has containers exit_code 'name=vigilit_ok')"
quiet resources
check 'stopped: no longer measured' no "$(has resources memory_bytes 'name=vigilit_ok')"
$e start vigilit_ok > /dev/null 2>&1
sleep 2
run containers 'vigilit_ok started again' | grep -E '^\$|name=vigilit_ok( |$)'
check 'started again: running 1, and a new uptime' '1 yes' "$(val containers running 'name=vigilit_ok state=running') $(awk -v u="$(val containers uptime_seconds 'name=vigilit_ok')" 'BEGIN { print (u != "" && u + 0 < 60) ? "yes" : "no [" u "]" }')"

say "More containers than a job names: the first few by name, the rest counted."
total=$(val containers containers)
env "${E}_MOST=3" bash "$bk_repo/packs/$e/$os/containers.sh" > "$work/most.out" 2>&1
check "${E}_MOST=3: three are named, and the rest are counted" "3 $((total - 3))" "$(grep -c '^metric running ' "$work/most.out") $(awk '$2 == "containers_not_shown" { print $3 }' "$work/most.out")"

say "Nothing answering."
for j in $(jobs_of); do
    if [ "$e" = docker ]; then
        DOCKER_HOST=unix://$work/nothing.sock bash "$bk_repo/packs/$e/$os/$j.sh" > "$work/down.out" 2>&1
    else
        CONTAINER_HOST=unix://$work/nothing.sock bash "$bk_repo/packs/$e/$os/$j.sh" > "$work/down.out" 2>&1
    fi
    check "$j: nothing answers: the job still runs, and reads up 0" '0 metric up 0' "$? $(cat "$work/down.out")"
done
if [ "$e" = docker ]; then
    DOCKER_HOST=tcp://127.0.0.1:2375 bash "$bk_repo/packs/$e/$os/status.sh" > "$work/bad.out" 2>&1
    check 'an address that is not a socket on this machine: refused, and said' '1 yes' "$? $(grep -q 'DOCKER_HOST is tcp://127.0.0.1:2375' "$work/bad.out" && echo yes || echo no)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
direct=$fail

say "The pack through Vigil."
if [ "$e" = docker ]; then
    host=${DOCKER_HOST:-unix:///var/run/docker.sock}
    export VIGIL_IT_DOCKER="DOCKER_HOST=$host" VIGIL_IT_DOCKER_DOWN="DOCKER_HOST=unix://$work/nothing.sock"
else
    export VIGIL_IT_PODMAN="CONTAINER_HOST=${CONTAINER_HOST-}" VIGIL_IT_PODMAN_DOWN="CONTAINER_HOST=unix://$work/nothing.sock"
fi
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?

if [ -n "${VIGIL_IT_CONTAINERS_HOLD-}" ]; then
    : > "$VIGIL_IT_CONTAINERS_HOLD"
    say "Held: the containers stay until $VIGIL_IT_CONTAINERS_HOLD is removed."
    while [ -e "$VIGIL_IT_CONTAINERS_HOLD" ]; do sleep 5; done
fi

say "Only what this run made is removed."
others_before=$($e ps -aq | wc -l | tr -d ' ')
clean
left=$($e ps -aq --filter label=vigil.it=containers | wc -l | tr -d ' ')
check 'this run'"'"'s eleven containers are gone, and no other was touched' "0 $((others_before - 11))" "$left $($e ps -aq | wc -l | tr -d ' ')"
[ "$direct" -eq 0 ] && [ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
