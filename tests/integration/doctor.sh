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
# Integration test: what a run costs (cpu_seconds, SPECIFICATION.md 12.2)
# and "vigil doctor" (16.7) on Linux and macOS. Builds a throwaway install
# root, runs a job that does work, and checks its state and what doctor
# reports: its cost, the cores Vigil keeps busy (ok, and WARN from a made-up
# history), the shell start, a state folder this account cannot read, and
# a root with no runs. The twin of Doctor.ps1.
#
# Exit code: 0 all passed, 1 any failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$(dirname "$here")")
vigil_cmd=$repo/app/vigil
root=${TMPDIR:-/tmp}/vigil-doctor.$$
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

# Whether the text $2 has a line matching the extended regular expression $3.
has() {
    if printf '%s\n' "$2" | grep -Eq -- "$3"; then check "$1" yes yes
    else check "$1" "a line matching $3" "$2"; fi
}

state_value() {
    sed -n "s/^$2 *= \{0,1\}//p" "$1"
}

vigil() { /bin/bash "$vigil_cmd" --root "$root" "$@"; }

printf 'bash %s\n' "$BASH_VERSION"
mkdir -p "$root/config" "$root/scripts"
root=$(cd "$root" && pwd)
cat > "$root/scripts/burn.sh" <<'EOF'
#!/bin/sh
i=0
while [ "$i" -lt 200000 ]; do i=$((i + 1)); done
echo "metric loops $i"
EOF
cat > "$root/scripts/idle.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$root/scripts/burn.sh" "$root/scripts/idle.sh"
cat > "$root/config/vigil.config" <<'EOF'
[vigil]
instance = doctor

[runner.sh]
command = /bin/sh

[runners]
.sh = sh

[job.burn]
file      = scripts/burn.sh
run_every = 5m

[job.idle]
file      = scripts/idle.sh
run_every = 5m
EOF

echo '== no runs yet'
out=$(vigil doctor 2>&1); code=$?
check 'no runs: exit code' 0 "$code"
has 'no runs: said so' "$out" '^  note  no runs recorded yet$'
has 'no runs: the shell start' "$out" '^  ok    /.*bash: [0-9]+\.[0-9]{2} CPU s'

echo '== cpu_seconds'
vigil run burn > /dev/null 2>&1
vigil run burn > /dev/null 2>&1
vigil run idle > /dev/null 2>&1
cpu=$(state_value "$root/state/jobs/burn.state" cpu_seconds)
check 'burn: cpu_seconds is a number' yes "$(printf '%s' "$cpu" | grep -Eq '^[0-9]+\.[0-9]{2}$' && echo yes || echo "$cpu")"
check 'burn: cpu_seconds is not zero' yes "$(awk -v c="$cpu" 'BEGIN { print (c > 0) ? "yes" : "no" }')"
check 'idle: cpu_seconds recorded' yes "$(grep -Eq '^cpu_seconds *= [0-9]+\.[0-9]{2}$' "$root/state/jobs/idle.state" && echo yes || echo no)"

echo '== doctor'
out=$(vigil doctor 2>&1); code=$?
printf '%s\n' "$out" | sed 's/^/    | /'
check 'doctor: exit code' 0 "$code"
has 'doctor: burn ran twice in the hour' "$out" "^  burn +2 +$cpu s +[0-9]+ s$"
has 'doctor: idle ran once' "$out" '^  idle +1 '
has 'doctor: the cores, ok' "$out" '^  ok    Vigil keeps 0\.[0-9]{2} of a core busy$'
has 'doctor: the runner shell' "$out" '^  ok    /bin/sh: '
has 'doctor: the summary' "$out" '^doctor: no warnings$'

echo '== above half a core'
printf '[state]\njob = heavy\ncpu_seconds = 40.50\nduration_seconds = 41\n' > "$root/state/jobs/heavy.state"
mkdir -p "$root/logs/jobs/heavy"
now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
i=0
while [ "$i" -lt 60 ]; do printf '%s r%d run start\n' "$now" "$i"; i=$((i + 1)); done > "$root/logs/jobs/heavy/today.log"
# Outside the last hour: not counted.
printf '2020-01-01T00:00:00Z r-old run start\n' >> "$root/logs/jobs/heavy/today.log"
out=$(vigil doctor 2>&1); code=$?
check 'heavy: exit code' 1 "$code"
has 'heavy: first, 60 runs in the hour' "$out" '^  heavy +60 +40\.50 s +41 s$'
has 'heavy: WARN' "$out" '^  WARN  Vigil keeps 0\.[6-9][0-9] of a core busy, above half of one'
has 'heavy: the summary' "$out" '^doctor: 1 warning\(s\)$'
rm -rf "$root/state/jobs/heavy.state" "$root/logs/jobs/heavy"

if [ "$(id -u)" != 0 ]; then
    echo '== a state folder this account cannot read'
    chmod 000 "$root/state/jobs"
    out=$(vigil doctor 2>&1); code=$?
    chmod 755 "$root/state/jobs"
    check 'unreadable: exit code' 1 "$code"
    has 'unreadable: says which' "$out" "^  WARN  cannot read $root/state/jobs from this account"
    has 'unreadable: the shell start still' "$out" '^Starting a shell'

    echo '== a configuration this account cannot read'
    chmod 000 "$root/config/vigil.config"
    out=$(vigil doctor 2>&1); code=$?
    chmod 644 "$root/config/vigil.config"
    check 'config unreadable: exit code' 1 "$code"
    has 'config unreadable: says which' "$out" "^  WARN  cannot read $root/config/vigil.config from this account"
    has 'config unreadable: the shell start still' "$out" '^  ok    /.*bash: '
fi

rm -rf "$root"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
