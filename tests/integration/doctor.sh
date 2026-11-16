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
# reports: its cost, the cores Vigil's runs keep busy (ok, and WARN from a
# made-up history), the shell start, a log folder this account cannot read,
# and a root with no runs. The twin of Doctor.ps1.
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
has 'no runs: said so' "$out" '^  note  no runs in the last hour$'
has 'no runs: the shell start' "$out" '^  ok    /.*bash: [0-9]+\.[0-9]{2} CPU s'

echo '== cpu_seconds'
vigil run burn > /dev/null 2>&1
vigil run burn > /dev/null 2>&1
vigil run idle > /dev/null 2>&1
cpu=$(state_value "$root/state/jobs/burn.state" cpu_seconds)
check 'burn: cpu_seconds is a number' yes "$(printf '%s' "$cpu" | grep -Eq '^[0-9]+\.[0-9]{2}$' && echo yes || echo "$cpu")"
check 'burn: cpu_seconds is not zero' yes "$(awk -v c="$cpu" 'BEGIN { print (c > 0) ? "yes" : "no" }')"
check 'burn: its run end line has it' yes "$(tail -n 1 "$root"/logs/jobs/burn/*.log | grep -Eq " run end succeeded in [0-9]+s, cpu ${cpu}s\$" && echo yes || echo no)"
check 'idle: cpu_seconds recorded' yes "$(grep -Eq '^cpu_seconds *= [0-9]+\.[0-9]{2}$' "$root/state/jobs/idle.state" && echo yes || echo no)"

echo '== doctor'
out=$(vigil doctor 2>&1); code=$?
printf '%s\n' "$out" | sed 's/^/    | /'
check 'doctor: exit code' 0 "$code"
has 'doctor: burn ran twice in the hour' "$out" '^  burn +2 +[0-9]+\.[0-9]{2} s +[0-9]+\.[0-9]{2} s +[0-9]+\.[0-9] s$'
has 'doctor: idle ran once' "$out" '^  idle +1 '
has 'doctor: the cores, ok' "$out" "^  ok    Vigil's runs keep 0\.[0-9]{2} of a core busy\$"
has 'doctor: the runner shell' "$out" '^  ok    /bin/sh: '
has 'doctor: the summary' "$out" '^doctor: no warnings$'

echo '== above half a core'
mkdir -p "$root/logs/jobs/heavy"
now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
i=0
while [ "$i" -lt 60 ]; do printf '%s r%d run end succeeded in 41s, cpu 40.50s\n' "$now" "$i"; i=$((i + 1)); done > "$root/logs/jobs/heavy/today.log"
# Before Vigil recorded the CPU: counted, without it.
printf '%s r-before run end failed (exit code 2) in 41s\n' "$now" >> "$root/logs/jobs/heavy/today.log"
# Outside the last hour: not counted.
printf '2020-01-01T00:00:00Z r-old run end succeeded in 41s, cpu 40.50s\n' >> "$root/logs/jobs/heavy/today.log"
out=$(vigil doctor 2>&1); code=$?
check 'heavy: exit code' 1 "$code"
has 'heavy: first, 61 runs in the hour' "$out" '^  heavy +61 +2430\.00 s +40\.50 s +41\.0 s$'
has 'heavy: WARN' "$out" "^  WARN  Vigil's runs keep 0\.6[78] of a core busy, above half of one"
has 'heavy: the run without CPU' "$out" '^  note  1 run\(s\) show no CPU'
has 'heavy: the summary' "$out" '^doctor: 1 warning\(s\)$'
rm -rf "$root/logs/jobs/heavy"

if [ "$(id -u)" != 0 ]; then
    echo '== a log folder this account cannot read'
    chmod 000 "$root/logs/jobs"
    out=$(vigil doctor 2>&1); code=$?
    chmod 755 "$root/logs/jobs"
    check 'unreadable: exit code' 1 "$code"
    has 'unreadable: says which' "$out" "^  WARN  cannot read $root/logs/jobs from this account"
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
