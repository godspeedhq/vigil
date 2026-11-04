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
# run-update.sh - a real update on a real machine (SPECIFICATION.md 18.7):
# a published release, installed by its own installer from GitHub, updates
# itself to the latest release from GitHub, with no test overrides. The
# supervisor must carry on as the same process, with its jobs, state and
# metrics intact. Unlike tests/integration/upgrade.sh, nothing is mocked and
# nothing is built here.
#
#   scripts/run-update.sh [from version]     (default: 0.2.0)
#
# HOME and the install root are a throwaway folder, so a Vigil already
# installed on this machine, and the account's own files, are not touched.
# No Docker, no backend. Its evidence is kept like the other runs'.
#
# Exit code: 0 all passed, 1 any failed.

# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

from=${1:-0.2.0}
from=${from#v}
github=https://github.com/godspeedhq/vigil
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-update.XXXXXX")
work=$(cd "$work" && pwd)
root=$work/root
pass=0
fail=0
sup=''
long_pid=''

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
    # The supervisor and run this script started, and nothing else.
    [ -n "$sup" ] && kill "$sup" 2> /dev/null
    [ -n "$long_pid" ] && kill "$long_pid" 2> /dev/null
    sleep 1
    evidence_save
    rm -rf "$work"
}
trap cleanup EXIT

vigil() { bash "$root/app/vigil" --root "$root" "$@"; }
runs() { cat "$root"/logs/jobs/"$1"/*.log 2> /dev/null | grep -c 'run start'; }

evidence_start "update-from-$from" '' "$0" "$@"
mkdir -p "$work/home"
export HOME=$work/home
# The real release server, and the real release key: no test overrides.
unset VIGIL_TEST_RELEASE_URL VIGIL_TEST_RELEASE_KEY VIGIL_FAULT

# Where GitHub's latest release redirects is the version to expect.
latest=$(curl -fsS -o /dev/null -w '%{redirect_url}' "$github/releases/latest")
latest=${latest##*/v}
printf 'updating from %s; the latest release is %s\n\n' "$from" "$latest"
[ -n "$latest" ] && [ "$latest" != "$from" ] || die "nothing to update to: the latest release is [$latest]"

# The old release, through its own installer, as its users ran it.
curl -fsSL "$github/releases/download/v$from/install.sh" |
    sh -s -- --user --version "$from" --prefix "$root" --instance update --backend file --no-service > "$work/install.out" 2>&1
rc=$?
check "Vigil $from installs from GitHub" 0 "$rc"
[ "$rc" -eq 0 ] || { cat "$work/install.out"; exit 1; }
check "and is $from" "$from" "$(cat "$root/app/VERSION")"
# From 0.2.1 on, a release carries the release key, and its self update
# refuses what the key did not sign. It says nothing when the signature is
# good, so the run checks the same signature with the same key itself.
if [ -f "$root/app/release-key.pem" ]; then
    cp "$root/app/release-key.pem" "$work/old-key.pem"
    printf 'Vigil %s has the release key: its update must be signed by it\n' "$from"
else
    printf 'Vigil %s has no release key: its update checks the SHA-256 only (signed releases began with 0.2.1)\n' "$from"
fi

# Jobs that outlive the update: one always due, one running across it.
printf 'echo "metric beats 1"\n' > "$root/scripts/beat.sh"
printf 'sleep 20\necho "metric long 1"\n' > "$root/scripts/long.sh"
cat >> "$root/config/vigil.config" << 'EOF'

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

vigil supervise > "$work/supervise.out" 2>&1 &
sup=$!
i=0
while [ "$(runs beat)" -lt 2 ] && [ "$i" -lt 120 ]; do sleep 0.5; i=$((i + 1)); done
check "jobs run on $from" yes "$([ "$(runs beat)" -ge 2 ] && echo yes || echo no)"
check "the supervisor is $from" "$from" "$(vigil version --supervisor 2> /dev/null)"
vigil run long > "$work/long.out" 2>&1 &
long_pid=$!
i=0
while [ ! -f "$root/state/jobs/long.state" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
before=$(runs beat)

printf '\n$ vigil self update --check\n'
vigil self update --check 2>&1 | tee "$work/check.out"
printf '\n$ vigil self update\n'
vigil self update > "$work/update.out" 2>&1
rc=$?
cat "$work/update.out"
printf '\n'
check 'it updates itself from GitHub' 0 "$rc"
check "to $latest" "$latest" "$(cat "$root/app/VERSION")"
i=0
while [ "$(vigil version --supervisor 2> /dev/null)" != "$latest" ] && [ "$i" -lt 120 ]; do sleep 0.5; i=$((i + 1)); done
check "the supervisor came up as $latest" "$latest" "$(vigil version --supervisor 2> /dev/null)"
check 'the same process' yes "$(kill -0 "$sup" 2> /dev/null && echo yes || echo no)"
check 'the configuration is untouched' "$cfg" "$(cksum < "$root/config/vigil.config")"
if [ -f "$work/old-key.pem" ]; then
    for f in SHA256SUMS SHA256SUMS.sig; do curl -fsSL -o "$work/$f" "$github/releases/download/v$latest/$f"; done
    check "$latest is signed by the key $from has" yes "$(openssl dgst -sha256 -verify "$work/old-key.pem" -signature "$work/SHA256SUMS.sig" "$work/SHA256SUMS" > /dev/null 2>&1 && echo yes || echo no)"
fi
check "$latest has the release key" yes "$([ -f "$root/app/release-key.pem" ] && echo yes || echo no)"

# Everything picks up where it left off.
wait "$long_pid"
long_pid=''
check 'the job running across it finished' 1 "$(cat "$root"/logs/jobs/long/*.log | grep -c 'run end succeeded')"
check 'and ran once' 1 "$(runs long)"
i=0
while [ "$(runs beat)" -le $((before + 2)) ] && [ "$i" -lt 120 ]; do sleep 0.5; i=$((i + 1)); done
check 'scheduled jobs carry on' yes "$([ "$(runs beat)" -gt $((before + 2)) ] && echo yes || echo no)"
check 'no run crashed' 0 "$(cat "$root"/logs/supervisor/2*.log | grep -c 'crashed')"
check 'metrics still flow' yes "$(grep -q '^beat_beats' "$root/metrics/vigil.prom" && echo yes || echo no)"
check 'nothing quarantined' no "$([ -d "$root/state/quarantine" ] && echo yes || echo no)"

# Now on the latest, there is nothing to update to.
printf '\n$ vigil self update\n'
vigil self update > "$work/again.out" 2>&1
rc=$?
cat "$work/again.out"
printf '\n'
check 'a second update finds nothing newer' 0 "$rc"
check "and leaves $latest in place" "$latest" "$(cat "$root/app/VERSION")"

if [ "$fail" -gt 0 ]; then
    tail -n 30 "$root"/logs/supervisor/2*.log
fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
