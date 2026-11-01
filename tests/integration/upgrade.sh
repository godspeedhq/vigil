#!/usr/bin/env bash
#
# Integration test: upgrading from the latest published release to this
# build (SPECIFICATION.md 18.7), on Linux and macOS. The real one-line
# installer installs the real release from GitHub, a real supervisor runs
# real jobs on it, and that release's own vigil self update moves it to this
# build, served by mock-files.py. The supervisor must carry on as the same
# process, with its jobs, state and metrics intact.
#
# HOME is a throwaway folder, so nothing of the account's own is touched.
# Under Git Bash a running script holds its own folder, so it is skipped.
#
# Needs curl and python3 (or python).
#
# Exit code: 0 all passed, 1 any failed.

set -u

case $(uname -s) in
    Linux | Darwin) ;;
    *)
        printf 'SKIP upgrade: needs Linux or macOS\n'
        exit 0
        ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-upgrade.XXXXXX")
work=$(cd "$work" && pwd)
root=$work/root
next=99.0.0-it
pass=0
fail=0
mock_pid=''
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
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

vigil() { bash "$root/app/vigil" --root "$root" "$@"; }
runs() { cat "$root"/logs/jobs/"$1"/*.log 2>/dev/null | grep -c 'run start'; }

# Waits up to 60 seconds for a command to print a value.
wait_for() {
    local want=$1 i=0
    shift
    while [ "$("$@" 2>/dev/null)" != "$want" ] && [ "$i" -lt 120 ]; do
        sleep 0.5
        i=$((i + 1))
    done
}

printf 'bash %s on %s\n' "$BASH_VERSION" "$(uname -s)"
python=''
for p in python3 python; do
    if "$p" -c 'import http.server' > /dev/null 2>&1; then
        python=$p
        break
    fi
done
[ -n "$python" ] || { echo "needs python3"; exit 1; }
mkdir -p "$work/home" "$work/mock/www/releases/tag"
export HOME=$work/home

# The published release, through the real one-liner.
curl -fsSL https://github.com/godspeedhq/vigil/releases/latest/download/install.sh |
    sh -s -- --user --prefix "$root" --instance upgrade --backend file --no-service > "$work/out" 2>&1
rc=$?
check 'the published release installs' 0 "$rc"
[ "$rc" -eq 0 ] || { cat "$work/out"; exit 1; }
old=$(cat "$root/app/VERSION")
printf 'upgrading from %s\n' "$old"

# Jobs that outlive the update: one always due, one running across it.
printf 'echo "metric beats 1"\n' > "$root/scripts/beat.sh"
printf 'sleep 12\necho "metric long 1"\n' > "$root/scripts/long.sh"
cat >> "$root/config/vigil.config" <<'EOF'

[job.beat]
file      = scripts/beat.sh
run_every = 2s

[job.long]
file      = scripts/long.sh
run_every = 3650d
EOF
sed -i.bak 's/^tick *= *.*/tick = 1s/' "$root/config/vigil.config" && rm -f "$root/config/vigil.config.bak"
grep -q '^tick' "$root/config/vigil.config" || printf '\n[scheduler]\ntick = 1s\n' >> "$root/config/vigil.config"
cfg=$(cksum < "$root/config/vigil.config")

vigil supervise > /dev/null 2>&1 &
sup=$!
i=0
while [ "$(runs beat)" -lt 2 ] && [ "$i" -lt 120 ]; do sleep 0.5; i=$((i + 1)); done
check 'jobs run on the published release' yes "$([ "$(runs beat)" -ge 2 ] && echo yes || echo no)"
vigil run long > "$work/long.out" 2>&1 &
long_pid=$!
i=0
while [ ! -f "$root/state/jobs/long.state" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
before=$(runs beat)

# This build, as a release on the mock.
"$python" "$here/mock-files.py" "$work/mock" 2> "$work/mock/stderr" &
mock_pid=$!
i=0
while [ ! -s "$work/mock/port" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
d=$work/mock/www/releases/download/v$next
mkdir -p "$d"
env -u VIGIL_SIGN_KEY bash "$repo/tools/release/package.sh" "$next" "$d" > /dev/null || { printf 'packaging failed\n'; exit 1; }
: > "$work/mock/www/releases/tag/v$next"
printf '/releases/latest /releases/tag/v%s\n' "$next" > "$work/mock/redirects"
export VIGIL_TEST_RELEASE_URL=http://127.0.0.1:$(cat "$work/mock/port")

# The published release updates itself.
vigil self update > "$work/out" 2>&1
rc=$?
check 'it updates itself' 0 "$rc"
[ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
check 'to this build' "$next" "$(cat "$root/app/VERSION")"
wait_for "$next" vigil version --supervisor
check 'the supervisor came up as this build' "$next" "$(vigil version --supervisor)"
check 'the same process' yes "$(kill -0 "$sup" 2>/dev/null && echo yes || echo no)"
check 'the configuration is untouched' "$cfg" "$(cksum < "$root/config/vigil.config")"

# Everything picks up where it left off.
wait "$long_pid"
check 'the job running across it finished' 1 "$(cat "$root"/logs/jobs/long/*.log | grep -c 'run end succeeded')"
check 'and ran once' 1 "$(runs long)"
i=0
while [ "$(runs beat)" -le $((before + 2)) ] && [ "$i" -lt 120 ]; do sleep 0.5; i=$((i + 1)); done
check 'scheduled jobs carry on' yes "$([ "$(runs beat)" -gt $((before + 2)) ] && echo yes || echo no)"
check 'no run crashed' 0 "$(grep -hc 'crashed' "$root"/logs/supervisor/2*.log | sort -n | tail -1)"
check 'metrics still flow' yes "$(grep -q '^beat_beats' "$root/metrics/vigil.prom" && echo yes || echo no)"
check 'nothing quarantined' no "$([ -d "$root/state/quarantine" ] && echo yes || echo no)"

if [ "$fail" -gt 0 ]; then
    tail -n 20 "$root"/logs/supervisor/2*.log
    cat "$root/metrics/vigil.prom" 2>/dev/null | head -20
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
