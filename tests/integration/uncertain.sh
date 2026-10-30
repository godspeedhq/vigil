#!/usr/bin/env bash
#
# Integration test: uncertain runs (SPECIFICATION.md 11.4, 11.5; fault
# injection 22.4 cases 10, 11, 12, 18, 19) on Linux and macOS.
#
# Each of three jobs gets a run that is alive (a process holds its run
# token) and past its deadline, but whose recorded job process is an
# unrelated one: ownership cannot be proven, so nothing may be killed.
# The jobs differ only in on_uncertain:
#   w  wait     held while uncertain; released when the evidence clears
#   r  replace  scheduling goes on, posting possible_duplicates
#   m  manual   still held after the evidence clears, until vigil resolve
# Every tick is a fresh supervisor process, so holds must survive restarts.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-unc.$$
pass=0
fail=0
pids=''

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
    sed -n "s/^$2 *= \{0,1\}//p" "$1" 2>/dev/null
}

vigil() {
    "$BASH" "$vigil_cmd" --root "$root" "$@"
}

tick() {
    local i=0
    vigil supervise --once >> "$root/once.out" 2>&1
    while ls "$root/state/locks" 2>/dev/null | grep '^vigil_sender\.' > /dev/null; do
        i=$((i + 1))
        [ "$i" -ge 120 ] && break
        sleep 0.5
    done
}

prom() {
    grep "^$1[{ ]" "$root/metrics/vigil.prom" 2>/dev/null | head -n 1 | sed 's/.* //'
}

section() {
    sed -n "/^$1\$/,/^\$/p" "$root/logs/supervisor/jobs.log"
}

printf 'bash %s\n' "$BASH_VERSION"
mkdir -p "$root/config" "$root/scripts" "$root/state/jobs" "$root/state/locks"
root=$(cd "$root" && pwd)

printf 'sleep 1\n' > "$root/scripts/quick.sh"
cat > "$root/config/vigil.config" <<'EOF'
[scheduler]
tick = 1s

[backend.file]
path = metrics/vigil.prom

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.w]
file         = scripts/quick.sh
run_every    = 2s
on_uncertain = wait

[job.r]
file         = scripts/quick.sh
run_every    = 2s
on_uncertain = replace

[job.m]
file         = scripts/quick.sh
run_every    = 2s
on_uncertain = manual
EOF

# This system's boot id, as Vigil computes it.
for lib in config worker; do . "$repo/app/lib/posix/$lib.sh"; done
_vigil_wk_boot_id
boot=$_vw_boot

# An unrelated process: the recorded "job process" of every fake run. It
# must never be killed.
sleep 300 &
unrelated=$!
pids="$pids $unrelated"

now=$(date '+%s')
for j in w r m; do
    rid=20260101T000000Z-9-$j
    : > "$root/state/locks/$j.$rid.token"
    # A stand-in worker: holds the run token open, so the run is alive.
    ( exec 9< "$root/state/locks/$j.$rid.token"; exec sleep 300 ) &
    eval "holder_$j=\$!"
    pids="$pids $!"
    printf '[state]\nschema_version = 1\njob = %s\nrun_id = %s\nstatus = running\nboot_id = %s\nstarted_epoch = %s\ndeadline_epoch = 1\njob_pid = %s\njob_name = sleep\n' \
        "$j" "$rid" "$boot" "$now" "$unrelated" > "$root/state/jobs/$j.state"
done

tick
sleep 3
tick

for j in w r m; do
    check "$j: recovery record written" uncertain "$(state_value "$root/state/recovery/$j.recovery" conclusion)"
    check "$j: listed as uncertain" yes "$(section UNCERTAIN | grep "  $j: past max_runtime, but its job process cannot be proven" > /dev/null && echo yes || echo no)"
done
check "w: policy recorded" wait "$(state_value "$root/state/recovery/w.recovery" policy)"
check "unrelated process never killed" yes "$(kill -0 "$unrelated" 2>/dev/null && echo yes || echo no)"
check "w: held, no new run" "" "$(ls "$root/state/locks" | grep '^w\.' | grep -v 20260101T000000Z-9-w)"
check "m: held, no new run" "" "$(ls "$root/state/locks" | grep '^m\.' | grep -v 20260101T000000Z-9-m)"
check "r: replaced, a new run started" yes "$(grep 'job r: run .* started beside an uncertain run' "$root/logs/supervisor/"*-*.log > /dev/null && echo yes || echo no)"
tick
check "uncertain gauge delivered" 1 "$(prom w_uncertain)"
check "possible duplicates counted" yes "$([ -n "$(prom r_possible_duplicates_total)" ] && echo yes || echo no)"
check "resolve refuses a job that is not held" 1 "$(vigil resolve nosuch > /dev/null 2>&1; echo $?)"

# The evidence clears: the stand-in workers exit, releasing their tokens.
eval "kill \$holder_w \$holder_m"
sleep 1
tick
# Released at once, w may already have run again: its conclusion is in the log.
check "w: concluded crashed" yes "$(grep 'job w: run 20260101T000000Z-9-w crashed' "$root/logs/supervisor/"*-*.log > /dev/null && echo yes || echo no)"
check "w: released, record gone" "" "$(ls "$root/state/recovery" | grep '^w\.')"
check "m: concluded crashed" crashed "$(state_value "$root/state/jobs/m.state" status)"
check "m: still held after the evidence cleared" crashed "$(state_value "$root/state/recovery/m.recovery" conclusion)"
check "m: listed as held until resolved" yes "$(section UNCERTAIN | grep '  m: run .* crashed; held until vigil resolve' > /dev/null && echo yes || echo no)"
tick
check "m: held across another restart" yes "$([ -f "$root/state/recovery/m.recovery" ] && echo yes || echo no)"

check "resolve succeeds for a held job" 0 "$(vigil resolve m > /dev/null 2>&1; echo $?)"
tick
check "m: released after resolve" "" "$(ls "$root/state/recovery" | grep '^m\.')"
check "release logged with who resolved it" yes "$(grep "job m: hold on run 20260101T000000Z-9-m released, resolved by" "$root/logs/supervisor/"*-*.log > /dev/null && echo yes || echo no)"
check "unrelated process still never killed" yes "$(kill -0 "$unrelated" 2>/dev/null && echo yes || echo no)"

if [ "$fail" -gt 0 ]; then
    printf '\nsupervisor log:\n'
    cat "$root/logs/supervisor/"*.log | tail -40
    printf '\n--once output:\n'
    cat "$root/once.out" 2>/dev/null | tail -20
fi
# shellcheck disable=SC2086
kill $pids 2>/dev/null
sleep 3
rm -rf "$root"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
