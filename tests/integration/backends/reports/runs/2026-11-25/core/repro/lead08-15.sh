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
# Two reload leads, one per mode. Throwaway root; ends only the supervisor
# it started and processes whose command line names that root.
#   statedir: a run is alive; [vigil] state_dir is changed. Is a second run
#             of the same job started beside it?
#   queued:   overlap = queue_one holds a run; the job is then disabled.
#             Is the held run still started when the active one ends?
. "$(dirname "$0")/common.sh"
mode=$1
R=$(newroot)
sed -i.bak 's/^tick *=.*/tick = 5s/' "$R/config/vigil.config"
slot() { local w=$((60 - 10#$(date +%S))); [ "$w" -lt "${1:-15}" ] && w=$((w + 60)); sleep "$w"; }
suplog() { grep -v 'vigil_sender\|vigil_logs\|vigil_fetch' "$R"/logs/supervisor/2*.log | sed "s#$R#<root>#g; s/^/    /"; }
say "mode: $mode"

if [ "$mode" = statedir ]; then
    printf 'sleep 200\n' > "$R/scripts/long.sh"
    printf '\n[job.long]\nfile = scripts/long.sh\nrun_every = 1m\n' >> "$R/config/vigil.config"
    bash "$R/app/vigil" --root "$R" supervise > "$R/sup.out" 2>&1 < /dev/null &
    sup=$!
    slot 15
    for _ in $(seq 1 20); do grep -q '^status *= *running' "$R/state/jobs/long.state" 2> /dev/null && break; sleep 1; done
    echo "a run of long is alive: $(pgrep -f "$R/scripts/long.sh" | wc -l) process(es); token: $(ls "$R/state/locks" | tr '\n' ' ')"
    sed -i.bak 's/^\[vigil\]$/[vigil]\nstate_dir = state2/' "$R/config/vigil.config"
    echo "edited: [vigil] state_dir = state2 ($(grep -c '^state_dir' "$R/config/vigil.config") line)"
    slot 20; sleep 12
    echo
    echo "after the next slot:"
    echo "  processes running the job's script: $(pgrep -f "$R/scripts/long.sh" | wc -l)"
    echo "  tokens in state/locks:  $(ls "$R/state/locks" 2> /dev/null | tr '\n' ' ')"
    echo "  tokens in state2/locks: $(ls "$R/state2/locks" 2> /dev/null | tr '\n' ' ')"
    echo "  supervisor.lock in state: $([ -e "$R/state/supervisor.lock" ] && echo yes || echo no); in state2: $([ -e "$R/state2/supervisor.lock" ] && echo yes || echo no)"
    echo "  supervisor alive: $(kill -0 "$sup" 2> /dev/null && echo yes || echo no)"
    echo "  the supervisor's log:"; suplog | tail -n 8
    tail -n 3 "$R/sup.out" | sed 's/^/    stderr: /'
else
    printf 'sleep 75\n' > "$R/scripts/q.sh"
    printf '\n[job.q]\nfile = scripts/q.sh\nrun_every = 1m\noverlap = queue_one\n' >> "$R/config/vigil.config"
    bash "$R/app/vigil" --root "$R" supervise > "$R/sup.out" 2>&1 < /dev/null &
    sup=$!
    slot 15
    echo "first slot passed; waiting for the second, which finds the run active and is held"
    slot 20; sleep 8
    echo "state/pending: $(tr '\n' ' ' < "$R/state/pending" 2> /dev/null)"
    printf 'enabled = false\n' >> "$R/config/vigil.config"
    echo "edited: [job.q] enabled = false, $(date -u +%H:%M:%S)"
    # The first run ends 75 s after its start; allow three ticks more.
    sleep 30
    echo
    echo "after the first run has ended:"
    echo "  processes running the job's script: $(pgrep -f "$R/scripts/q.sh" | wc -l)"
    echo "  jobs.log:"; sed 's/^/    /' "$R/logs/supervisor/jobs.log" | head -n 12
    echo "  the supervisor's log:"; suplog | tail -n 8
fi
kill "$sup" 2> /dev/null
pkill -f "$R/" 2> /dev/null
sleep 1
rm -rf "$R"
