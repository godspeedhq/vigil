#!/usr/bin/env bash
#
# Integration test: the supervisor and the sender (SPECIFICATION.md 4.1,
# 4.5, 7, 8, 11.3) on Linux and macOS. Runs a real supervisor with a
# one-second tick against real jobs, then checks what it did through the
# file backend's Prometheus file: runs started, the concurrency limit held,
# overlaps skipped, a crashed run and an abandoned launch recorded, events
# for a backend type not implemented yet counted as dropped, and a second
# supervisor refused.
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

# Both jobs take the same in-flight marker: if they ever overlap, the
# concurrency limit of 1 was broken.
cat > "$root/scripts/work.sh" <<'EOF'
if ! mkdir "$IT_ROOT/inflight" 2>/dev/null; then echo overlap >> "$IT_ROOT/overlap"; fi
sleep "$1"
rmdir "$IT_ROOT/inflight" 2>/dev/null
echo "metric slept $1"
EOF

cat > "$root/config/vigil.config" <<EOF
[vigil]
instance       = sup
max_concurrent = 1

[scheduler]
tick = 1s

[backend.file]
path = metrics/vigil.prom

# Not implemented yet: its events are counted as dropped.
[backend.splunk]
token = env:SPLUNK_HEC_TOKEN

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.fast]
file      = scripts/work.sh
arg       = 0
env       = IT_ROOT=$root
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
sed -i.bak "s/^run_every = 2s$/run_every = 3650d/" "$root/config/vigil.config" && rm -f "$root/config/vigil.config.bak"
sleep 5
tick
tick

check "concurrency limit never broken" "" "$(cat "$root/overlap" 2>/dev/null)"
check "fast ran and succeeded" succeeded "$(state_value "$root/state/jobs/fast.state" status)"
check "slow ran and succeeded" succeeded "$(state_value "$root/state/jobs/slow.state" status)"
check "sender ran and succeeded" succeeded "$(state_value "$root/state/jobs/vigil_sender.state" status)"
runs=$(prom fast_runs_total)
check "fast ran more than once" yes "$([ "${runs:-0}" -ge 2 ] && echo yes || echo "no (${runs:-0})")"
check "fast succeeded counted" "$runs" "$(prom fast_succeeded_total)"
check "job metric delivered" 0 "$(prom fast_slept)"
check "slow overlaps were skipped" yes "$([ -n "$(prom slow_skipped_total)" ] && echo yes || echo no)"
check "heartbeat delivered" 1 "$(prom vigil_supervisor_up)"
check "unimplemented backend counted as dropped" yes "$(grep '^vigil_spool_dropped_total{backend="splunk".*reason="not_implemented"' "$root/metrics/vigil.prom" > /dev/null && echo yes || echo no)"
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
