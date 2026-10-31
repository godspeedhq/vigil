#!/usr/bin/env bash
#
# Integration test: vigil init (SPECIFICATION.md 19) and vigil uninstall
# (18.8) on Linux and macOS. init writes a configuration that passes
# pre-flight and whose sample job runs, and never overwrites one.
# uninstall ends only the workers proven to be the root's - an unrelated
# process stays - and removes the root, or all but config/ and scripts/.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-init.XXXXXX")
work=$(cd "$work" && pwd)
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

# A root with the app in it, as an install has.
make_root() {
    mkdir -p "$1"
    cp -R "$repo/app" "$1/"
}

vigil() {
    local root=$1
    shift
    "$BASH" "$root/app/vigil" --root "$root" "$@" < /dev/null
}

printf 'bash %s\n' "$BASH_VERSION"

# --- init -------------------------------------------------------------------

r=$work/init
make_root "$r"
vigil "$r" init --instance it-host --backend file,datadog > "$work/out" 2>&1
check 'init succeeds' 0 "$?"
check 'init writes the configuration' yes "$([ -f "$r/config/vigil.config" ] && echo yes)"
check 'init writes the sample script' yes "$([ -f "$r/scripts/disk.sh" ] && echo yes)"
check 'init names the variables to set' 1 "$(grep -c '^  DATADOG_API_KEY$' "$work/out")"
check 'every credential is a reference' 0 "$(grep -E '^api_key' "$r/config/vigil.config" | grep -cvE '= *(env|secret|store):')"
DATADOG_API_KEY=x vigil "$r" precheck > "$work/out" 2>&1
check 'the configuration passes pre-flight' 0 "$?"
vigil "$r" run disk > /dev/null 2>&1
check 'the sample job succeeds' 0 "$?"
before=$(cksum < "$r/config/vigil.config")
vigil "$r" init > /dev/null 2>&1
check 'init again is refused' 1 "$?"
check 'and leaves the configuration alone' "$before" "$(cksum < "$r/config/vigil.config")"

r=$work/init2
make_root "$r"
vigil "$r" init --backend splunk > /dev/null 2>&1
check 'an unknown backend is refused' 1 "$?"
vigil "$r" init --instance 'a b' > /dev/null 2>&1
check 'a bad instance name is refused' 1 "$?"
check 'and nothing is written' no "$([ -e "$r/config/vigil.config" ] && echo yes || echo no)"
vigil "$r" init --no-sample > /dev/null 2>&1
check 'init --no-sample succeeds' 0 "$?"
check 'with no job' 0 "$(grep -c '^\[job\.' "$r/config/vigil.config")"
check 'defaults to the file backend' 1 "$(grep -c '^\[backend\.file\]$' "$r/config/vigil.config")"

# --- uninstall ----------------------------------------------------------------

# A root whose job holds on, started by a real supervisor that is then
# stopped, as a service stop would: the worker and its job carry on.
r=$work/un
make_root "$r"
mkdir -p "$r/config" "$r/scripts"
printf '%s\n' 'exec sleep 300' > "$r/scripts/hold.sh"
cat > "$r/config/vigil.config" <<EOF
[vigil]
instance = un

[scheduler]
tick = 1s

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.hold]
file      = scripts/hold.sh
run_every = 2s
EOF
"$BASH" "$r/app/vigil" --root "$r" supervise > /dev/null 2>&1 &
sup=$!
i=0
while [ "$i" -lt 60 ] && ! grep -q '^job_pid' "$r/state/jobs/hold.state" 2> /dev/null; do
    sleep 0.5
    i=$((i + 1))
done
kill -TERM "$sup"
wait "$sup"
wpid=$(sed -n 's/^worker_pid *= *//p' "$r/state/jobs/hold.state")
jpid=$(sed -n 's/^job_pid *= *//p' "$r/state/jobs/hold.state")
check 'the job is running' 0 "$(kill -0 "$jpid" 2> /dev/null; echo $?)"
# An unrelated process started from the root: never Vigil's to end.
(cd "$r" && exec sleep 300) &
decoy=$!

vigil "$r" uninstall > "$work/out" 2>&1
check 'uninstall without --yes off a terminal is refused' 1 "$?"
check 'and removes nothing' yes "$([ -d "$r/app" ] && echo yes)"

vigil "$r" uninstall --yes > "$work/out" 2>&1
check 'uninstall --yes succeeds' 0 "$?"
check 'it listed the processes it would end' 1 "$(grep -c "running Vigil processes:.*$jpid" "$work/out")"
check 'the root is gone' no "$([ -e "$r" ] && echo yes || echo no)"
sleep 1
check 'the job was ended' 1 "$(kill -0 "$jpid" 2> /dev/null; echo $?)"
check 'the worker was ended' 1 "$(kill -0 "$wpid" 2> /dev/null; echo $?)"
check 'the unrelated process was not' 0 "$(kill -0 "$decoy" 2> /dev/null; echo $?)"
kill "$decoy" 2> /dev/null

r=$work/keep
make_root "$r"
mkdir -p "$r/config" "$r/scripts" "$r/state/jobs" "$r/logs"
echo x > "$r/scripts/a.sh"
vigil "$r" init --no-sample > /dev/null 2>&1
vigil "$r" uninstall --yes --keep-config > /dev/null 2>&1
check 'uninstall --keep-config succeeds' 0 "$?"
check 'keeps config and scripts' 'config scripts' "$(ls "$r" | tr '\n' ' ' | sed 's/ $//')"
check 'keeps the configuration itself' yes "$([ -f "$r/config/vigil.config" ] && echo yes)"

mkdir -p "$work/notroot"
"$BASH" "$repo/app/vigil" --root "$work/notroot" uninstall --yes > /dev/null 2>&1
check 'a folder without app/vigil is refused' 1 "$?"
check 'and left alone' yes "$([ -d "$work/notroot" ] && echo yes)"

rm -rf "$work"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
