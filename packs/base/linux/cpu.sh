#!/usr/bin/env bash
#
# cpu.sh - CPU use on Linux
#
# Reads the CPU time counters in /proc/stat twice, one second apart, and
# reports the share of that second the CPU spent working.
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
# Requires: bash, /proc
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

readonly STAT_FILE=/proc/stat
readonly SAMPLE_SECONDS=1

# Reads the first line of /proc/stat, the total across all cores, into busy
# and idle. Time waiting for disk counts as idle. steal is missing on very
# old kernels.
read_counters() {
    local label user nice system idle_time iowait irq softirq steal rest
    read -r label user nice system idle_time iowait irq softirq steal rest < "$STAT_FILE" || return 1
    busy=$((user + nice + system + irq + softirq + ${steal:-0}))
    idle=$((idle_time + iowait))
}

read_counters || exit 1
first_busy=$busy
first_idle=$idle

sleep "$SAMPLE_SECONDS"

read_counters || exit 1
busy_delta=$((busy - first_busy))
total_delta=$((busy_delta + idle - first_idle))

# Guards against a division by zero on a clock that did not move.
[ "$total_delta" -gt 0 ] || total_delta=1

echo "metric used_pct $((100 * busy_delta / total_delta))"
