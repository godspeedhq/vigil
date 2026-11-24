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
# Backlog 67 end to end, part B: a Vigil whose configuration comes from the
# Git source. $1: the root. Fetches, then precheck, every job of the pack run
# once, and status, as an operator would see them.
set -u
R=$1
v() { bash "$R/app/vigil" --root "$R" "$@" < /dev/null; }
say() { printf '\n$ %s\n' "$*"; }
tick() {
    local i=0
    v supervise --once >> "$R/../$(basename "$R").supervise.out" 2>&1
    while ls "$R/state/locks" 2> /dev/null | grep -q '^vigil_fetch\.'; do
        i=$((i + 1)); [ "$i" -ge 120 ] && break; sleep 0.5
    done
}
rm -f "$R/state/fetch.next"; tick; tick
say 'cat state/config.active      # the fetched configuration, now active'
cat "$R/state/config.active" 2> /dev/null || sed -n 's/^reason *= *//p' "$R/state/jobs/vigil_fetch.state"
say 'vigil precheck'
v precheck 2>&1 | grep -v '^  OK  ' ; echo "(exit ${PIPESTATUS[0]})"
# The jobs of the configuration fetched last.
cfg=$(ls -td "$R"/cache/central/*/ | head -n 1)$(sed -n 's/^config_file *= *//p' "$R/config/vigil.config")
for j in $(sed -n 's/^\[job\.\([a-z0-9_]*\)\]$/\1/p' "$cfg"); do
    case $j in vigil_*) continue ;; esac
    v run "$j" > /dev/null 2>&1
done
tick
say 'vigil status'
v status 2>&1 | sed -n '/^LAST RUN/,$p'
