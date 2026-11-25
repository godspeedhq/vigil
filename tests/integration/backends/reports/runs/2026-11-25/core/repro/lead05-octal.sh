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
# Lead 5: a duration with a leading zero that validation accepts, and what
# the bash supervisor does with it. Throwaway roots only.
. "$(dirname "$0")/common.sh"

say "Control: tick = 8m"
R=$(newroot)
sed -i.bak 's/^tick *=.*/tick = 8m/' "$R/config/vigil.config"
grep -n '^tick' "$R/config/vigil.config"
v precheck > "$R/precheck.out" 2>&1; echo "precheck exit $?: $(tail -n 1 "$R/precheck.out")"
v supervise --once > "$R/once.out" 2>&1; echo "supervise --once exit $?"; tail -n 2 "$R/once.out"

say "tick = 08m: does validation accept it?"
R=$(newroot)
sed -i.bak 's/^tick *=.*/tick = 08m/' "$R/config/vigil.config"
grep -n '^tick' "$R/config/vigil.config"
v precheck > "$R/precheck.out" 2>&1; echo "precheck exit $?: $(tail -n 1 "$R/precheck.out")"
grep -i 'tick\|08' "$R/precheck.out"
say "tick = 08m: the supervisor at start"
v supervise --once > "$R/once.out" 2>&1; echo "supervise --once exit $?"; tail -n 3 "$R/once.out"

say "tick = 08m on reload: a supervisor running with tick = 5s, then the edit"
R=$(newroot)
sed -i.bak 's/^tick *=.*/tick = 5s/' "$R/config/vigil.config"
bash "$R/app/vigil" --root "$R" supervise > "$R/sup.out" 2>&1 < /dev/null &
pid=$!
sleep 12
echo "before the edit: supervisor $pid alive: $(kill -0 "$pid" 2> /dev/null && echo yes || echo no)"
sed -i.bak 's/^tick *=.*/tick = 08m/' "$R/config/vigil.config"
sleep 15
echo "15 s after the edit: supervisor $pid alive: $(kill -0 "$pid" 2> /dev/null && echo yes || echo no)"
# Ours: ended here if it is still running, so the wait cannot hang.
if kill -0 "$pid" 2> /dev/null; then echo "it is still running: ending it"; kill "$pid"; fi
wait "$pid" 2> /dev/null; echo "its exit code: $?"
tail -n 3 "$R/sup.out"
tail -n 3 "$R"/logs/supervisor/2*.log 2> /dev/null
# Ours, if it is still there.
kill "$pid" 2> /dev/null
