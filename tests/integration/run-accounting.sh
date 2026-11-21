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
# Integration test: the supervisor answers for every run, and says so
# truly (backlog 66), on Linux and macOS. The twin of Run-Accounting.ps1.
#   1. A local job file that is missing: FILE MISSING, file_missing, no run;
#      back, the job runs and file_missing goes to 0 (16.3).
#   2. A job removed from the configuration mid-run is still stopped at its
#      max_runtime and its outcome recorded (11.3); running goes to 0.
#   3. A crashed run is counted in runs, as well as crashes (14.2).
#   4. A job held for vigil resolve after its run ended is not shown as
#      running, nor counted as a worker (13.2).
#   5. Retention deletes the output a crashed run left once it is as old as
#      the job's log, never a running run's (13.1).
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-acct.$$
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

state_value() { sed -n "s/^$2 *= \{0,1\}//p" "$1" 2>/dev/null; }
vigil() { "$BASH" "$vigil_cmd" --root "$root" "$@"; }

# One supervisor tick, then wait (up to 60s) for the sender it may start.
tick() {
    local i=0
    vigil supervise --once >> "$root/once.out" 2>&1
    while ls "$root/state/locks" 2>/dev/null | grep '^vigil_sender\.' > /dev/null; do
        i=$((i + 1))
        [ "$i" -ge 120 ] && break
        sleep 0.5
    done
}
# Ticks until command $2.. succeeds, at most $1 times, a second apart.
tick_until() {
    local n=$1 i=0
    shift
    while ! "$@" && [ "$i" -lt "$n" ]; do tick; sleep 1; i=$((i + 1)); done
    "$@"
}
# The value of series $1 in the file backend's file.
prom() { grep "^$1[{ ]" "$root/metrics/vigil.prom" 2>/dev/null | head -n 1 | sed 's/.* //'; }
status_is() { [ "$(state_value "$root/state/jobs/$1.state" status)" = "$2" ]; }
prom_is() { [ "$(prom "$1")" = "$2" ]; }
section() { sed -n "/^$1\$/,/^\$/p" "$root/logs/supervisor/jobs.log" | sed '1d; /^$/d'; }

# The configuration: the backend, then the job sections given.
config() {
    {
        cat <<EOF
[vigil]
instance = acct

[scheduler]
tick = 1s

[backend.file]
path = metrics/vigil.prom

[runner.sh]
command = /bin/sh

[runners]
.sh = sh
EOF
        printf '%s\n' "$@"
    } > "$root/config/vigil.config"
}

cleanup() { rm -rf "$root"; }
trap cleanup EXIT

printf 'bash %s\n' "$BASH_VERSION"
mkdir -p "$root/config" "$root/scripts"
root=$(cd "$root" && pwd)
printf 'sleep 60\n' > "$root/scripts/slow.sh"
printf 'echo metric ran 1\n' > "$root/scripts/quick.sh"

printf '1. a missing local file\n'
config "
[job.gone]
file      = scripts/gone.sh
run_every = 1s"
tick
tick
check 'FILE MISSING in jobs.log' gone "$(section 'FILE MISSING' | tr -d ' ')"
check 'file_missing is 1' 1 "$(prom gone_file_missing)"
check 'and it never ran' no "$([ -e "$root/state/jobs/gone.state" ] && echo yes || echo no)"
printf 'echo metric ran 1\n' > "$root/scripts/gone.sh"
tick_until 15 status_is gone succeeded
check 'back, it runs' succeeded "$(state_value "$root/state/jobs/gone.state" status)"
tick_until 5 prom_is gone_file_missing 0
check 'and file_missing goes to 0' 0 "$(prom gone_file_missing)"

printf '2. a job removed mid-run\n'
config "
[job.slow]
file        = scripts/slow.sh
run_every   = 1s
max_runtime = 10s
grace       = 2s"
tick_until 15 status_is slow running
check 'slow is running' running "$(state_value "$root/state/jobs/slow.state" status)"
tick
check 'its running gauge is up' yes "$([ -n "$(prom slow_running)" ] && [ "$(prom slow_running)" != 0 ] && echo yes || echo no)"
config ''
tick
check 'jobs.log still shows its run' yes "$(section RUNNING | grep -q '^ *slow: .*(no longer in the configuration, or invalid in it)$' && echo yes || echo no)"
tick_until 20 status_is slow timed_out
check 'still stopped at its max_runtime' timed_out "$(state_value "$root/state/jobs/slow.state" status)"
check 'and the supervisor said so' yes "$(grep -q 'job slow: run .* passed max_runtime; sent TERM' "$root/logs/supervisor/"*.log && echo yes || echo no)"
tick_until 5 prom_is slow_running 0
check 'running goes to 0' 0 "$(prom slow_running)"
check 'no locks left' '' "$(ls "$root/state/locks" | grep '^slow\.')"

printf '3. a crashed run is a run\n'
config "
[job.crashy]
file      = scripts/slow.sh
run_every = 1s"
tick_until 15 status_is crashy running
config "
[job.crashy]
file      = scripts/slow.sh
run_every = 3650d"
jp=$(state_value "$root/state/jobs/crashy.state" job_pid)
wp=$(state_value "$root/state/jobs/crashy.state" worker_pid)
rid=$(state_value "$root/state/jobs/crashy.state" run_id)
kill -9 "$wp" 2>/dev/null
kill -9 -- "-$jp" 2>/dev/null || kill -9 "$jp" 2>/dev/null
tick_until 20 status_is crashy crashed
check 'crashy recorded as crashed' crashed "$(state_value "$root/state/jobs/crashy.state" status)"
tick_until 5 prom_is crashy_crashes_total 1
check 'counted in crashes' 1 "$(prom crashy_crashes_total)"
check 'and in runs' 1 "$(prom crashy_runs_total)"

printf '4. a job held after its run ended\n'
config "
[job.held]
file         = scripts/quick.sh
run_every    = 3650d
on_uncertain = manual"
vigil run held > /dev/null 2>&1
hrid=$(state_value "$root/state/jobs/held.state" run_id)
mkdir -p "$root/state/recovery"
printf '[recovery]\njob          = held\nrun_id       = %s\nconclusion   = uncertain\nreason       = a test\nfirst_seen   = 1\nlast_checked = 1\npolicy       = manual\nresolved_by  = \nresolved_at  = \n' "$hrid" > "$root/state/recovery/held.recovery"
tick
check 'held is under UNCERTAIN' yes "$(section UNCERTAIN | grep -q "^ *held: run $hrid .*held until vigil resolve" && echo yes || echo no)"
check 'not under RUNNING' '' "$(section RUNNING | grep '^ *held:')"
check 'and not counted as a worker' 0 "$(prom vigil_supervisor_workers)"

printf '5. retention of a crashed run'"'"'s output\n'
mkdir -p "$root/logs/jobs/crashy"
for f in 20200101T000000Z-1-1.out 20200101T000000Z-1-1.err 20200101T000000Z-1-2.out; do : > "$root/logs/jobs/crashy/$f"; done
# A run still going holds its token open, as its worker would.
sleep 60 7> "$root/state/locks/crashy.20200101T000000Z-1-2.token" &
holder=$!
tick
check "a crashed run's old output is deleted" '' "$(ls "$root/logs/jobs/crashy" | grep '^20200101T000000Z-1-1\.')"
check "a run's that still holds its token is kept" 20200101T000000Z-1-2.out "$(ls "$root/logs/jobs/crashy" | grep '^20200101T000000Z-1-2\.')"
check "this run's output, too young, is kept" yes "$([ -e "$root/logs/jobs/crashy/$rid.out" ] && echo yes || echo no)"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

if [ "$fail" -gt 0 ]; then
    printf '\njobs.log:\n'
    cat "$root/logs/supervisor/jobs.log"
    printf '\nsupervisor log:\n'
    cat "$root/logs/supervisor/"*-*.log | tail -30
    printf '\n--once output:\n'
    tail -20 "$root/once.out" 2>/dev/null
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
