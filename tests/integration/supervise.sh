#!/usr/bin/env bash
#
# Integration test: the supervisor (SPECIFICATION.md 4.1, 7, 8, 11.3) on
# Linux and macOS. Runs a real supervisor with a one-second tick against
# real jobs, then checks what it did: runs started, the concurrency limit
# held, overlaps skipped, a crashed run and an abandoned launch recorded,
# and a second supervisor refused.
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
check "a second supervisor is refused" 1 "$(vigil supervise --once > /dev/null 2>&1; echo $?)"
kill -TERM "$sup"
wait "$sup"
check "supervisor exits cleanly on TERM" 0 "$?"

# From here on nothing new may start: hourly slots are never due before the
# 2-second cursors. Let the last workers finish; one more tick reconciles them.
sed -i.bak "s/^run_every = 2s$/run_every = 1h/" "$root/config/vigil.config" && rm -f "$root/config/vigil.config.bak"
sleep 5
vigil supervise --once > /dev/null 2>&1

check "concurrency limit never broken" "" "$(cat "$root/overlap" 2>/dev/null)"
check "fast ran and succeeded" succeeded "$(state_value "$root/state/jobs/fast.state" status)"
check "slow ran and succeeded" succeeded "$(state_value "$root/state/jobs/slow.state" status)"
runs=$(ls "$root/spool/incoming" | grep -c -- '-fast-')
check "fast ran more than once" yes "$([ "$runs" -ge 2 ] && echo yes || echo "no ($runs)")"
check "slow overlaps were skipped" yes "$(cat "$root/spool/incoming/"*-supervisor.events | grep -q '^[0-9]* slow.skipped 1 count' && echo yes || echo no)"
check "heartbeat posted" yes "$(cat "$root/spool/incoming/"*-supervisor.events | grep -q '^[0-9]* vigil.supervisor.up 1 gauge host=' && echo yes || echo no)"
check "disabled job never ran" "" "$(ls "$root/state/jobs" | grep '^off')"
check "disabled job listed" yes "$(sed -n '/^DISABLED/,/^$/p' "$root/logs/supervisor/jobs.log" | grep -q '  off' && echo yes || echo no)"
check "no locks left" "" "$(ls "$root/state/locks")"
check "cursors kept" "fast.cursor slow.cursor" "$(ls "$root/state/schedule" | tr '\n' ' ' | sed 's/ $//')"

# A run whose worker vanished without an outcome is recorded as crashed.
boot=$(state_value "$root/state/jobs/fast.state" boot_id)
rid=20260101T000000Z-1-1
printf '[state]\nschema_version = 1\njob = fast\nrun_id = %s\nstatus = running\nboot_id = %s\nstarted_epoch = 1\n' "$rid" "$boot" > "$root/state/jobs/fast.state"
: > "$root/state/locks/fast.$rid.token"
vigil supervise --once > /dev/null 2>&1
check "vanished worker recorded as crashed" crashed "$(state_value "$root/state/jobs/fast.state" status)"
check "crash posted" yes "$(cat "$root/spool/incoming/"*-supervisor.events | grep -q '^[0-9]* fast.crashes 1 count' && echo yes || echo no)"
check "stale token removed" "" "$(ls "$root/state/locks")"
check "crash listed" yes "$(sed -n '/^CRASHED/,/^$/p' "$root/logs/supervisor/jobs.log" | grep -q '  fast' && echo yes || echo no)"

# A launch never claimed within the grace is abandoned; the job did not run.
rid=20260101T000000Z-1-2
printf '[launch]\njob           = slow\nrun_id        = %s\nboot_id       = %s\nlaunch_epoch  = 1\n' "$rid" "$boot" > "$root/state/locks/slow.$rid.launch"
vigil supervise --once > /dev/null 2>&1
check "old unclaimed launch abandoned" "" "$(ls "$root/state/locks" | grep "^slow.$rid")"
check "abandonment posted" yes "$(cat "$root/spool/incoming/"*-supervisor.events | grep -q '^[0-9]* slow.abandoned_launches 1 count' && echo yes || echo no)"

# A young launch is held: nothing else starts for the job.
now=$(date '+%s')
rid=20260101T000000Z-1-3
printf '[launch]\njob           = slow\nrun_id        = %s\nboot_id       = %s\nlaunch_epoch  = %s\n' "$rid" "$boot" "$now" > "$root/state/locks/slow.$rid.launch"
vigil supervise --once > /dev/null 2>&1
check "young launch kept" "slow.$rid.launch" "$(ls "$root/state/locks" | grep "^slow\.")"
check "job with a young launch is running" yes "$(sed -n '/^RUNNING/,/^$/p' "$root/logs/supervisor/jobs.log" | grep -q '  slow' && echo yes || echo no)"
rm -f "$root/state/locks/slow.$rid.launch"

if [ "$fail" -gt 0 ]; then
    printf '\nsupervisor log:\n'
    cat "$root/logs/supervisor/"*.log | tail -40
fi
rm -rf "$root"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
