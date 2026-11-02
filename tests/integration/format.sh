#!/usr/bin/env bash
#
# Integration test: the data format and its migrations (SPECIFICATION.md
# 18.7) on Linux and macOS. Runs a copy of app/ with migrations of its own, so
# nothing here depends on a real format change.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-format.XXXXXX")
work=$(cd "$work" && pwd)
root=$work/root
pass=0
fail=0
sup=''

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
    fi
}

cleanup() {
    [ -n "$sup" ] && kill "$sup" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

vigil() { bash "$root/app/vigil" --root "$root" "$@"; }
stored() { cat "$root/state/format" 2>/dev/null; }
good() { printf 'printf "%%s\\n" "%s $1 $2 $3" >> "$1/trace"\n' "$1" > "$root/app/migrations/$1.sh"; }
bad() { printf 'exit 3\n' > "$root/app/migrations/$1.sh"; }
syslog() { cat "$root"/logs/supervisor/2*.log 2>/dev/null; }

# Waits up to 30 seconds for a file to match.
wait_grep() {
    local i=0
    while ! grep -q "$1" "$2" 2>/dev/null && [ "$i" -lt 60 ]; do
        sleep 0.5
        i=$((i + 1))
    done
}
wait_log() {
    local i=0
    while ! syslog | grep -q "$1" && [ "$i" -lt 60 ]; do
        sleep 0.5
        i=$((i + 1))
    done
}

printf 'bash %s on %s\n' "$BASH_VERSION" "$(uname -s)"
mkdir -p "$root"
cp -R "$repo/app" "$repo/vendor" "$root/"
printf '1.0.0\n' > "$root/app/VERSION"
vigil init --instance format --backend file --no-sample > /dev/null 2>&1
mkdir -p "$root/app/migrations"
sed -i.bak 's/^tick *= *.*/tick = 1s/' "$root/config/vigil.config" && rm -f "$root/config/vigil.config.bak"

printf 'A fresh install\n'
vigil supervise --once > /dev/null 2>&1
check 'starts' 0 "$?"
check 'is format 1' 1 "$(stored)"

printf 'An install from before formats\n'
rm -f "$root/state/format"
vigil precheck > "$work/out" 2>&1
check 'precheck reads it as format 1' yes "$(grep -q 'data format: 1$' "$work/out" && echo yes || echo no)"
vigil supervise --once > /dev/null 2>&1
check 'is stamped format 1' 1 "$(stored)"

printf 'Migrations\n'
good 2
good 3
vigil precheck > "$work/out" 2>&1
check 'precheck says what will move' yes "$(grep -q 'data format: 1, moves to 3' "$work/out" && echo yes || echo no)"
vigil supervise --once > /dev/null 2>&1
check 'run' 0 "$?"
check 'reach the highest' 3 "$(stored)"
check 'in order, given the directories' "2 $root/state $root/spool $root/logs|3 $root/state $root/spool $root/logs" "$(tr '\n' '|' < "$root/state/trace" | sed 's/|$//')"
vigil supervise --once > /dev/null 2>&1
check 'run once only' 2 "$(wc -l < "$root/state/trace" | tr -d ' ')"

printf 'A migration that fails\n'
good 4
bad 5
good 6
rm -f "$root/state/trace"
vigil supervise --once > "$work/out" 2>&1
check 'stops the start' 1 "$?"
check 'says which' yes "$(grep -q 'migration 5 failed' "$work/out" && echo yes || echo no)"
check 'keeps the step before it' 4 "$(stored)"
good 5
vigil supervise --once > /dev/null 2>&1
check 'is retried, not repeated' '4|5|6' "$(cut -d' ' -f1 "$root/state/trace" | tr '\n' '|' | sed 's/|$//')"
check 'and finishes' 6 "$(stored)"
good 8
vigil supervise --once > "$work/out" 2>&1
check 'a gap stops the start' yes "$(grep -q 'migration 7 is missing' "$work/out" && echo yes || echo no)"
check 'and moves nothing' 6 "$(stored)"
rm -f "$root/app/migrations/8.sh"

printf 'Data of a newer format\n'
printf '7\n' > "$root/state/format"
vigil supervise --once > "$work/out" 2>&1
check 'is refused' 1 "$?"
check 'says so' yes "$(grep -q 'format 7, newer than the format 6' "$work/out" && echo yes || echo no)"
check 'is not touched' 7 "$(stored)"
vigil precheck > "$work/out" 2>&1
check 'precheck fails' 1 "$?"
printf 'six\n' > "$root/state/format"
vigil supervise --once > "$work/out" 2>&1
check 'an unreadable number is refused' 1 "$?"
printf '6\n' > "$root/state/format"

printf 'A hot reload\n'
rm -f "$root/state/supervisor.version"
vigil supervise > /dev/null 2>&1 &
sup=$!
wait_grep '^1.0.0$' "$root/state/supervisor.version"
: > "$root/state/trace"
bad 7
printf '2.0.0\n' > "$root/app/VERSION"
wait_log 'staying on Vigil 1.0.0'
check 'a failed migration keeps the supervisor' yes "$(kill -0 "$sup" 2>/dev/null && echo yes || echo no)"
check 'on the same version' 1.0.0 "$(cat "$root/state/supervisor.version")"
check 'and the data where it was' 6 "$(stored)"
check 'and says why, once' 1 "$(syslog | grep -c 'staying on Vigil 1.0.0')"
printf '1.0.0\n' > "$root/app/VERSION"
sleep 5
good 7
printf '2.0.0\n' > "$root/app/VERSION"
wait_grep '^2.0.0$' "$root/state/supervisor.version"
check 'the retried update reloads' 2.0.0 "$(cat "$root/state/supervisor.version")"
check 'the same process' yes "$(kill -0 "$sup" 2>/dev/null && echo yes || echo no)"
check 'the data moved' 7 "$(stored)"
check 'by that one step' 7 "$(cut -d' ' -f1 "$root/state/trace" | tr '\n' ' ' | sed 's/ $//')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
