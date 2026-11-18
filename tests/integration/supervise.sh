#!/usr/bin/env bash
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
# Integration test: the supervisor and the sender (SPECIFICATION.md 4.1,
# 4.5, 7, 8, 11.3) on Linux and macOS. Runs a real supervisor with a
# one-second tick against real jobs, then checks what it did through the
# file backend's Prometheus file: runs started, jobs running together with
# no ceiling, overlaps skipped, a crashed run and an abandoned launch
# recorded, events for a backend type not implemented yet counted as
# dropped, a second supervisor refused, and the faults of 22.4 tests 1, 2,
# 13, 17 and 24 (a corrupt or missing state file, a reboot, a launch from
# the previous boot).
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-sup.$$
pass=0
fail=0

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
    fi
}

state_value() {
    sed -n "s/^$2 *= \{0,1\}//p" "$1"
}

vigil() {
    "$BASH" "$vigil_cmd" --root "$root" "$@"
}

# One supervisor tick, then wait (up to 60s) for the sender it may have
# started, so the Prometheus file is current.
tick() {
    local i=0
    vigil supervise --once > /dev/null 2>&1
    while ls "$root/state/locks" 2>/dev/null | grep '^vigil_sender\.' > /dev/null; do
        i=$((i + 1))
        [ "$i" -ge 120 ] && break
        sleep 0.5
    done
}

# The value of series $1 (a name, or name{labels} prefix) in the file.
prom() {
    grep "^$1[{ ]" "$root/metrics/vigil.prom" 2>/dev/null | head -n 1 | sed 's/.* //'
}

printf 'bash %s\n' "$BASH_VERSION"
mkdir -p "$root/config" "$root/scripts"
root=$(cd "$root" && pwd)

# Both jobs take the same in-flight marker. Nothing caps how many run at
# once (8), and both start on the same slots, so slow (3s) and fast (1s)
# are in flight together whatever it takes each to start.
cat > "$root/scripts/work.sh" <<'EOF'
if ! mkdir "$IT_ROOT/inflight" 2>/dev/null; then echo overlap >> "$IT_ROOT/overlap"; fi
sleep "$1"
rmdir "$IT_ROOT/inflight" 2>/dev/null
echo "metric slept $1"
EOF

cat > "$root/config/vigil.config" <<EOF
[vigil]
instance = sup

[scheduler]
tick = 1s

[backend.file]
path = metrics/vigil.prom

# Not implemented yet: its events are counted as dropped.
[backend.newrelic]
api_key = env:NEW_RELIC_KEY

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.fast]
file      = scripts/work.sh
arg       = 1
env      = IT_ROOT=$root
run_every = 2s

[job.slow]
file      = scripts/work.sh
arg       = 3
env       = IT_ROOT=$root
run_every = 2s

[job.off]
file      = scripts/work.sh
run_every = 2s
enabled   = false
EOF

# Run a real supervisor for a while, then stop it.
"$BASH" "$vigil_cmd" --root "$root" supervise > "$root/supervise.out" 2>&1 &
sup=$!
sleep 20
# A loaded machine gives fast fewer chances: wait up to 40s more for a second run.
i=0
while [ "$i" -lt 40 ]; do
    runs=$(prom fast_runs_total)
    [ "${runs:-0}" -ge 2 ] && break
    sleep 1
    i=$((i + 1))
done
check "a second supervisor is refused" 1 "$(vigil supervise --once > /dev/null 2>&1; echo $?)"
kill -TERM "$sup"
wait "$sup"
check "supervisor exits cleanly on TERM" 0 "$?"

# From here on nothing new may start: 3650-day slots (the next one in
# 2029) are never due before the 2-second cursors. An hour would be crossed
# by a run at hh:59. Let the last workers finish; one more tick reconciles them.
# A run still waiting for a slot is kept across a restart (8), and would start.
rm -f "$root/state/pending"
sed -i.bak "s/^run_every = 2s$/run_every = 3650d/" "$root/config/vigil.config" && rm -f "$root/config/vigil.config.bak"
sleep 5
tick
tick

check "jobs run together: no ceiling" yes "$([ -s "$root/overlap" ] && echo yes || echo no)"
check "fast ran and succeeded" succeeded "$(state_value "$root/state/jobs/fast.state" status)"
check "slow ran and succeeded" succeeded "$(state_value "$root/state/jobs/slow.state" status)"
check "sender ran and succeeded" succeeded "$(state_value "$root/state/jobs/vigil_sender.state" status)"
runs=$(prom fast_runs_total)
check "fast ran more than once" yes "$([ "${runs:-0}" -ge 2 ] && echo yes || echo "no (${runs:-0})")"
check "fast succeeded counted" "$runs" "$(prom fast_succeeded_total)"
check "job metric delivered" 1 "$(prom fast_slept)"
check "slow overlaps were skipped" yes "$([ -n "$(prom slow_skipped_total)" ] && echo yes || echo no)"
check "heartbeat delivered" 1 "$(prom vigil_supervisor_up)"
check "unimplemented backend counted as dropped" yes "$(grep '^vigil_spool_dropped_total{backend="newrelic".*reason="not_implemented"' "$root/metrics/vigil.prom" > /dev/null && echo yes || echo no)"
check "disabled job never ran" "" "$(ls "$root/state/jobs" | grep '^off')"
check "disabled job listed" yes "$(sed -n '/^DISABLED/,/^$/p' "$root/logs/supervisor/jobs.log" | grep '  off' > /dev/null && echo yes || echo no)"
check "no locks left" "" "$(ls "$root/state/locks")"
check "cursors kept" "fast.cursor slow.cursor" "$(ls "$root/state/schedule" | tr '\n' ' ' | sed 's/ $//')"
check "file backend queue drained" "" "$(ls "$root/spool/backends/file" 2>/dev/null)"
check "no fan-out left over" "" "$(ls "$root/spool/fanout" 2>/dev/null)"

# A run whose worker vanished without an outcome is recorded as crashed.
boot=$(state_value "$root/state/jobs/fast.state" boot_id)
rid=20260101T000000Z-1-1
printf '[state]\nschema_version = 1\njob = fast\nrun_id = %s\nstatus = running\nboot_id = %s\nstarted_epoch = 1\n' "$rid" "$boot" > "$root/state/jobs/fast.state"
: > "$root/state/locks/fast.$rid.token"
tick
tick
check "vanished worker recorded as crashed" crashed "$(state_value "$root/state/jobs/fast.state" status)"
check "crash delivered" 1 "$(prom fast_crashes_total)"
check "stale token removed" "" "$(ls "$root/state/locks")"

# A run whose worker went before its final state, while the sender was
# copying its events: they are in fanout/, and still prove it finished.
rid=20260101T000000Z-1-4
printf '[state]\nschema_version = 1\njob = fast\nrun_id = %s\nstatus = running\nboot_id = %s\nstarted_epoch = 1\n' "$rid" "$boot" > "$root/state/jobs/fast.state"
: > "$root/state/locks/fast.$rid.token"
mkdir -p "$root/spool/fanout"
printf '1 fast.succeeded 1 count host=it\n' > "$root/spool/fanout/1-fast-$rid.events"
tick
check "run reconciled from its events in the fan-out" "succeeded|reconciled from the spool file" \
    "$(state_value "$root/state/jobs/fast.state" status)|$(state_value "$root/state/jobs/fast.state" reason)"

# A launch never claimed within the grace is abandoned; the job did not run.
rid=20260101T000000Z-1-2
printf '[launch]\njob           = slow\nrun_id        = %s\nboot_id       = %s\nlaunch_epoch  = 1\n' "$rid" "$boot" > "$root/state/locks/slow.$rid.launch"
tick
tick
check "old unclaimed launch abandoned" "" "$(ls "$root/state/locks" | grep "^slow.$rid")"
check "abandonment delivered" 1 "$(prom slow_abandoned_launches_total)"

# A young launch is held: nothing else starts for the job.
now=$(date '+%s')
rid=20260101T000000Z-1-3
printf '[launch]\njob           = slow\nrun_id        = %s\nboot_id       = %s\nlaunch_epoch  = %s\n' "$rid" "$boot" "$now" > "$root/state/locks/slow.$rid.launch"
vigil supervise --once > /dev/null 2>&1
check "young launch kept" "slow.$rid.launch" "$(ls "$root/state/locks" | grep "^slow\.")"
check "job with a young launch is running" yes "$(sed -n '/^RUNNING/,/^$/p' "$root/logs/supervisor/jobs.log" | grep '  slow' > /dev/null && echo yes || echo no)"
rm -f "$root/state/locks/slow.$rid.launch"

# vigil status from an account that cannot read the logs (backlog 40).
out=$(vigil status 2>&1)
rc=$?
check "status shows jobs.log" "0 yes" "$rc $(printf '%s\n' "$out" | grep '^Vigil .* at ' > /dev/null && echo yes || echo no)"
# vigil status --watch (backlog 57), given 5 seconds from its first frame
# (or until it ends, within a minute): prints how it ended, "running" when it
# was still going and was stopped, else its exit code. What it printed is in
# $root.watch.
watch_for() {
    "$BASH" "$vigil_cmd" --root "$root" status --watch > "$root.watch" 2>&1 &
    local p=$! i=0
    while kill -0 "$p" 2> /dev/null && ! grep '^every 2 s' "$root.watch" > /dev/null 2>&1 && [ "$i" -lt 120 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    i=0
    while kill -0 "$p" 2> /dev/null && [ "$i" -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
    if kill -0 "$p" 2> /dev/null; then
        kill "$p"
        wait "$p" 2> /dev/null
        echo running
    else
        wait "$p"
        echo $?
    fi
}
check "status --watch keeps going" running "$(watch_for)"
frames=$(grep -c '^every 2 s, Ctrl+C to stop: ' "$root.watch")
check "a frame every 2 seconds" yes "$([ "$frames" -ge 2 ] && echo yes || echo no)"
check "each with jobs.log" "$frames" "$(grep -c '^Vigil .* at ' "$root.watch")"
check "status --watch with more: usage" 64 "$(vigil status --watch now > /dev/null 2>&1; echo $?)"
if [ "$(id -u)" = 0 ]; then
    printf '  SKIP  status with logs it cannot read: root reads everything\n'
else
    chmod 000 "$root/logs/supervisor"
    out=$(vigil status 2>&1)
    rc=$?
    watched=$(watch_for)
    chmod 755 "$root/logs/supervisor"
    check "status --watch with logs it cannot read: refused, once" "1 1" "$watched $(grep -c 'cannot read' "$root.watch")"
    check "status with logs it cannot read: refused" 1 "$rc"
    check "saying why, not that there is no jobs.log yet" \
        "vigil: cannot read $root/logs/supervisor from this account: run vigil status as the account that installed Vigil (sudo for a system install)" \
        "$(printf '%s\n' "$out" | tail -n 1)"
    check "and nothing else about jobs.log" no "$(printf '%s\n' "$out" | grep 'no jobs.log yet' > /dev/null && echo yes || echo no)"
fi
rm -f "$root.watch"

# Orphaned (11.3, §22 item 14): kill a run's worker while its job keeps
# running. The job holds the run (fd 9), so no second run starts beside it,
# and jobs.log says ORPHANED; once the job ends, the run is concluded.
main_root=$root
root=$(mktemp -d "${TMPDIR:-/tmp}/vigil-orphan.XXXXXX")
mkdir -p "$root/config" "$root/scripts"
# The job runs until the test has checked it, not for a time a slow machine
# may outlast before the checks (49): it ends when long.stop appears, or after
# five minutes, so it never outlives a failed run.
stop=$root/scripts/long.stop
printf 'i=0\nwhile [ ! -f "%s" ] && [ "$i" -lt 300 ]; do sleep 1; i=$((i + 1)); done\necho metric done 1\n' "$stop" > "$root/scripts/long.sh"
printf '[vigil]\ninstance = orphan\n\n[runner.sh]\ncommand = /bin/sh\n\n[runners]\n.sh = sh\n\n[job.long]\nfile      = scripts/long.sh\nrun_every = 1s\n' > "$root/config/vigil.config"
st=$root/state/jobs/long.state
# The first tick may only schedule the job: tick until its run has started.
i=0
while [ -z "$(state_value "$st" job_pid 2>/dev/null)" ] && [ "$i" -lt 30 ]; do
    vigil supervise --once > /dev/null 2>&1
    sleep 1
    i=$((i + 1))
done
rid=$(state_value "$st" run_id)
wpid=$(state_value "$st" worker_pid)
jpid=$(state_value "$st" job_pid)
check "orphan: the run started" yes "$([ -n "$wpid" ] && [ -n "$jpid" ] && echo yes || echo no)"

# While that run is alive (22.4, 17, 1 and 2). The job is due every second,
# so a supervisor that lost track of the run would start another.
others() { ls "$root/state/locks" | grep '^long\.' | grep -vF "long.$rid."; }
# 17. The supervisor never writes a live run's state file.
sum=$(cksum < "$st")
vigil supervise --once > /dev/null 2>&1
vigil supervise --once > /dev/null 2>&1
check "17: a live run's state file is never written" "$sum" "$(cksum < "$st")"
# 1. Its state file corrupted: the run is found by its token and run id.
cp "$st" "$root/long.state.good"
printf 'not a state file\n' > "$st"
vigil supervise --once > /dev/null 2>&1
vigil supervise --once > /dev/null 2>&1
check "1: corrupt state: the job still runs" yes "$(kill -0 "$jpid" 2>/dev/null && kill -0 "$wpid" 2>/dev/null && echo yes || echo no)"
check "1: no run started beside it" '' "$(others)"
check "1: and its state file left as it is" 'not a state file' "$(cat "$st")"
# 2. Its state file deleted: the same.
rm -f "$st"
vigil supervise --once > /dev/null 2>&1
vigil supervise --once > /dev/null 2>&1
check "2: deleted state: the job still runs" yes "$(kill -0 "$jpid" 2>/dev/null && kill -0 "$wpid" 2>/dev/null && echo yes || echo no)"
check "2: no run started beside it" '' "$(others)"
check "2: and nothing writes it" no "$([ -e "$st" ] && echo yes || echo no)"
mv "$root/long.state.good" "$st"

kill -9 "$wpid" 2>/dev/null
i=0
while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
vigil supervise --once > /dev/null 2>&1
vigil supervise --once > /dev/null 2>&1
check "orphan: its job still runs" yes "$(kill -0 "$jpid" 2>/dev/null && echo yes || echo no)"
check "orphan: still the same run" "$rid" "$(state_value "$st" run_id)"
check "orphan: jobs.log says ORPHANED" yes "$(sed -n '/^ORPHANED$/,/^$/p' "$root/logs/supervisor/jobs.log" | grep -F "  long: run $rid, its worker (pid $wpid) is gone" > /dev/null && echo yes || echo no)"
: > "$stop"
i=0
while kill -0 "$jpid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
vigil supervise --once > /dev/null 2>&1
# From the supervisor's log: that tick may already have started the next
# run, whose worker rewrites the state file.
check "orphan: once the job ends, the run is concluded" yes "$(cat "$root/logs/supervisor/"*.log | grep -F "job long: run $rid crashed" > /dev/null && echo yes || echo no)"
check "orphan: and its token is gone" '' "$(ls "$root/state/locks" | grep -F "long.$rid.")"
# Let the next run end before cleaning up.
i=0
while ls "$root/state/locks" 2>/dev/null | grep '^long\.' > /dev/null && [ "$i" -lt 40 ]; do sleep 0.5; i=$((i + 1)); done
rm -rf "$root"

# A reboot (22.4, 13 and 24), as a boot id that is not this boot's: every
# run recorded as running then is concluded, and a launch record from then is
# abandoned at once, however young. Neither job is ever due, so no run of
# theirs rewrites what this checks.
root=$(mktemp -d "${TMPDIR:-/tmp}/vigil-reboot.XXXXXX")
mkdir -p "$root/config" "$root/scripts" "$root/state/locks" "$root/state/jobs"
printf 'echo metric done 1\n' > "$root/scripts/quick.sh"
printf '[vigil]\ninstance = reboot\n\n[runner.sh]\ncommand = /bin/sh\n\n[runners]\n.sh = sh\n\n' > "$root/config/vigil.config"
for j in one two three; do
    printf '[job.%s]\nfile      = scripts/quick.sh\nrun_every = 3650d\n\n' "$j" >> "$root/config/vigil.config"
done
# The processes of before the reboot: one that has ended.
sh -c 'exit 0' &
gone=$!
wait "$gone"
for j in one two; do
    printf '[state]\nschema_version = 1\njob = %s\nrun_id = 20260101T000000Z-1-%s\nstatus = running\nboot_id = before-the-reboot\nstarted_epoch = 1\njob_pid = %s\nworker_pid = %s\n' "$j" "$j" "$gone" "$gone" > "$root/state/jobs/$j.state"
    : > "$root/state/locks/$j.20260101T000000Z-1-$j.token"
done
printf '[launch]\njob           = three\nrun_id        = 20260101T000000Z-1-three\nboot_id       = before-the-reboot\nlaunch_epoch  = %s\n' "$(date '+%s')" > "$root/state/locks/three.20260101T000000Z-1-three.launch"
vigil supervise --once > /dev/null 2>&1
check "13: after a reboot, every run recorded as running is concluded" "crashed crashed" \
    "$(state_value "$root/state/jobs/one.state" status) $(state_value "$root/state/jobs/two.state" status)"
check "13: and their tokens are gone" '' "$(ls "$root/state/locks" | grep -e '^one\.' -e '^two\.')"
check "24: a launch from before the reboot is abandoned at once" '' "$(ls "$root/state/locks" | grep '^three\.')"
check "24: and logged" yes "$(cat "$root/logs/supervisor/"*.log | grep -F 'job three: launch 20260101T000000Z-1-three abandoned' > /dev/null && echo yes || echo no)"
check "24: never run" '' "$(ls "$root/state/jobs" | grep '^three')"
rm -rf "$root"

# Damaged numbers (11.3, backlog 44): a launch record whose epoch is not a
# number, a state file whose numbers are not, and an empty state file, next
# to a healthy job. Each is read as damage, never used in arithmetic: the
# supervisor carries on, the healthy job runs, the launch is abandoned, and
# both state files are quarantined and reported as state_corrupt.
root=$(mktemp -d "${TMPDIR:-/tmp}/vigil-damaged.XXXXXX")
mkdir -p "$root/config" "$root/scripts" "$root/state/locks" "$root/state/jobs"
printf 'echo metric done 1\n' > "$root/scripts/quick.sh"
printf '[vigil]\ninstance = damaged\n\n[backend.file]\npath = metrics/vigil.prom\n\n[runner.sh]\ncommand = /bin/sh\n\n[runners]\n.sh = sh\n\n' > "$root/config/vigil.config"
for j in ok launch nums empty; do
    printf '[job.%s]\nfile      = scripts/quick.sh\nrun_every = 1s\n\n' "$j" >> "$root/config/vigil.config"
done
printf '[launch]\njob           = launch\nrun_id        = 20260101T000000Z-1-1\nlaunch_epoch  = 17x\n' > "$root/state/locks/launch.20260101T000000Z-1-1.launch"
printf '[state]\nschema_version = 1\nstatus = running\nrun_id = 20260101T000000Z-1-2\nstarted_epoch = abc\ndeadline_epoch = 1\njob_pid = 08\nworker_pid = 99999999999\n' > "$root/state/jobs/nums.state"
: > "$root/state/jobs/empty.state"
out=$(vigil supervise --once 2>&1)
check "damaged: the tick carries on" 0 "$?"
check "damaged: and says nothing on stderr" '' "$(printf '%s' "$out" | grep -v '^$')"
# The first tick only schedules a new job (7.6): tick until ok has run.
i=0
while [ "$(state_value "$root/state/jobs/ok.state" status 2>/dev/null)" != succeeded ] && [ "$i" -lt 30 ]; do
    tick
    sleep 1
    i=$((i + 1))
done
check "damaged: the healthy job ran" succeeded "$(state_value "$root/state/jobs/ok.state" status)"
check "damaged: the launch with a bad epoch was abandoned" '' "$(ls "$root/state/locks" | grep -F 'launch.20260101T000000Z-1-1.')"
check "damaged: bad numbers quarantined" yes "$(ls "$root/state/quarantine" 2>/dev/null | grep '^nums\.' > /dev/null && echo yes || echo no)"
check "damaged: an empty state file quarantined" yes "$(ls "$root/state/quarantine" 2>/dev/null | grep '^empty\.' > /dev/null && echo yes || echo no)"
tick
check "damaged: state_corrupt reported for bad numbers" 1 "$(prom nums_state_corrupt_total)"
check "damaged: state_corrupt reported for an empty file" 1 "$(prom empty_state_corrupt_total)"
check "damaged: the abandoned launch reported" 1 "$(prom launch_abandoned_launches_total)"
if [ "$fail" -gt 0 ]; then cat "$root/logs/supervisor/"*.log | tail -20; fi
i=0
while ls "$root/state/locks" 2>/dev/null | grep -v '\.abandoned$' | grep . > /dev/null && [ "$i" -lt 40 ]; do sleep 0.5; i=$((i + 1)); done
rm -rf "$root"

# A rejected edit (16.3): the last valid configuration stays active, and so
# the runs it launches use it, not the file that was rejected.
root=$(mktemp -d "${TMPDIR:-/tmp}/vigil-rejected.XXXXXX")
root=$(cd "$root" && pwd)
mkdir -p "$root/config" "$root/scripts"
printf 'echo "metric done 1"\n' > "$root/scripts/quick.sh"
good='[vigil]\ninstance = rejected\n\n[scheduler]\ntick = 1s\n\n[runner.sh]\ncommand = /bin/sh\n\n[runners]\n.sh = sh\n\n[job.kept]\nfile      = scripts/quick.sh\nrun_every = 1s\n'
printf "$good" > "$root/config/vigil.config"
kept=$root/state/jobs/kept.state
"$BASH" "$vigil_cmd" --root "$root" supervise > "$root/supervise.out" 2>&1 &
rej_sup=$!
i=0
while [ "$(state_value "$kept" status 2>/dev/null)" != succeeded ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
before=$(state_value "$kept" run_id 2>/dev/null)
check "rejected edit: the job ran before it" yes "$([ -n "$before" ] && echo yes || echo no)"
# An unknown section rejects the whole file.
printf "$good\n[weird]\n" > "$root/config/vigil.config"
i=0
while ! cat "$root/logs/supervisor/"*-*.log 2>/dev/null | grep -q 'configuration rejected' && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
check "rejected edit: the supervisor rejects it" yes "$(cat "$root/logs/supervisor/"*-*.log 2>/dev/null | grep -q 'configuration rejected' && echo yes || echo no)"
# A run launched after the rejection must still run, with the last valid
# configuration.
rejected=$(state_value "$kept" run_id 2>/dev/null)
i=0
while [ "$i" -lt 60 ]; do
    now=$(state_value "$kept" run_id 2>/dev/null)
    [ "$now" != "$rejected" ] && [ "$now" != "$before" ] && [ "$(state_value "$kept" status 2>/dev/null)" = succeeded ] && break
    sleep 1
    i=$((i + 1))
done
check "rejected edit: later runs still run" yes "$([ "$(state_value "$kept" run_id 2>/dev/null)" != "$rejected" ] && [ "$(state_value "$kept" status 2>/dev/null)" = succeeded ] && echo yes || echo no)"
kill -TERM "$rej_sup"
wait "$rej_sup"
if [ "$fail" -gt 0 ]; then cat "$root/logs/supervisor/"*-*.log 2>/dev/null | tail -20; fi
i=0
while ls "$root/state/locks" 2>/dev/null | grep '^kept\.' > /dev/null && [ "$i" -lt 40 ]; do sleep 0.5; i=$((i + 1)); done
rm -rf "$root"
root=$main_root

if [ "$fail" -gt 0 ]; then
    printf '\nsupervisor log:\n'
    cat "$root/logs/supervisor/"*.log | tail -40
    printf '\nprom file:\n'
    cat "$root/metrics/vigil.prom" 2>/dev/null | head -60
    printf '\nsender log:\n'
    cat "$root/logs/jobs/vigil_sender/"*.log 2>/dev/null | tail -20
fi
# Let a sender started by the last tick finish before cleaning up.
sleep 3
rm -rf "$root"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
