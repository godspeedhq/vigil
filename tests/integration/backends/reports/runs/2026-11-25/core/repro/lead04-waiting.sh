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
# Lead 4: a job with max_runtime = 20s is running under a local
# configuration. A [source.*] that cannot be reached is then added to the
# configuration (a change 16.1 allows without a restart). Is the run still
# held to its limit? With "control", nothing is added.
# Throwaway root. Ends only the supervisor it started and processes whose
# command line names that root.
. "$(dirname "$0")/common.sh"
mode=${1:-source}

R=$(newroot)
sed -i.bak 's/^tick *=.*/tick = 5s/' "$R/config/vigil.config"
printf 'sleep 300\n' > "$R/scripts/long.sh"
printf '\n[job.long]\nfile = scripts/long.sh\nrun_every = 1m\nmax_runtime = 20s\n' >> "$R/config/vigil.config"
say "mode: $mode"
echo "precheck: $(v precheck 2>&1 | tail -n 1)"
bash "$R/app/vigil" --root "$R" supervise > "$R/sup.out" 2>&1 < /dev/null &
sup=$!
# A new job first runs at the slot after the supervisor's first tick (7.6).
w=$((60 - 10#$(date +%S))); [ "$w" -lt 15 ] && w=$((w + 60))
sleep "$w"
for _ in $(seq 1 20); do grep -q '^status *= *running' "$R/state/jobs/long.state" 2> /dev/null && break; sleep 1; done
started=$(sed -n 's/^started_epoch *= *//p' "$R/state/jobs/long.state")
echo "run started; state: $(sed -n 's/^status *= *//p' "$R/state/jobs/long.state"), deadline_epoch - started_epoch = $(( $(sed -n 's/^deadline_epoch *= *//p' "$R/state/jobs/long.state") - started ))"
if [ "$mode" = source ]; then
    printf '\n[source.extra]\ntype = local\npath = /nonexistent-vv-source\n\n[job.fromsource]\nsource = extra\nfile = check.sh\nrun_every = 1h\n' >> "$R/config/vigil.config"
    echo "added to the configuration, $(( $(date +%s) - started )) s into the run: [source.extra] (local, a path that is not there) and [job.fromsource], whose script comes from it"
fi
sleep 95
age=$(( $(date +%s) - started ))
echo
echo "$age s after the run started (max_runtime 20s, tick 5s, grace 30s):"
echo "  state: status = $(sed -n 's/^status *= *//p' "$R/state/jobs/long.state")"
echo "  the job's sleep still running: $(pgrep -f "$R/scripts/long.sh" > /dev/null && echo yes || echo no)"
echo "  timeout marker: $(ls "$R"/state/locks/*.timeout 2> /dev/null | wc -l)"
echo "  jobs.log:"; sed 's/^/    /' "$R/logs/supervisor/jobs.log" 2> /dev/null | head -n 14
echo "  the supervisor's log:"; grep -v 'vigil_sender\|vigil_logs' "$R"/logs/supervisor/2*.log | sed "s#$R#<root>#g; s/^/    /" | tail -n 8
# Ours only.
kill "$sup" 2> /dev/null
pkill -f "$R/" 2> /dev/null
sleep 1
rm -rf "$R"
