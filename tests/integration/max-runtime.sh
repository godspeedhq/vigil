#!/usr/bin/env bash
#
# Integration test: max_runtime (SPECIFICATION.md 10.3, 11.5, 11.6) on
# Linux and macOS. A real supervisor stops two overrunning jobs: one that
# exits on TERM, and one that ignores TERM and is killed after grace. Both
# are recorded as timed_out, counted as timeouts, and leave nothing behind.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-mrt.$$
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

# One supervisor tick, then wait (up to 60s) for the sender it may start.
tick() {
    local i=0
    vigil supervise --once >> "$root/once.out" 2>&1; echo "rc=$?" >> "$root/once.out"
    while ls "$root/state/locks" 2>/dev/null | grep '^vigil_sender\.' > /dev/null; do
        i=$((i + 1))
        [ "$i" -ge 120 ] && break
        sleep 0.5
    done
}

prom() {
    grep "^$1[{ ]" "$root/metrics/vigil.prom" 2>/dev/null | head -n 1 | sed 's/.* //'
}

printf 'bash %s\n' "$BASH_VERSION"
mkdir -p "$root/config" "$root/scripts"
root=$(cd "$root" && pwd)

# Each job would finish after 30 seconds and leave a marker; neither may.
cat > "$root/scripts/long.sh" <<'EOF'
sleep 30
touch "$IT_ROOT/long.finished"
EOF
cat > "$root/scripts/stubborn.sh" <<'EOF'
trap '' TERM
sleep 30
touch "$IT_ROOT/stubborn.finished"
EOF

cat > "$root/config/vigil.config" <<EOF
[vigil]
instance       = mrt
max_concurrent = 5

[scheduler]
tick = 1s

[backend.file]
path = metrics/vigil.prom

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.long]
file        = scripts/long.sh
env         = IT_ROOT=$root
run_every   = 2s
max_runtime = 3s
grace       = 2s

[job.stubborn]
file        = scripts/stubborn.sh
env         = IT_ROOT=$root
run_every   = 2s
max_runtime = 3s
grace       = 2s
EOF

"$BASH" "$vigil_cmd" --root "$root" supervise > "$root/supervise.out" 2>&1 &
sup=$!
sleep 18
kill -TERM "$sup"
wait "$sup"

# No new runs from here on; let everything settle.
sed -i.bak "s/^run_every   = 2s$/run_every   = 1h/" "$root/config/vigil.config" && rm -f "$root/config/vigil.config.bak"
sleep 3
tick
tick

check "long recorded as timed_out" timed_out "$(state_value "$root/state/jobs/long.state" status)"
check "long reason" "stopped after max_runtime 3s" "$(state_value "$root/state/jobs/long.state" reason)"
check "stubborn recorded as timed_out" timed_out "$(state_value "$root/state/jobs/stubborn.state" status)"
check "deadline recorded" yes "$([ -n "$(state_value "$root/state/jobs/long.state" deadline_epoch)" ] && echo yes || echo no)"
check "long timeouts counted" yes "$([ -n "$(prom long_timeouts_total)" ] && echo yes || echo no)"
check "stubborn timeouts counted" yes "$([ -n "$(prom stubborn_timeouts_total)" ] && echo yes || echo no)"
check "timeouts are not failures" "" "$(prom long_failures_total)"
check "TERM sent and logged" yes "$(grep 'job long: run .* passed max_runtime; sent TERM' "$root/logs/supervisor/"*.log > /dev/null && echo yes || echo no)"
check "KILL sent to the job ignoring TERM" yes "$(grep 'job stubborn: run .* sent KILL' "$root/logs/supervisor/"*.log > /dev/null && echo yes || echo no)"
check "TERM was enough for long" "" "$(grep 'job long: run .* sent KILL' "$root/logs/supervisor/"*.log)"
check "no locks or markers left" "" "$(ls "$root/state/locks")"

# Every job process is gone: none lives on to finish its sleep.
sleep 30
check "long's process did not survive" "" "$(ls "$root" | grep '^long.finished')"
check "stubborn's process did not survive" "" "$(ls "$root" | grep '^stubborn.finished')"

if [ "$fail" -gt 0 ]; then
    printf '\nsupervisor log:\n'
    cat "$root/logs/supervisor/"*.log | tail -30
    printf '
--once output:
'
    cat "$root/once.out" 2>/dev/null
    printf '
processes:
'
    ps -ef 2>/dev/null | grep -v grep | grep -e vigil -e sleep | head -20
fi
rm -rf "$root"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
