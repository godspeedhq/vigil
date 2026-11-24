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
# Integration test: the crash points of SPECIFICATION.md 22.4.1 drive the
# launch and fan-out tests of 22.4 (20 to 23, 25 to 29), the worker's own
# crash points (7, 16), and a held queue_one run launched as the supervisor
# crashes (8, 9), on Linux and macOS.
# The twin of Crash.ps1. Two invariants:
#   launch:  exactly one run per launch, or none, never two;
#   fan-out: every event reaches every one of its targets at least once, and
#            no partial file is ever sent.
#
# CRASH_RACE_ROUNDS (default 50) sets how many times test 23 races a claim
# against an abandonment; CRASH_LOOP_ROUNDS (default 6) the rounds of the
# randomised loop (29).
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-crash.$$
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

vigil() { "$BASH" "$vigil_cmd" --root "$root" "$@"; }
state_value() { sed -n "s/^$2 *= \{0,1\}//p" "$1" 2>/dev/null; }
locks() { ls "$root/state/locks" 2>/dev/null | grep "^$1\." ; }
# Run ids a job ran with: one line per run its script started.
marks() { cat "$root/marks" 2>/dev/null; }
dup_marks() { sort "$root/marks" 2>/dev/null | uniq -d; }
# A tick that waits for no worker.
tick() { vigil supervise --once > /dev/null 2>&1; }
# Ticks until command $2.. succeeds, at most $1 times, a second apart.
tick_until() {
    local n=$1 i=0
    shift
    while ! "$@" && [ "$i" -lt "$n" ]; do tick; sleep 1; i=$((i + 1)); done
    "$@"
}
# The run id of job $1's only launch record or token.
lock_rid() { locks "$1" | head -n 1 | sed "s/^$1\.//; s/\.launch\$//; s/\.token\$//"; }
age_launch() { local f="$root/state/locks/$1.$2.launch"; [ -f "$f" ] && sed -i.bak 's/^launch_epoch .*/launch_epoch  = 1/' "$f" && rm -f "$f.bak"; }
in_both() { grep -q "^$1" "$root/metrics/a.prom" 2>/dev/null && grep -q "^$1" "$root/metrics/b.prom" 2>/dev/null; }
no_mark_lock() { [ -z "$(locks mark)" ]; }

cleanup() { rm -rf "$root"; }
trap cleanup EXIT

printf 'bash %s\n' "$BASH_VERSION"
mkdir -p "$root/config" "$root/scripts" "$root/state/locks"
root=$(cd "$root" && pwd)

# The job records its run id, and an overlap if two runs ever meet.
cat > "$root/scripts/mark.sh" <<'EOF'
if ! mkdir "$IT_ROOT/inflight" 2>/dev/null; then echo overlap >> "$IT_ROOT/overlap"; fi
echo "$VIGIL_RUN_ID" >> "$IT_ROOT/marks"
sleep 1
rmdir "$IT_ROOT/inflight" 2>/dev/null
echo "metric ran 1"
EOF

config() {
    cat > "$root/config/vigil.config" <<EOF
[vigil]
instance = crash

[scheduler]
tick = 1s

[backend.a]
type = file
path = metrics/a.prom

[backend.b]
type = file
path = metrics/b.prom

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.mark]
file      = scripts/mark.sh
env       = IT_ROOT=$root
run_every = $1
EOF
}

# --- Launch window (22.4, 20 to 22) -------------------------------------------------

# A launch crash point fires at the first launch of a tick, and a tick
# launches its due jobs before the sender (8, 4.5). So each test first lets
# the job's runs end, then makes it due: its launch is then the tick's first.
settle() { config 3650d; tick_until 30 no_mark_lock > /dev/null; config 1s; }
# One tick with the environment given, until it launches the job.
fault_tick() {
    local i=0
    code=0
    while [ "$i" -lt 10 ]; do
        env "$@" "$BASH" "$vigil_cmd" --root "$root" supervise --once > /dev/null 2>&1
        code=$?
        [ -n "$(locks mark)" ] && break
        sleep 1
        i=$((i + 1))
    done
    rid=$(lock_rid mark)
}

config 1s
tick
tick_until 20 sh -c "[ -f '$root/state/jobs/mark.state' ]" > /dev/null

# 20. launch.after_record: the record is written, the worker never started.
settle
fault_tick VIGIL_FAULT=launch.after_record
config 3650d
check "20: the supervisor crashed after the record" 99 "$code"
check "20: the launch record is there" yes "$([ -n "$rid" ] && [ -f "$root/state/locks/mark.$rid.launch" ] && echo yes || echo no)"
sleep 2
check "20: the job did not run" no "$(marks | grep -qx "$rid" && echo yes || echo no)"
tick
check "20: a young launch is held, nothing else started" "mark.$rid.launch" "$(locks mark)"
age_launch mark "$rid"
tick
check "20: past its grace, abandoned" "" "$(locks mark)"
check "20: and never run" no "$(marks | grep -qx "$rid" && echo yes || echo no)"

# 21. launch.after_spawn: the worker started, then the supervisor crashed.
# One crash only, and the run found by its mark, not its lock: a fast worker
# can be done before a lock is looked for.
settle
before=$(marks)
VIGIL_FAULT=launch.after_spawn vigil supervise --once > /dev/null 2>&1
code=$?
config 3650d
check "21: the supervisor crashed after the spawn" 99 "$code"
i=0 rid=''
while [ -z "$rid" ] && [ "$i" -lt 40 ]; do
    sleep 0.5
    rid=$(marks | grep -vxF -e "$before" -e '' | head -n 1)
    [ -n "$before" ] || rid=$(marks | head -n 1)
    i=$((i + 1))
done
check "21: the worker claimed and ran the job" yes "$([ -n "$rid" ] && echo yes || echo no)"
tick_until 20 no_mark_lock > /dev/null
check "21: run once, never beside itself" "1|" "$(marks | grep -cx "$rid")|$(cat "$root/overlap" 2>/dev/null)"
check "21: and recorded" succeeded "$(state_value "$root/state/jobs/mark.state" status)"
boot=$(state_value "$root/state/jobs/mark.state" boot_id)

# 22. worker.before_claim held past the grace: a process carries the run id,
# so the supervisor keeps holding and starts nothing (11.3); the late worker
# then claims and runs the job, once.
settle
fault_tick VIGIL_FAULT=worker.before_claim VIGIL_FAULT_SLEEP=8
config 3650d
check "22: launched, its worker waiting" "mark.$rid.launch" "$(locks mark)"
age_launch mark "$rid"
tick
check "22: past its grace, still held: nothing else started" "mark.$rid.launch" "$(locks mark)"
i=0
while ! marks | grep -qx "$rid" && [ "$i" -lt 40 ]; do sleep 0.5; i=$((i + 1)); done
tick_until 20 no_mark_lock > /dev/null
check "22: the late worker ran the job, once" "1|" "$(marks | grep -cx "$rid")|$(cat "$root/overlap" 2>/dev/null)"
check "22: no token left behind" "" "$(locks mark)"

# --- 23. Claim against abandonment ---------------------------------------------------

# A worker starts on an old launch record while a tick abandons it: exactly
# one side wins, every time.
rounds=${CRASH_RACE_ROUNDS:-50}
both=0 neither=0 i=0
while [ "$i" -lt "$rounds" ]; do
    i=$((i + 1))
    rid="20260101T000000Z-23-$i"
    printf '[launch]\njob           = mark\nrun_id        = %s\nboot_id       = %s\nlaunch_epoch  = 1\n' "$rid" "$boot" > "$root/state/locks/mark.$rid.launch"
    vigil worker mark --run-id "$rid" > /dev/null 2>&1 &
    w=$!
    tick
    wait "$w"
    ran=no
    marks | grep -qx "$rid" && ran=yes
    abandoned=no
    grep -q "launch $rid abandoned" "$root"/logs/supervisor/2*.log 2>/dev/null && abandoned=yes
    [ "$ran" = yes ] && [ "$abandoned" = yes ] && both=$((both + 1))
    [ "$ran" = no ] && [ "$abandoned" = no ] && neither=$((neither + 1))
    tick_until 10 no_mark_lock > /dev/null
done
check "23: $rounds races, never both" 0 "$both"
check "23: and never neither" 0 "$neither"
check "23: no run ever met another" "" "$(cat "$root/overlap" 2>/dev/null)"

# --- Fan-out (22.4, 25 and 26) -----------------------------------------------------

# One event, named $1, put in the spool as a job's would be.
# The time is read once: read again for the rename, a second that turns
# between the two loses the event before Vigil ever sees it.
event() {
    local now f
    now=$(date '+%s')
    f="$root/spool/incoming/$now-it-$1.events"
    printf '%s %s 1 gauge host=it\n' "$now" "$1" > "$f.tmp" && mv -f "$f.tmp" "$f"
}
mkdir -p "$root/spool/incoming"
# The sender's run ids that started, and whether run $1 ended.
sender_runs() { cat "$root"/logs/jobs/vigil_sender/*.log 2>/dev/null | sed -n 's/^[^ ]* \([^ ]*\) run start.*/\1/p'; }
sender_ended() { cat "$root"/logs/jobs/vigil_sender/*.log 2>/dev/null | grep -q " $1 run end "; }

# 25. A sender crashed at each point; a later one finishes the fan-out.
n=0
for point in fanout.after_claim fanout.after_targets fanout.after_place:1 fanout.after_place:2 fanout.before_retire sender.after_send; do
    n=$((n + 1))
    name="crash_$n"
    # No sender running: one would take the event before the crashing one.
    i=0
    while [ -n "$(locks vigil_sender)" ] && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
    event "$name"
    before=$(sender_runs)
    VIGIL_FAULT=$point vigil supervise --once > /dev/null 2>&1
    i=0 new=''
    while [ -z "$new" ] && [ "$i" -lt 40 ]; do
        sleep 0.5
        new=$(sender_runs | grep -vxF -e "$before" -e '' | head -n 1)
        [ -n "$before" ] || new=$(sender_runs | head -n 1)
        i=$((i + 1))
    done
    sleep 2
    check "25: $point: the sender crashed there" "started|no end" "$([ -n "$new" ] && echo started)|$(sender_ended "$new" && echo ended || echo 'no end')"
    tick_until 20 in_both "$name" > /dev/null
    check "25: $point: every target has the event" yes "$(in_both "$name" && echo yes || echo no)"
done
tick_until 10 sh -c "[ -z \"\$(ls '$root/spool/fanout' 2>/dev/null)\" ]" > /dev/null
check "25: nothing left in the fan-out" "" "$(ls "$root/spool/fanout" 2>/dev/null)"

# 26. A copy left half-written (a temporary file) is never sent.
mkdir -p "$root/spool/backends/a"
printf '%s partial_copy 1 gauge host=it\n' "$(date '+%s')" > "$root/spool/backends/a/.1-it-partial.events.tmp.123"
event after_partial
tick_until 10 in_both after_partial > /dev/null
check "26: a temporary file is never sent" no "$(grep -q '^partial_copy' "$root/metrics/a.prom" && echo yes || echo no)"
rm -f "$root/spool/backends/a/.1-it-partial.events.tmp.123"

# 27. A backend removed between a crash and the resume: its copy is dropped
# and counted, and the other backend still gets the event.
dropped_b() { grep -q '^vigil_spool_dropped_total{backend="b".*reason="backend_removed"' "$root/metrics/a.prom" 2>/dev/null; }
in_a() { grep -q "^$1" "$root/metrics/a.prom" 2>/dev/null; }
config 3650d
i=0
while [ -n "$(locks vigil_sender)" ] && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
event removed_b
VIGIL_FAULT=fanout.after_targets vigil supervise --once > /dev/null 2>&1
# It crashes at the first file it claims, which may be an older one of
# Vigil's own: any fan-out with its targets fixed will do.
i=0
while ! ls "$root/spool/fanout" 2>/dev/null | grep -q '\.targets$' && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
sleep 1
check "27: the sender crashed with the targets fixed" yes "$(ls "$root/spool/fanout" 2>/dev/null | grep -q '\.targets$' && echo yes || echo no)"
sed -i.bak '/^\[backend\.b\]/,/^path/d' "$root/config/vigil.config" && rm -f "$root/config/vigil.config.bak"
tick_until 20 sh -c "grep -q '^removed_b' '$root/metrics/a.prom' && grep -q '^vigil_spool_dropped_total{backend=\"b\".*reason=\"backend_removed\"' '$root/metrics/a.prom'" > /dev/null
check "27: the backend left has the event" yes "$(in_a removed_b && echo yes || echo no)"
check "27: the removed one's copy dropped, counted as backend_removed" yes "$(dropped_b && echo yes || echo no)"
# Once the senders have finished: the next may be mid-way through Vigil's own
# newer events, which are not this test's.
i=0
while [ -n "$(locks vigil_sender)" ] && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
check "27: nothing left in the fan-out" "" "$(ls "$root/spool/fanout" 2>/dev/null)"
# b back. A sender started without it delivers by the configuration it was
# launched with (4.3), even events that arrive while it starts: let it end.
config 3650d
i=0
while [ -n "$(locks vigil_sender)" ] && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done

# 28. A copy that fails, as on a full disk: a file where b's queue directory
# should be. The fan-out is not retired, a gets the event meanwhile, and b
# gets it once its copy can be made.
in_b() { grep -q "^$1" "$root/metrics/b.prom" 2>/dev/null; }
fanout_has() { ls "$root/spool/fanout" 2>/dev/null | grep -q "$1"; }
tick_until 20 sh -c "[ -z \"\$(ls '$root/spool/backends/b' 2>/dev/null)\" ]" > /dev/null
rm -rf "$root/spool/backends/b"
: > "$root/spool/backends/b"
event full_disk
tick_until 20 in_a full_disk > /dev/null
tick
check "28: the backend whose copy worked gets the event" yes "$(in_a full_disk && echo yes || echo no)"
check "28: the fan-out is not retired" yes "$(fanout_has 'full_disk\.events$' && echo yes || echo no)"
check "28: the failed copy is not marked done" no "$(fanout_has 'full_disk\.events\.b\.done$' && echo yes || echo no)"
rm -f "$root/spool/backends/b"
tick_until 20 in_b full_disk > /dev/null
check "28: once the copy can be made, b gets the event" yes "$(in_b full_disk && echo yes || echo no)"
tick_until 10 sh -c "! ls '$root/spool/fanout' 2>/dev/null | grep -q full_disk" > /dev/null
check "28: and the fan-out is retired" no "$(fanout_has full_disk && echo yes || echo no)"

# --- 29. A randomised crash loop ------------------------------------------------------

# Where event $1 got to, when it was lost: every file of it, and the logs
# around it.
lost_dump() {
    printf '        in a: %s  in b: %s\n' "$(grep -c "^$1" "$root/metrics/a.prom" 2>/dev/null)" "$(grep -c "^$1" "$root/metrics/b.prom" 2>/dev/null)"
    (cd "$root/spool" && find . -type f) | sed 's/^/        spool: /'
    ls "$root/state/locks" 2>/dev/null | sed 's/^/        lock: /'
    grep -rl "$1" "$root/spool" 2>/dev/null | sed 's/^/        has it: /'
    cat "$root"/logs/supervisor/2*.log 2>/dev/null | tail -12 | sed 's/^/        sup: /'
    cat "$root"/logs/jobs/vigil_sender/*.log 2>/dev/null | tail -8 | sed 's/^/        sender: /'
}

points="launch.after_record launch.after_spawn fanout.after_claim fanout.after_targets fanout.after_place:1 fanout.after_place:2 fanout.before_retire sender.after_send state.after_temp"
set -- $points
count=$#
rounds=${CRASH_LOOP_ROUNDS:-6}
lost=0 r=0
config 1s
while [ "$r" -lt "$rounds" ]; do
    r=$((r + 1))
    k=$(( (RANDOM % count) + 1 ))
    eval "point=\${$k}"
    event "loop_$r"
    VIGIL_FAULT=$point vigil supervise --once > /dev/null 2>&1
    sleep 2
    # Abandon any launch the crash left, as the grace would: the job's, or
    # the sender's when the job was still running and the sender's launch
    # was the tick's first.
    for f in "$root"/state/locks/*.launch; do
        [ -f "$f" ] || continue
        sed -i.bak 's/^launch_epoch .*/launch_epoch  = 1/' "$f" && rm -f "$f.bak"
    done
    tick_until 20 in_both "loop_$r" > /dev/null || { lost=$((lost + 1)); printf '        lost after %s\n' "$point"; lost_dump "loop_$r"; }
done
config 3650d
tick_until 20 no_mark_lock > /dev/null
check "29: $rounds random crashes, every event delivered" 0 "$lost"
check "29: no launch ever ran twice" "" "$(dup_marks)"
check "29: no run ever met another" "" "$(cat "$root/overlap" 2>/dev/null)"

# --- A queued run (9): a crash after its launch never runs it twice ------------------
#
# q holds one run while another is active (queue_one). When the active run
# ends, a tick launches the held one, and crashes right after (backlog 58).
# The held run must be gone from state/pending by then, or the next
# supervisor runs it again.
cat > "$root/scripts/q.sh" <<'EOF'
echo "$VIGIL_RUN_ID" >> "$IT_ROOT/qmarks"
sleep 4
EOF
config_q() {
    config 3650d
    cat >> "$root/config/vigil.config" <<EOF

[job.q]
file      = scripts/q.sh
env       = IT_ROOT=$root
overlap   = queue_one
run_every = $1
EOF
}
q_idle() { [ -z "$(locks q)" ]; }
q_queued() { grep -Eq '^queued=(.* )?q( |$)' "$root/state/pending" 2>/dev/null; }
config_q 2s
tick_until 10 sh -c "[ -n \"\$(ls '$root/state/locks' 2>/dev/null | grep '^q\.')\" ]" > /dev/null
# Its next slot comes due while the first run is active: held.
sleep 2
tick_until 5 q_queued > /dev/null
check "queued: a run is held while one is active" yes "$(q_queued && echo yes || echo no)"
# Nothing else comes due: only the held run is left to start.
config_q 3650d
i=0
while ! q_idle && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
VIGIL_FAULT=launch.after_spawn vigil supervise --once > /dev/null 2>&1
check "queued: the supervisor crashed after launching it" 99 "$?"
check "queued: and it is no longer held" no "$(q_queued && echo yes || echo no)"
# Tick until the held run has ended, then a few more.
tick_until 20 q_idle > /dev/null
i=0
while [ "$i" -lt 8 ]; do tick; sleep 1; i=$((i + 1)); done
tick_until 20 q_idle > /dev/null
check "queued: two runs, never three" 2 "$(wc -l < "$root/qmarks" | tr -d ' ')"
# Seen once with three, on Windows PowerShell 7, and not since: if it comes
# back, which runs, and what the supervisor said about q.
if [ "$(wc -l < "$root/qmarks" | tr -d ' ')" != 2 ]; then
    sed 's/^/        run: /' "$root/qmarks"
    cat "$root"/logs/supervisor/2*.log 2>/dev/null | grep -E 'job q[: ]|VIGIL_FAULT|supervisor started' | tail -30 | sed 's/^/        sup: /'
    cat "$root"/logs/jobs/q/*.log 2>/dev/null | sed 's/^/        job: /'
fi

# --- The worker's crash points (7, 16, 23) ------------------------------------------
#
# Each case crashes the worker of one run of w at a point, then ticks once:
# the run must be concluded as what it was, run once or not at all, and
# leave no token. w runs for 4 s, so a sender started by the same tick is
# done before w's events are written, and the supervisor finds them where
# the worker left them.
cat > "$root/scripts/w.sh" <<'EOF'
echo "$VIGIL_RUN_ID" >> "$IT_ROOT/wmarks"
sleep 4
EOF
config_w() {
    config 3650d
    cat >> "$root/config/vigil.config" <<EOF

[job.w]
file      = scripts/w.sh
env       = IT_ROOT=$root
run_every = $1
EOF
}
w_idle() { [ -z "$(locks w)" ]; }
w_ran() { cat "$root/wmarks" 2>/dev/null | grep -cx "$1" || true; }
w_state() { state_value "$root/state/jobs/w.state" "$1"; }
# One run of w with VIGIL_FAULT=$1; once no process carries its run id,
# one tick.
w_crash() {
    local i=0
    config_w 3650d
    tick_until 30 w_idle > /dev/null
    config_w 1s
    rid=''
    while [ -z "$rid" ] && [ "$i" -lt 10 ]; do
        VIGIL_FAULT=$1 vigil supervise --once > /dev/null 2>&1
        rid=$(lock_rid w)
        [ -n "$rid" ] || sleep 1
        i=$((i + 1))
    done
    config_w 3650d
    i=0
    while ps -A -o args= | grep -F -- "$rid" | grep -qv grep && [ "$i" -lt 40 ]; do sleep 0.5; i=$((i + 1)); done
    tick
}

# 23. worker.after_claim: the token taken, the job never started.
w_crash worker.after_claim
check "worker.after_claim: never ran" 0 "$(w_ran "$rid")"
check "worker.after_claim: concluded crashed" "crashed $rid" "$(w_state status) $(w_state run_id)"
check "worker.after_claim: no token left" "" "$(locks w)"

# 7. state.after_temp:1: the first state write interrupted, its temporary
# file left behind, before the job starts.
w_crash state.after_temp:1
check "7: state.after_temp:1: never ran" 0 "$(w_ran "$rid")"
check "7: state.after_temp:1: concluded crashed" "crashed $rid" "$(w_state status) $(w_state run_id)"
check "7: state.after_temp:1: the temporary file is left, never read" yes "$(ls "$root/state/jobs" | grep -q '^w\.state\.tmp\.' && echo yes || echo no)"
check "7: state.after_temp:1: no token left" "" "$(locks w)"

# 7 and 16. state.after_temp:3: the final state write interrupted, after
# the run's events: reconciled from them.
w_crash state.after_temp:3
check "7: state.after_temp:3: ran once" 1 "$(w_ran "$rid")"
check "7: state.after_temp:3: reconciled from its spool file" "succeeded|reconciled from the spool file|$rid" "$(w_state status)|$(w_state reason)|$(w_state run_id)"
check "7: state.after_temp:3: no token left" "" "$(locks w)"

# 16. worker.after_spool: the events written, the final state never.
w_crash worker.after_spool
check "16: worker.after_spool: ran once" 1 "$(w_ran "$rid")"
check "16: worker.after_spool: reconciled from its spool file" "succeeded|reconciled from the spool file|$rid" "$(w_state status)|$(w_state reason)|$(w_state run_id)"
check "16: worker.after_spool: no token left" "" "$(locks w)"

# 16b. The same, for a job that failed and printed a metric of its own
# called steps.succeeded, and for one that succeeded and printed
# rows.failures: the outcome is the worker's own line of the spool file,
# never one the job printed (V-01).
cp "$root/scripts/w.sh" "$root/scripts/w.sh.keep"
printf '%s\n' 'echo "$VIGIL_RUN_ID" >> "$IT_ROOT/wmarks"' 'echo "metric steps.succeeded 1"' 'exit 2' > "$root/scripts/w.sh"
w_crash worker.after_spool
check "16b: a failed run that printed steps.succeeded is reconciled as failed" "failed|reconciled from the spool file|$rid" "$(w_state status)|$(w_state reason)|$(w_state run_id)"
printf '%s\n' 'echo "$VIGIL_RUN_ID" >> "$IT_ROOT/wmarks"' 'echo "metric rows.failures 0"' > "$root/scripts/w.sh"
w_crash worker.after_spool
check "16b: a run that succeeded and printed rows.failures is reconciled as succeeded" "succeeded|reconciled from the spool file|$rid" "$(w_state status)|$(w_state reason)|$(w_state run_id)"
mv -f "$root/scripts/w.sh.keep" "$root/scripts/w.sh"

# worker.after_state: the final state written, the token never released.
w_crash worker.after_state
check "worker.after_state: ran once" 1 "$(w_ran "$rid")"
check "worker.after_state: its own outcome kept" "succeeded||$rid" "$(w_state status)|$(w_state reason)|$(w_state run_id)"
check "worker.after_state: not taken for a crash" 0 "$(cat "$root"/logs/supervisor/2*.log | grep -c "run $rid crashed")"
check "worker.after_state: no token left" "" "$(locks w)"
check "the worker's crash points: no run ever ran twice" "" "$(sort "$root/wmarks" | uniq -d)"

# The supervisor says when crash points are on (22.4.1).
check "the supervisor warns while VIGIL_FAULT is set" yes "$(grep -q 'VIGIL_FAULT is set' "$root"/logs/supervisor/2*.log && echo yes || echo no)"

if [ "$fail" -gt 0 ]; then
    printf '\nsupervisor log, last 30 lines:\n'
    cat "$root"/logs/supervisor/2*.log 2>/dev/null | tail -30
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
