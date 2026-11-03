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
# tour.sh - a tour of Vigil on Linux or macOS, for the "Logs and output"
# page. The twin of Tour.ps1.
#
#   bash tools/docs/tour.sh
#
# Installs this checkout in a temporary folder, runs the commands people use
# every day, runs the supervisor for real for a minute or two, and prints
# each command's output and each log file as it is. CI runs it on main, and
# tour-page.sh turns that console output into the page, so nothing on the
# page is typed by hand.
#
# The temporary folder is shown as /opt/vigil, where a system install puts
# it; nothing else is changed. Lines starting with :: mark where each piece
# begins, for tour-page.sh:
#
#   ::section <title>    ::note <text>    ::cmd <command>    ::file <path>
#
# Exit code: 0, or 1 if Vigil could not be set up at all.

set -u

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-tour.XXXXXX") || exit 1
work=$(cd "$work" && pwd -P)
root=$work/root
shown=/opt/vigil
sup=''

cleanup() {
    # The supervisor this script started, and nothing else.
    [ -n "$sup" ] && kill "$sup" 2> /dev/null
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' TERM INT HUP

# The temporary root, as a system install would have it.
mask() { sed "s#$root#$shown#g"; }

section() { printf '::section %s\n' "$*"; }
note() { printf '::note %s\n' "$*"; }

# Runs vigil with the given arguments, shown as typed, then its exit code.
cmd() {
    local rc
    printf '::cmd vigil %s\n' "$*"
    bash "$root/app/vigil" --root "$root" "$@" < /dev/null 2>&1 | mask
    rc=${PIPESTATUS[0]}
    printf '(exit code %s)\n' "$rc"
}

# Prints a file under the root, or the part of it from the first line
# matching a pattern.
file() {
    printf '::file %s\n' "$shown/$1"
    if [ -n "${2-}" ]; then awk -v re="$2" '$0 ~ re { on = 1 } on' "$root/$1" | mask; else mask < "$root/$1"; fi
}

# Prints the lines of a file under the root that match a pattern.
lines() {
    printf '::file %s\n' "$shown/$1"
    grep -E "$2" "$root/$1" | mask
}

# How many times the supervisor has logged a line matching a pattern.
logged() { cat "$root"/logs/supervisor/2*.log 2> /dev/null | grep -cE "$1"; }

# Waits up to 30 seconds for the supervisor to log one more such line.
wait_logged() {
    local i=0
    while [ "$i" -lt 30 ] && [ "$(logged "$1")" -le "$2" ]; do
        sleep 1
        i=$((i + 1))
    done
}

# Waits up to $1 seconds for a line matching $2 in file $3.
wait_for() {
    local i=0
    while [ "$i" -lt "$1" ]; do
        grep -qE "$2" $3 2> /dev/null && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

case $(uname -s) in Darwin) os=macos ;; *) os=linux ;; esac
mkdir -p "$root/packs/base" "$root/scripts"
cp -R "$repo/app" "$repo/vendor" "$root/" &&
    cp "$repo/packs/base/pack.config" "$repo/packs/base/$os"/* "$root/packs/base/" || exit 1

section 'What is installed'
cmd version
cmd about

section 'A first configuration'
note 'vigil init writes a commented configuration with the base pack turned on. Away from a console it asks no questions.'
cmd init --instance web-01 --backend file
[ -f "$root/config/vigil.config" ] || exit 1
cmd pack list

# Two jobs of our own: one that fails, and one that runs too long.
cat > "$root/scripts/backup_check.sh" <<'EOF'
#!/usr/bin/env bash
# Fails on purpose: the last backup is too old.
echo "metric age_hours 31"
echo "last backup is 31 hours old (limit 24)" >&2
exit 2
EOF
cat > "$root/scripts/report.sh" <<'EOF'
#!/usr/bin/env bash
# Hangs on purpose, to be stopped at max_runtime.
echo "building the report"
sleep 600
EOF
cat >> "$root/config/vigil.config" <<'EOF'

[job.backup_check]
file = scripts/backup_check.sh
run_every = 1m

[job.report]
file = scripts/report.sh
run_every = 1m
max_runtime = 15s
grace = 5s
EOF
section 'Two jobs of our own'
note 'One fails on purpose and one hangs on purpose, to show what Vigil does with each.'
file config/vigil.config '^\[job\.backup_check\]'
file scripts/backup_check.sh
file scripts/report.sh

section 'Checking before running'
cmd precheck
cp "$root/config/vigil.config" "$work/good.config"
printf '\n[job.broken]\nfile = scripts/missing.sh\nrun_every = soon\n' >> "$root/config/vigil.config"
note 'A mistake: a job with a schedule Vigil cannot read. precheck says what is wrong, and where.'
cmd precheck
cp "$work/good.config" "$root/config/vigil.config"

section 'Running a job by hand'
cmd run base_cpu
cmd run backup_check
cmd run no_such_job

section 'Secrets'
note 'The value comes from standard input, or a hidden prompt at a console. It is never shown again.'
printf '::cmd %s\n' "printf 's3cret' | vigil secret set DB_PASSWORD --stdin"
printf 's3cret' | bash "$root/app/vigil" --root "$root" secret set DB_PASSWORD --stdin 2>&1 | mask
printf '(exit code %s)\n' "${PIPESTATUS[1]}"
cmd secret list

section 'Turning pack jobs off and on'
cmd pack disable base_disk
cmd pack list
cmd pack enable base_disk

# --- The supervisor, for real ---------------------------------------------------

bash "$root/app/vigil" --root "$root" supervise < /dev/null > "$work/supervise.out" 2>&1 &
sup=$!
section 'The supervisor at work'
note 'Here the supervisor runs straight from the command line rather than as a service, for a minute or two. Jobs with run_every = 1m start on the next whole minute.'
wait_for 150 'status += timed_out' "$root/state/jobs/report.state"
wait_for 30 'run end' "$root/logs/jobs/base_disk/*.log"
cmd status
file logs/supervisor/jobs.log

section 'Mistakes while it runs'
note 'A broken job is set aside as INVALID, and every other job keeps running.'
printf '\n[job.broken]\nfile = scripts/missing.sh\nrun_every = soon\n' >> "$root/config/vigil.config"
wait_for 30 '^INVALID' "$root/logs/supervisor/jobs.log"
file logs/supervisor/jobs.log
n=$(logged 'configuration loaded')
cp "$work/good.config" "$root/config/vigil.config"
wait_logged 'configuration loaded' "$n"
note 'A mistake outside any job, here a misspelt section name, rejects the whole file. The last good configuration stays active, and the supervisor says so in its log and in jobs.log.'
n=$(logged 'configuration rejected')
printf '\n[schedular]\ntick = 30s\n' >> "$root/config/vigil.config"
wait_logged 'configuration rejected' "$n"
wait_for 30 '^CONFIGURATION REJECTED' "$root/logs/supervisor/jobs.log"
file logs/supervisor/jobs.log
lines logs/supervisor/$(cd "$root/logs/supervisor" && ls 2*.log | tail -n 1) 'ERROR'
note 'Then the mistake is put right, and the supervisor loads it at its next tick.'
n=$(logged 'configuration loaded')
cp "$work/good.config" "$root/config/vigil.config"
wait_logged 'configuration loaded' "$n"

section 'The logs'
kill "$sup" 2> /dev/null
wait "$sup" 2> /dev/null
sup=''
for f in "$root"/logs/supervisor/2*.log; do file "logs/supervisor/${f##*/}"; done
for j in base_cpu base_disk backup_check report; do
    for f in "$root/logs/jobs/$j"/*.log; do [ -f "$f" ] && file "logs/jobs/$j/${f##*/}"; done
done

section 'State and metrics'
note 'Each job has a state file: how its last run ended, and why.'
file state/jobs/report.state
note 'The file backend writes the metrics in the Prometheus text format, for node_exporter or a test. A few of them:'
lines metrics/vigil.prom '^(system_cpu|system_memory_used|backup_check|report)'
printf '::done\n'
