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
# Lead 1: a run whose worker dies after writing its spool file and before
# its final state (crash point worker.after_spool) is concluded from the
# spool. Does a metric line the job printed change the outcome recorded?
# Throwaway roots only.
. "$(dirname "$0")/common.sh"

one() {   # $1 label, $2 the job's script body, $3 expected outcome
    R=$(newroot)
    printf '%s\n' "$2" > "$R/scripts/j.sh"
    printf '\n[job.j]\nfile = scripts/j.sh\nmetric_name = app\nrun_every = 1h\n' >> "$R/config/vigil.config"
    say "$1"
    printf 'the job: %s\n' "$2"
    VIGIL_FAULT=worker.after_spool bash "$R/app/vigil" --root "$R" run j > "$R/run.out" 2>&1 < /dev/null
    echo "vigil run (worker stopped at worker.after_spool): exit $?"
    echo "state before the supervisor looks: $(sed -n 's/^status *= *//p' "$R/state/jobs/j.state")"
    echo "the spool file's lines:"; cat "$R"/spool/incoming/*-j-*.events 2> /dev/null | sed 's/^/    /'
    v supervise --once > "$R/once.out" 2>&1
    echo "after one supervisor tick: status = $(sed -n 's/^status *= *//p' "$R/state/jobs/j.state"), reason = $(sed -n 's/^reason *= *//p' "$R/state/jobs/j.state")"
    echo "expected: $3"
    grep -h ' j' "$R"/logs/supervisor/2*.log 2> /dev/null | tail -n 2 | sed 's/^/    /'
}

one 'Control: a job that fails (exit 2), no metric line' 'exit 2' failed
one 'A job that fails (exit 2) and printed: metric steps.succeeded 1' 'echo "metric steps.succeeded 1"; exit 2' failed
one 'A job that succeeds (exit 0) and printed: metric rows.failures 0' 'echo "metric rows.failures 0"; exit 0' succeeded
