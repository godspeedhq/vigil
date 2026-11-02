#!/usr/bin/env bash
#
# Integration test: the base pack on this machine (SPECIFICATION.md 18.10).
# vigil init turns it on, each job runs, and its metrics reach a backend. The
# twin of Base-Pack.ps1.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-base.XXXXXX")
work=$(cd "$work" && pwd)
root=$work/root
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
trap 'rm -rf "$work"' EXIT

vigil() { bash "$root/app/vigil" --root "$root" "$@"; }
reports() {
    if grep -q "^$1" "$root/metrics/vigil.prom" 2> /dev/null; then echo yes; else echo no; fi
}

printf 'bash %s on %s\n' "$BASH_VERSION" "$(uname -s)"
case $(uname -s) in Darwin) os=macos ;; *) os=linux ;; esac
mkdir -p "$root/packs/base"
cp -R "$repo/app" "$repo/vendor" "$root/"
cp "$repo/packs/base/pack.config" "$repo/packs/base/$os"/* "$root/packs/base/"

vigil init --instance base --backend file > "$work/out" 2>&1
check 'init turns on the base pack' 0 "$?"
sed 's/^/        /' "$work/out" | grep 'on: '
check 'precheck is happy' 0 "$(vigil precheck > /dev/null 2>&1; echo $?)"

for j in cpu memory disk network load services; do
    vigil run "base_$j" > "$work/out" 2>&1
    rc=$?
    check "base_$j runs" 0 "$rc"
    [ "$rc" -eq 0 ] || sed 's/^/        /' "$work/out"
    grep -h '^[^ ]* [^ ]* out metric' "$root/logs/jobs/base_$j"/*.log 2> /dev/null | sed 's/^[^ ]* [^ ]* out /        /' | head -3
done

# The sender delivers from the spool.
vigil supervise --once > /dev/null 2>&1
sleep 3
vigil supervise --once > /dev/null 2>&1
sleep 3
vigil supervise --once > /dev/null 2>&1
check 'CPU reaches the backend' yes "$(reports system_cpu_used_pct)"
check 'memory reaches the backend' yes "$(reports system_memory_used_pct)"
check 'disk reaches the backend' yes "$(reports system_disk_used_pct)"
check 'network reaches the backend' yes "$(reports system_network_rx_bytes)"
check 'load reaches the backend' yes "$(reports system_load_load1)"
check 'nothing failed' 0 "$(grep -c 'run end failed' "$root"/logs/jobs/base_*/*.log | awk -F: '{ n += $2 } END { print n + 0 }')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
