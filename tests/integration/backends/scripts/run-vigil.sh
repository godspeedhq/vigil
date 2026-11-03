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
# run-vigil.sh - runs Vigil from this checkout, on this host, against one
# running target, then checks with verify.sh that its telemetry was stored.
#
#   scripts/start.sh lgtm
#   scripts/run-vigil.sh lgtm
#
# Vigil is installed into a temporary folder, with the workloads in
# ../workloads as its jobs: one that succeeds, one that fails, one that runs
# long, one stopped at max_runtime, one whose file is missing, one writing
# to stdout and stderr, one reporting a metric, and a native program
# (/bin/date). They all run every minute, so several run at once. The
# supervisor runs for about two and a half minutes, then verify.sh asks the
# backend for this run's data, found by a tag unique to the run.
#
# With BK_PRECHECK_ONLY=1 it stops after vigil precheck, which checks the
# configuration for the target without the backend, or Docker, running.
#
# Linux and macOS. Exit code: 0 when verify.sh passes, 1 otherwise.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

[ "$#" -eq 1 ] || die 'usage: run-vigil.sh <target>'
target=$1
endpoints "$target"
[ -z "$bk_why" ] || die "$target: not applicable to Vigil: $bk_why"

tag="bk$(date -u '+%Y%m%d%H%M%S')$$"
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-bk.XXXXXX") || exit 1
root=$work/root
sup=''
cleanup() {
    # The supervisor this script started, and nothing else.
    [ -n "$sup" ] && kill "$sup" 2> /dev/null
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' TERM INT HUP

mkdir -p "$root/scripts" "$root/config" && cp -R "$bk_repo/app" "$root/" && cp "$bk_dir"/workloads/*.sh "$root/scripts/" || exit 1

# A backend or log destination section for "<type> <endpoint>".
section() {
    local kind=$1 type=${2%% *} url=${2#* }
    printf '[%s.target]\n' "$kind"
    [ "$kind" = backend ] && printf 'type     = %s\n' "$type"
    [ "$kind" = log_destination ] && printf 'type     = %s\n' "$type"
    printf 'endpoint = %s\n' "$url"
    if [ "$type" = splunk ]; then
        if [ "$kind" = backend ]; then
            printf 'token    = env:VIGIL_SPLUNK_METRICS_TOKEN\n'
        else
            printf 'token    = env:VIGIL_SPLUNK_LOGS_TOKEN\n'
        fi
    fi
    printf '\n'
}

{
    printf '[vigil]\ninstance = backend-test\n\n[scheduler]\ntick = 10s\n\n'
    printf '[runner.sh]\ncommand = /bin/bash\n\n[runners]\n.sh = sh\n\n'
    if [ -n "$bk_metrics" ]; then
        section backend "$bk_metrics"
    else
        # Somewhere for metrics to go when the target takes only logs.
        printf '[backend.file]\npath = metrics/vigil.prom\n\n'
    fi
    if [ -n "$bk_logs" ]; then
        printf '[log_forward]\ndestination = target\ninclude     = supervisor, run, stdout, stderr\ncheck_every = 10s\n\n'
        section log_destination "$bk_logs"
    fi
    printf '[job.bk_ok]\nfile = scripts/ok.sh\nrun_every = 1m\n\n'
    printf '[job.bk_fail]\nfile = scripts/fail.sh\nrun_every = 1m\n\n'
    printf '[job.bk_long]\nfile = scripts/long.sh\nrun_every = 1m\nmax_runtime = 55s\n\n'
    printf '[job.bk_overrun]\nfile = scripts/overrun.sh\nrun_every = 1m\nmax_runtime = 10s\ngrace = 5s\n\n'
    printf '[job.bk_missing]\nfile = scripts/missing.sh\nrun_every = 1m\n\n'
    printf '[job.bk_output]\nfile = scripts/output.sh\nrun_every = 1m\nenv = BK_RUN=%s\n\n' "$tag"
    printf '[job.bk_metrics]\nfile = scripts/metrics.sh\nrun_every = 1m\nenv = BK_RUN=%s\n\n' "$tag"
    printf '[job.bk_native]\nfile = /bin/date\nrun_every = 1m\n'
} > "$root/config/vigil.config"

vigil() { bash "$root/app/vigil" --root "$root" "$@" < /dev/null; }
printf 'run tag: %s\n' "$tag"
# bk_missing's file is missing on purpose, and precheck rightly says so;
# any other problem stops the run.
if ! vigil precheck > "$work/precheck.out" 2>&1; then
    cat "$work/precheck.out"
    if grep -E '^ *(FAIL|INVALID|ERROR)' "$work/precheck.out" | grep -qv 'bk_missing'; then
        die 'precheck failed: the configuration above is wrong, or a credential is missing from .env'
    fi
    printf 'precheck: only bk_missing, whose file is missing on purpose\n'
fi
# BK_PRECHECK_ONLY=1 stops here: the configuration for this target is
# checked without a backend, or Docker, at all.
[ -z "${BK_PRECHECK_ONLY-}" ] || exit 0

vigil supervise > "$work/supervise.out" 2>&1 &
sup=$!
# Two whole minutes of runs, then time for the sender and forwarder.
sleep 150
kill "$sup" 2> /dev/null
wait "$sup" 2> /dev/null
sup=''
# The last sender and forwarder runs, started by the last tick.
sleep 15

printf '\njobs.log at the end:\n'
sed 's/^/  /' "$root/logs/supervisor/jobs.log"
bash "$here/verify.sh" "$target" "$tag"
