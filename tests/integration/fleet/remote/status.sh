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
# One line per remote fleet host, as fleet.sh status prints the Docker ones:
# release on disk, release the supervisor runs, the last update. With log
# first, the supervisors' lines about configuration and updates instead.
#   status.sh [log] <mac ssh target> <windows ssh target> [ssh options...]
# Expects host.sh's folder at ~/fleet/mac, and Status.ps1 beside Host.ps1's
# folders in fleet\ on Windows.
set -u
log=''
[ "$1" = log ] && { log=1; shift; }
mac=$1 win=$2
shift 2
if [ -n "$log" ]; then
    ssh "$@" "$mac" 'r=$HOME/fleet/mac/root; cat $r/logs/supervisor/2*.log | grep -E "as the configuration asks|could not be|reloading|staying on|configuration revision" | sed "s/^/mac  /"
        grep ^beat_beats $r/metrics/vigil.prom | sed "s/^/mac  /"' 2> /dev/null
    ssh "$@" "$win" 'powershell -NoProfile -ExecutionPolicy Bypass -File fleet\Status.ps1 -Dir fleet -Log' 2> /dev/null | tr -d '\r'
    exit 0
fi
ssh "$@" "$mac" 'r=$HOME/fleet/mac/root; u() { sed -n "s/^$1 *= *//p" "$r/state/update.state" 2> /dev/null; }
    printf "%-4s %-8s %-10s %-10s %-11s %s\n" mac git "$(cat "$r/app/VERSION" 2> /dev/null)" "$(cat "$r/state/supervisor.version" 2> /dev/null)" "$(u version)" "$(u result)$(u reason | sed "s/^/: /;s/^: $//")"' 2> /dev/null
ssh "$@" "$win" 'powershell -NoProfile -ExecutionPolicy Bypass -File fleet\Status.ps1 -Dir fleet' 2> /dev/null | tr -d '\r'
