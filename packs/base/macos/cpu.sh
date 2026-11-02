#!/usr/bin/env bash
#
# cpu.sh - CPU use on macOS
#
# Takes two samples from top, one second apart, and reports the second:
# the first only covers the time since boot.
#
# Metrics:
#   used_pct  percent of CPU time in use, across all cores
#
# Example output:
#   metric used_pct 37
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  below 70: normal work, and short spikes to 100 are fine.
#   Watch    70 to 90 for 15 minutes or more: little room left for a peak.
#   Act      above 90 for 5 minutes or more: find what is using the CPU.
#
# Requires: bash, top, awk
# Exit code: 0 on success, 1 if the data cannot be read
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

set -u

# -l 2: two samples. -n 0: no process list. -s 1: one second apart.
report=$(top -l 2 -n 0 -s 1 2> /dev/null) || exit 1

# The line reads: CPU usage: 6.66% user, 13.33% sys, 80.0% idle
# awk keeps the last match, and "+ 0" drops the percent sign.
printf '%s\n' "$report" | awk '
    /^CPU usage/ { idle = $7 + 0; found = 1 }
    END {
        if (!found) exit 1
        printf "metric used_pct %d\n", 100 - idle
    }
'
