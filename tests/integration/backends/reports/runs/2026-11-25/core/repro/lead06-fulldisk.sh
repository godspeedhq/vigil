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
# Lead 6, run INSIDE a throwaway container whose /st is a small tmpfs:
#   docker run --rm --tmpfs /st:size=256k -v ~/vv/src:/src:ro -v ~/vv/repro:/repro:ro debian:13-slim bash /repro/lead06-fulldisk.sh
# The state directory is /st. A first run leaves a good final state. Then
# /st is filled, and the job runs again: what does the worker publish as the
# job's state while it runs, and what does it say?
set -u
R=/work/r
mkdir -p "$R/scripts" && cp -R /src/app /src/vendor "$R/"
v() { bash "$R/app/vigil" --root "$R" "$@" < /dev/null; }
v init empty --instance t --backend file > /dev/null 2>&1
sed -i 's/^\[vigil\]$/[vigil]\nstate_dir = \/st/' "$R/config/vigil.config"
printf 'sleep 6\nexit 0\n' > "$R/scripts/j.sh"
printf '\n[job.j]\nfile = scripts/j.sh\nrun_every = 1h\nmax_runtime = 2m\n' >> "$R/config/vigil.config"
echo "bash $BASH_VERSION; precheck: $(v precheck 2>&1 | tail -n 1)"

echo; echo "# A first run, with room: the state it leaves"
v run j > /dev/null 2>&1; echo "vigil run exit $?"
ls -l /st/jobs/j.state | awk '{ print "  " $5 " bytes  " $NF }'
grep -E '^(status|run_id|deadline_epoch) ' /st/jobs/j.state | sed 's/^/  /'

echo; echo "# /st is filled"
dd if=/dev/zero of=/st/ballast bs=4k 2> /dev/null
df -k /st | tail -n 1 | awk '{ print "  " $4 " KB free of " $2 }'

echo; echo "# The job runs again; its state file, 3 s into the run"
v run j > /tmp/run2.out 2>&1 &
w=$!
sleep 3
ls -l /st/jobs/j.state | awk '{ print "  " $5 " bytes  " $NF }'
echo "  status line: [$(grep '^status' /st/jobs/j.state)]"
echo "  deadline line: [$(grep '^deadline_epoch' /st/jobs/j.state)]"
echo "  token held by the worker: $(ls /st/locks/ 2> /dev/null | tr '\n' ' ')"
wait "$w"; echo "vigil run exit $?"
echo "  what the worker printed:"; sed 's/^/    /' /tmp/run2.out | head -n 6
echo "  its job log:"; tail -n 3 "$R"/logs/jobs/j/*.log | sed 's/^/    /'
echo; echo "# After the run"
ls -l /st/jobs/j.state | awk '{ print "  " $5 " bytes  " $NF }'
ls /st/jobs/ | sed 's/^/  /'

echo; echo "# Space is freed, and the supervisor looks (one tick)"
rm -f /st/ballast
echo "  the run's spool file is there: $(ls "$R"/spool/incoming/ 2> /dev/null | grep -c -- '-j-')"
v supervise --once > /tmp/once.out 2>&1; echo "  supervise --once exit $?"
echo "  the job's state now:"; grep -E '^(status|run_id|reason) ' /st/jobs/j.state | sed 's/^/    /'
echo "  quarantine: $(ls /st/quarantine 2> /dev/null | tr '\n' ' ')"
echo "  the supervisor's log:"; grep ' j' "$R"/logs/supervisor/2*.log | sed 's/^/    /' | tail -n 4
