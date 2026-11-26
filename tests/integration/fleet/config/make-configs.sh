#!/usr/bin/env bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# make-configs.sh <backend address> <dir> [<wave>] - the fleet's
# configuration files, one for each kind of instance, into <dir> (the
# config repository's working tree). Every instance's pointer file names
# one of them:
#
#   linux-container.config    Alpine containers (node/)
#   linux-bare.config         Linux, on the machine itself
#   macos-bare.config         macOS, on the machine itself
#   windows-bare.config       Windows, on the machine itself
#
# Each: the base pack's jobs (the scripts its install holds), metrics to
# the backend's OTLP endpoint, Vigil's own log lines to its Loki, and the
# tags fleet, kind and wave. <wave> (default 1) is the number the scenarios
# change, so a change shows in the backend as a new tag and a new revision.
set -eu
[ "$#" -ge 2 ] || { echo "usage: make-configs.sh <backend address> <dir> [<wave>]" >&2; exit 64; }
addr=$1 dir=$2 wave=${3:-1}
mkdir -p "$dir"
jobs='cpu:system.cpu:run_every   = 1m
memory:system.memory:run_every   = 1m
disk:system.disk:cron        = 1/5 * * * *
diskio:system.diskio:cron        = 2/5 * * * *
network:system.network:run_every   = 1m
load:system.load:run_every   = 1m
services:system.services:run_every   = 1m
processes:system.processes:cron        = 3/5 * * * *
host:system.host:cron        = 4/5 * * * *'

# one <kind> <ext> <runner block>
one() {
    {
        printf '# %s.config - the fleet test'"'"'s configuration for %s instances,\n' "$1" "$1"
        printf '# written by tests/integration/fleet/config/make-configs.sh. Every instance\n'
        printf '# of this kind fetches it from Git, and picks up a change at its next check.\n\n'
        printf '[vigil]\ninstance = fleet\n\n[scheduler]\ntick = 10s\n\n'
        printf '[tags]\nfleet = test\nkind = %s\nwave = %s\n\n' "$1" "$wave"
        printf '[backend.lgtm]\ntype     = otel\nendpoint = https://%s:4318/v1/metrics\ntimeout  = 10s\n\n' "$addr"
        printf '[log_destination.lgtm_logs]\ntype     = otel\nendpoint = https://%s:4318/v1/logs\ntimeout  = 10s\n\n' "$addr"
        printf '[log_forward]\ndestination = lgtm_logs\ninclude     = supervisor, run\n\n'
        printf '%s\n\n' "$3"
        printf '# pack base\n'
        printf '%s\n' "$jobs" | while IFS=: read -r j m when; do
            printf '\n[job.base_%s]\nfile = packs/base/%s.%s\nmetric_name = %s\n%s\nmax_runtime = 30s\n' "$j" "$j" "$2" "$m" "$when"
        done
        printf '# end of pack base\n'
    } > "$dir/$1.config"
}
sh='[runner.sh]
command = /bin/bash

[runners]
.sh = sh'
ps='[runner.ps]
command = powershell.exe
arg     = -NoProfile
arg     = -NonInteractive
arg     = -ExecutionPolicy
arg     = Bypass
arg     = -File

[runners]
.ps1 = ps'
one linux-container sh "$sh"
one linux-bare sh "$sh"
one macos-bare sh "$sh"
one windows-bare ps1 "$ps"
ls "$dir"
