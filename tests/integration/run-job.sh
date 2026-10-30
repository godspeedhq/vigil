#!/usr/bin/env bash
#
# Integration test: "vigil run <job>" end to end on Linux and macOS
# (SPECIFICATION.md 4.3). Builds a throwaway install root, runs real jobs
# through the real command, and checks the exit code, state file, spool
# events, job log and lock files of each run.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
# Run the command with the same bash as this test, so CI covers bash 3.2.
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-it.$$
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

# The value of key $2 in state file $1.
state_value() {
    sed -n "s/^$2 *= \{0,1\}//p" "$1"
}

printf 'bash %s\n' "$BASH_VERSION"
mkdir -p "$root/config" "$root/scripts"

cat > "$root/scripts/ok.sh" <<'EOF'
#!/bin/sh
echo "starting"
echo "metric rows 5 table=orders"
echo "metric bad"
echo "to stderr" >&2
exit 0
EOF
cat > "$root/scripts/check_disk.sh" <<'EOF'
echo "DISK WARNING - / 85% | /=11700MB;15600;17550;0;19500"
exit 1
EOF
cat > "$root/scripts/fail.sh" <<'EOF'
#!/bin/sh
echo "metric partial 1"
exit 2
EOF
cat > "$root/scripts/env.sh" <<'EOF'
echo "metric greeting_len ${#GREETING}"
echo "metric run_id_set $([ -n "$VIGIL_RUN_ID" ] && echo 1 || echo 0)"
echo "metric args $#"
EOF
chmod +x "$root/scripts/ok.sh" "$root/scripts/fail.sh"

cat > "$root/config/vigil.config" <<'EOF'
[vigil]
instance = it

[tags]
env = test

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.ok]
file      = scripts/ok.sh
run_every = 5m

[job.disk]
metric_name = os.disk
file        = scripts/check_disk.sh
run_every   = 5m
exit_codes  = nagios

[job.fail]
file      = scripts/fail.sh
run_every = 5m

[job.env]
file        = scripts/env.sh
arg         = one
arg         = two words
env         = GREETING=hello
require_env = HOME
run_every   = 5m

[job.needs_env]
file        = scripts/env.sh
require_env = VIGIL_IT_SURELY_UNSET
run_every   = 5m

[job.missing]
file      = scripts/missing.sh
run_every = 5m
EOF

# run <job> <expected exit code> <expected status> <expected reason>
run() {
    local out rc st
    out=$("$BASH" "$vigil_cmd" --root "$root" run "$1" 2>&1)
    rc=$?
    check "$1 exit code" "$2" "$rc"
    st="$root/state/jobs/$1.state"
    check "$1 status" "$3" "$(state_value "$st" status)"
    check "$1 reason" "$4" "$(state_value "$st" reason)"
    check "$1 no locks left" "" "$(ls "$root/state/locks" 2>/dev/null | grep "^$1\." || true)"
    check "$1 summary line" "$1: $3" "$(printf '%s' "$out" | sed -n "s/^\($1: [a-z_]*\).*/\1/p")"
}

# events <job>: the events of its latest run, without epoch and host.
events() {
    local f
    f=$(ls "$root/spool/incoming/"*"-$1-"*.events | tail -n 1)
    sed -e 's/^[0-9]* //' -e 's/ host=[^ ]*//' -e 's/ os=[^ ]*//' "$f"
}

run ok 0 succeeded ''
check "ok events" "ok.duration_seconds 0 gauge instance=it job=ok env=test
ok.runs 1 count instance=it job=ok env=test
ok.succeeded 1 count instance=it job=ok env=test
ok.rows 5 gauge instance=it job=ok env=test table=orders
ok.invalid_metric_lines 1 count instance=it job=ok env=test" "$(events ok | sed 's/duration_seconds [0-9]*/duration_seconds 0/')"
check "ok state summary" "1 1 0" "$(st="$root/state/jobs/ok.state"; echo "$(state_value "$st" metric_lines) $(state_value "$st" invalid_lines) $(state_value "$st" dropped_lines)")"
log=$(cat "$root/logs/jobs/ok/"*.log)
check "ok log has stdout" 1 "$(printf '%s\n' "$log" | grep -c ' out: metric rows 5 table=orders$')"
check "ok log has stderr" 1 "$(printf '%s\n' "$log" | grep -c ' err: to stderr$')"
check "ok log has end" 1 "$(printf '%s\n' "$log" | grep -c ' END run .* succeeded in ')"

run disk 1 warning 'exit code 1'
check "disk perf event" "os.disk.perf 12268339200 gauge instance=it job=disk env=test label=/" "$(events disk | grep '^os.disk.perf ')"

run fail 2 failed 'exit code 2'
check "fail failures event" "fail.failures 1 count instance=it job=fail env=test exit_code=2" "$(events fail | grep failures)"

run env 0 succeeded ''
check "env passes env, run id and arguments" "env.greeting_len 5
env.run_id_set 1
env.args 2" "$(events env | grep -e greeting_len -e run_id_set -e '\.args' | sed 's/ gauge.*//')"

run needs_env 2 failed 'missing environment variable VIGIL_IT_SURELY_UNSET'
run missing 2 failed "file not found: $root/scripts/missing.sh"
check "missing failures event has no exit code" "missing.failures 1 count instance=it job=missing env=test" "$(events missing | grep failures)"

# A run of a job that is in progress is refused.
touch "$root/state/locks/ok.20260101T000000Z-1.token"
"$BASH" "$vigil_cmd" --root "$root" run ok > /dev/null 2>&1
check "run refused while a token exists" 4 "$?"
rm -f "$root/state/locks/ok.20260101T000000Z-1.token"

# A worker whose launch record is gone does not run the job.
"$BASH" "$vigil_cmd" --root "$root" worker ok --run-id 20260101T000000Z-2 > /dev/null 2>&1
check "abandoned launch is not run" 4 "$?"

"$BASH" "$vigil_cmd" --root "$root" run nosuchjob > /dev/null 2>&1
check "unknown job is not run" 4 "$?"

rm -rf "$root"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
