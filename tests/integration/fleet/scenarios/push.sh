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
# push.sh <backend address> <wave> <change> - one change to the fleet's
# configuration, pushed to Gitea, its time recorded (scenarios/out/push.log):
#
#   good        every kind's file at <wave>: the fleet should move to it
#   broken      every file at <wave>, with a job whose run_every is not a
#               duration: the fleet takes the file, sets that job aside
#               as INVALID (its invalid_config metric) and runs the rest
#   unknown     every file at <wave>, with a section Vigil does not know:
#               the file is refused, and every instance keeps what it runs
#   windows     only windows-bare.config invalid (an unknown section):
#               Windows keeps its revision, the rest move to <wave>
#   abusive     every file at <wave>, every job run every second and a
#               thousand jobs more: what Vigil accepts, and what it costs
#
# Uses backend/out (setup.sh): the admin's token, through Git's askpass.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
[ "$#" -eq 3 ] || { sed -n '10,25p' "$0"; exit 64; }
addr=$1 wave=$2 change=$3
out=$here/../backend/out repo=$here/../backend/out/config-repo
ca=$here/../tls/out/ca.crt
mkdir -p "$here/out"
gitf() { GIT_ASKPASS=$out/askpass.sh GIT_TERMINAL_PROMPT=0 git -C "$repo" -c credential.helper= -c http.sslCAInfo="$ca" -c http.sslBackend=openssl -c core.autocrlf=false "$@"; }
gitf pull -q --ff-only origin main
bash "$here/../config/make-configs.sh" "$addr" "$repo" "$wave" > /dev/null
broken='
[job.fleet_broken]
file = packs/base/cpu.sh
metric_name = fleet.broken
run_every = banana
'
case $change in
    good) ;;
    broken) for f in "$repo"/*.config; do printf '%s' "$broken" >> "$f"; done ;;
    unknown) for f in "$repo"/*.config; do printf '\n[fleet_nonsense]\ncolour = blue\n' >> "$f"; done ;;
    windows) printf '\n[fleet_nonsense]\ncolour = blue\n' >> "$repo/windows-bare.config" ;;
    abusive)
        for f in "$repo"/*.config; do
            sed -i 's/^run_every   = 1m$/run_every   = 1s/; s/^cron        = .*$/run_every   = 1s/' "$f"
            ext=sh; case $f in *windows*) ext=ps1 ;; esac
            for i in $(seq 1 1000); do
                printf '\n[job.fleet_extra_%s]\nfile = packs/base/load.%s\nmetric_name = fleet.extra%s\nrun_every = 1s\nmax_runtime = 30s\n' "$i" "$ext" "$i" >> "$f"
            done
        done ;;
    *) echo "unknown change: $change" >&2; exit 64 ;;
esac
gitf add -A
gitf commit -q -m "Wave $wave: $change"
gitf push -q origin main
line="$(date -u +%Y-%m-%dT%H:%M:%SZ) pushed wave $wave ($change) $(gitf rev-parse --short HEAD)"
echo "$line" | tee -a "$here/out/push.log"
